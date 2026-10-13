// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Callee} from "src/interfaces/IUniswapV2Callee.sol";
import {MockERC20} from "test/base/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

contract FlashBorrower is IUniswapV2Callee {
    bool public repayShort;

    function setRepayShort(bool _short) external {
        repayShort = _short;
    }

    function uniswapV2Call(address sender, uint256 amount0, uint256 amount1, bytes calldata) external override {
        sender; // silence unused warning
        address token0 = IUniswapV2Pair(msg.sender).token0();
        address token1 = IUniswapV2Pair(msg.sender).token1();

        address borrowedToken = amount0 > 0 ? token0 : token1;
        uint256 borrowedAmount = amount0 > 0 ? amount0 : amount1;

        // V2 flash swap fee formula: repay = (amount * 1000) / 997 + 1
        uint256 fee = (borrowedAmount * 3) / 997 + 1;
        uint256 repayAmount = borrowedAmount + fee;

        if (repayShort) {
            repayAmount -= 1; // 1 wei short
        }

        IERC20(borrowedToken).transfer(msg.sender, repayAmount);
    }
}

contract V2Refresher is ForkBase {
    FlashBorrower internal borrower;

    function setUp() public override {
        super.setUp();
        borrower = new FlashBorrower();
    }

    /// @notice R-T01: Verify factory.getPair equals the CREATE2-derived address with Uniswap V2 init code hash
    function test_RT01_Create2PairAddress() public view {
        address tokenA = address(usdc);
        address tokenB = address(weth);

        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);

        bytes32 initCodeHash = hex"96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f";
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));

        address derivedPair =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"ff", address(factory), salt, initCodeHash)))));

        address actualPair = factory.getPair(tokenA, tokenB);
        assertEq(derivedPair, actualPair, "CREATE2 pair address mismatch");
    }

    /// @notice R-T02: Read token0, token1, reserves; check ordering and decimal scaling
    function test_RT02_OrderingReservesAndSpotPrice() public view {
        IUniswapV2Pair pair = pairOf(address(usdc), address(weth));
        address t0 = pair.token0();
        address t1 = pair.token1();

        assertTrue(t0 < t1, "Tokens must be sorted token0 < token1");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);

        (uint256 rUsdc, uint256 rWeth) = t0 == address(usdc) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        // Spot price of WETH in USDC = (rUsdc * 1e18) / rWeth
        uint256 ethPriceInUsdc = (rUsdc * 1e18) / rWeth;

        assertGt(ethPriceInUsdc, 500 * 1e6, "ETH price too low");
        assertLt(ethPriceInUsdc, 20_000 * 1e6, "ETH price too high");
    }

    /// @notice R-T03: Manual getAmountOut matches Router.getAmountsOut for 10 amounts
    function test_RT03_ManualGetAmountOutVsRouter() public view {
        IUniswapV2Pair pair = pairOf(address(usdc), address(weth));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            pair.token0() == address(usdc) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        uint256[10] memory testAmounts = [
            uint256(100 * 1e6),
            uint256(500 * 1e6),
            uint256(1_000 * 1e6),
            uint256(2_500 * 1e6),
            uint256(5_000 * 1e6),
            uint256(10_000 * 1e6),
            uint256(25_000 * 1e6),
            uint256(5_000 * 1e6 * 10),
            uint256(100_000 * 1e6),
            uint256(250_000 * 1e6)
        ];

        for (uint256 i = 0; i < 10; i++) {
            uint256 amountIn = testAmounts[i];
            uint256 amountInWithFee = amountIn * 997;
            uint256 manualOut = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);

            uint256[] memory routerOuts = router.getAmountsOut(amountIn, path);
            assertEq(manualOut, routerOuts[1], "Manual amountOut != Router amountOut");
        }
    }

    /// @notice R-T04: Real swap, reserve check and k_after >= k_before
    function test_RT04_SwapAndInvariantK() public {
        IUniswapV2Pair pair = pairOf(address(usdc), address(weth));
        (uint112 r0Before, uint112 r1Before,) = pair.getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        uint256 swapAmountIn = 10_000 * 1e6; // 10k USDC
        fund(alice, usdc, swapAmountIn);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        vm.startPrank(alice);
        usdc.approve(address(router), swapAmountIn);
        router.swapExactTokensForTokens(swapAmountIn, 0, path, alice, block.timestamp);
        vm.stopPrank();

        (uint112 r0After, uint112 r1After,) = pair.getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        assertGe(kAfter, kBefore, "k must not decrease after swap");
        assertTrue(kAfter > kBefore, "k should strictly increase due to 0.3% fee");
    }

    /// @notice R-T05: Price impact across swap sizes (1k, 100k, 1M USDC)
    function test_RT05_PriceImpactAcrossSizes() public view {
        IUniswapV2Pair pair = pairOf(address(usdc), address(weth));
        (uint112 r0, uint112 r1,) = pair.getReserves();
        (uint256 reserveIn, uint256 reserveOut) =
            pair.token0() == address(usdc) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));

        uint256[3] memory sizes = [uint256(1_000 * 1e6), uint256(100_000 * 1e6), uint256(1_000_000 * 1e6)];

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        uint256 prevImpact = 0;
        for (uint256 i = 0; i < sizes.length; i++) {
            uint256 amountIn = sizes[i];
            uint256[] memory amounts = router.getAmountsOut(amountIn, path);
            uint256 amountOut = amounts[1];

            uint256 effectivePrice = (amountIn * 1e18) / amountOut;
            uint256 spotPrice = (reserveIn * 1e18) / reserveOut;

            uint256 impactBps = effectivePrice > spotPrice ? ((effectivePrice - spotPrice) * 10_000) / spotPrice : 0;

            assertTrue(impactBps >= prevImpact, "Price impact must grow monotonically with trade size");
            prevImpact = impactBps;
        }
    }

    /// @notice R-T06: Add liquidity to a fresh pair; first mint = sqrt(x*y) - 1000, later mints proportional
    function test_RT06_FreshPairLiquidityFirstMint() public {
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);

        address pairAddress = factory.createPair(address(tokenA), address(tokenB));
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);

        uint256 amountA = 100 * 1e18;
        uint256 amountB = 400 * 1e18;

        tokenA.mint(alice, amountA);
        tokenB.mint(alice, amountB);

        vm.startPrank(alice);
        tokenA.approve(address(router), amountA);
        tokenB.approve(address(router), amountB);

        (,, uint256 lpAlice) =
            router.addLiquidity(address(tokenA), address(tokenB), amountA, amountB, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        uint256 expectedFirstLp = Math.sqrt(amountA * amountB) - 1000;
        assertEq(lpAlice, expectedFirstLp, "First mint LP math mismatch");
        assertEq(pair.balanceOf(address(0)), 1000, "1000 minimum liquidity must be locked at address(0)");

        // Second mint from Bob (proportional)
        uint256 amountA2 = 50 * 1e18;
        uint256 amountB2 = 200 * 1e18;
        tokenA.mint(bob, amountA2);
        tokenB.mint(bob, amountB2);

        vm.startPrank(bob);
        tokenA.approve(address(router), amountA2);
        tokenB.approve(address(router), amountB2);

        (,, uint256 lpBob) =
            router.addLiquidity(address(tokenA), address(tokenB), amountA2, amountB2, 0, 0, bob, block.timestamp);
        vm.stopPrank();

        uint256 totalBeforeBob = pair.totalSupply() - lpBob;
        assertEq(lpBob, totalBeforeBob / 2, "Subsequent mint must be proportional to reserves");
    }

    /// @notice R-T07: Remove liquidity; returned tokens equal share * reserves / totalSupply
    function test_RT07_RemoveLiquidityBurnMath() public {
        MockERC20 tokenA = new MockERC20("Token A", "TKA", 18);
        MockERC20 tokenB = new MockERC20("Token B", "TKB", 18);

        address pairAddress = factory.createPair(address(tokenA), address(tokenB));
        IUniswapV2Pair pair = IUniswapV2Pair(pairAddress);

        tokenA.mint(alice, 200 * 1e18);
        tokenB.mint(alice, 800 * 1e18);

        vm.startPrank(alice);
        tokenA.approve(address(router), 200 * 1e18);
        tokenB.approve(address(router), 800 * 1e18);
        (,, uint256 lpAlice) =
            router.addLiquidity(address(tokenA), address(tokenB), 200 * 1e18, 800 * 1e18, 0, 0, alice, block.timestamp);

        uint256 lpToBurn = lpAlice / 2;
        pair.approve(address(router), lpToBurn);

        uint256 expectedA;
        uint256 expectedB;
        {
            (uint112 r0, uint112 r1,) = pair.getReserves();
            (uint256 rA, uint256 rB) =
                pair.token0() == address(tokenA) ? (uint256(r0), uint256(r1)) : (uint256(r1), uint256(r0));
            uint256 totalLp = pair.totalSupply();
            expectedA = (lpToBurn * rA) / totalLp;
            expectedB = (lpToBurn * rB) / totalLp;
        }

        (uint256 returnedA, uint256 returnedB) =
            router.removeLiquidity(address(tokenA), address(tokenB), lpToBurn, 0, 0, alice, block.timestamp);
        vm.stopPrank();

        assertEq(returnedA, expectedA, "Removed tokenA amount mismatch");
        assertEq(returnedB, expectedB, "Removed tokenB amount mismatch");
    }

    /// @notice R-T08: Flash swap repayment rule: exact repayment passes, 1 wei short reverts
    function test_RT08_FlashSwapRepaymentExactAndShort() public {
        IUniswapV2Pair pair = pairOf(address(usdc), address(weth));
        uint256 borrowAmount = 10_000 * 1e6; // 10,000 USDC

        // Fund borrower with enough to pay the fee for BOTH calls
        uint256 fee = (borrowAmount * 3) / 997 + 1;
        fund(address(borrower), usdc, (fee + 1000) * 2);

        // Case 1: Exact repayment succeeds
        borrower.setRepayShort(false);
        uint256 amount0Out = pair.token0() == address(usdc) ? borrowAmount : 0;
        uint256 amount1Out = pair.token0() == address(usdc) ? 0 : borrowAmount;

        pair.swap(amount0Out, amount1Out, address(borrower), bytes("flash"));

        // Case 2: 1 wei short reverts with UniswapV2: K
        borrower.setRepayShort(true);
        vm.expectRevert(bytes("UniswapV2: K"));
        pair.swap(amount0Out, amount1Out, address(borrower), bytes("flash"));
    }

    /// @notice R-T09: Warp time, sync(), read price0CumulativeLast, compute TWAP by hand
    function test_RT09_CumulativePriceAndTwapByHand() public {
        IUniswapV2Pair pair = pairOf(address(usdc), address(weth));
        pair.sync();

        uint256 p0Before = pair.price0CumulativeLast();
        uint32 tsBefore = uint32(block.timestamp);

        uint32 timeElapsed = 1800; // 30 minutes
        vm.warp(block.timestamp + timeElapsed);

        pair.sync();

        uint256 p0After = pair.price0CumulativeLast();
        uint32 tsAfter = uint32(block.timestamp);

        assertEq(tsAfter - tsBefore, timeElapsed);
        assertGt(p0After, p0Before, "Cumulative price must increase after elapsed time");

        uint256 twapUQ112 = (p0After - p0Before) / timeElapsed;
        assertGt(twapUQ112, 0, "TWAP in UQ112 must be positive");

        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 expectedSpotUQ112 = (uint256(r1) << 112) / uint256(r0);

        assertEq(twapUQ112, expectedSpotUQ112, "TWAP on quiet pool must equal reserve ratio");
    }
}
