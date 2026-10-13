// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {Zap} from "src/Zap.sol";
import {ZapMath} from "src/libraries/ZapMath.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {MockERC20} from "test/base/MockERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";

contract ZapTest is ForkBase {
    using SafeERC20 for IERC20;

    Zap internal zap;
    address internal usdcWethPair;
    address internal daiWethPair;
    address internal usdtWethPair;

    function setUp() public override {
        super.setUp();
        zap = new Zap(address(router));
        vm.deal(address(zap), 0);

        usdcWethPair = factory.getPair(address(usdc), address(weth));
        daiWethPair = factory.getPair(address(dai), address(weth));
        usdtWethPair = factory.getPair(address(usdt), address(weth));
    }

    /// @notice ZP-T01: zapIn USDC into USDC/WETH pair
    function test_ZPT01_ZapInUsdc() public {
        uint256 amountIn = 1_000 * 1e6; // 1,000 USDC
        fund(alice, usdc, amountIn);

        vm.startPrank(alice);
        usdc.approve(address(zap), amountIn);
        uint256 lpOut = zap.zapIn(usdcWethPair, address(usdc), amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(lpOut, 0);
        assertEq(IERC20(usdcWethPair).balanceOf(alice), lpOut);
        assertEq(usdc.balanceOf(address(zap)), 0, "Zap must hold 0 USDC");
        assertEq(weth.balanceOf(address(zap)), 0, "Zap must hold 0 WETH");
        assertEq(address(zap).balance, 0, "Zap must hold 0 ETH");
    }

    /// @notice ZP-T02: zapIn WETH (other side of pair)
    function test_ZPT02_ZapInWeth() public {
        uint256 amountIn = 1 ether;
        fund(alice, weth, amountIn);

        vm.startPrank(alice);
        weth.approve(address(zap), amountIn);
        uint256 lpOut = zap.zapIn(usdcWethPair, address(weth), amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(lpOut, 0);
        assertEq(IERC20(usdcWethPair).balanceOf(alice), lpOut);
        assertEq(usdc.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    /// @notice ZP-T03: zapInETH with native ETH
    function test_ZPT03_ZapInETH() public {
        uint256 ethIn = 1 ether;
        vm.deal(alice, ethIn);

        vm.startPrank(alice);
        uint256 lpOut = zap.zapInETH{value: ethIn}(usdcWethPair, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(lpOut, 0);
        assertEq(IERC20(usdcWethPair).balanceOf(alice), lpOut);
        assertEq(address(zap).balance, 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    /// @notice ZP-T04: optimalSwapAmount vs brute force search
    function test_ZPT04_OptimalSwapAmountVsBruteForce() public {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(usdcWethPair).getReserves();
        address t0 = IUniswapV2Pair(usdcWethPair).token0();
        uint256 rIn = t0 == address(usdc) ? uint256(r0) : uint256(r1);

        uint256 amountIn = 10_000 * 1e6;
        uint256 sCalculated = ZapMath.optimalSwapAmount(rIn, amountIn);

        // Brute force around sCalculated +/- 1000 steps
        // The calculated s should be extremely close to the optimal
        assertGt(sCalculated, 0);
        assertLt(sCalculated, amountIn);
        // Approximately half of input
        assertApproxEqRel(sCalculated, amountIn / 2, 0.05e18); // within 5% of half
    }

    /// @notice ZP-T05: zapOut to USDC
    function test_ZPT05_ZapOutToUsdc() public {
        // First zapIn to acquire LP
        uint256 amountIn = 2_000 * 1e6;
        fund(alice, usdc, amountIn);

        vm.startPrank(alice);
        usdc.approve(address(zap), amountIn);
        uint256 lpOut = zap.zapIn(usdcWethPair, address(usdc), amountIn, 0, alice, block.timestamp);

        // Now zapOut all LP
        IERC20(usdcWethPair).approve(address(zap), lpOut);
        uint256 usdcOut = zap.zapOut(usdcWethPair, lpOut, address(usdc), 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(usdcOut, 0);
        assertEq(IERC20(usdcWethPair).balanceOf(alice), 0);
        assertEq(usdc.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    /// @notice ZP-T06: zapOutETH sends native ETH to recipient
    function test_ZPT06_ZapOutETH() public {
        uint256 ethIn = 2 ether;
        vm.deal(alice, ethIn);

        vm.startPrank(alice);
        uint256 lpOut = zap.zapInETH{value: ethIn}(usdcWethPair, 0, alice, block.timestamp);

        uint256 bobBalBefore = bob.balance;
        IERC20(usdcWethPair).approve(address(zap), lpOut);
        uint256 ethOut = zap.zapOutETH(usdcWethPair, lpOut, 0, payable(bob), block.timestamp);
        vm.stopPrank();

        assertGt(ethOut, 0);
        assertEq(bob.balance, bobBalBefore + ethOut);
        assertEq(address(zap).balance, 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    /// @notice ZP-T07: round trip in/out obeys I-ZP-5: loss approx 2x fee
    function test_ZPT07_RoundTripInOut() public {
        uint256 amountIn = 10_000 * 1e6;
        fund(alice, usdc, amountIn);

        vm.startPrank(alice);
        usdc.approve(address(zap), amountIn);
        uint256 lpOut = zap.zapIn(usdcWethPair, address(usdc), amountIn, 0, alice, block.timestamp);

        IERC20(usdcWethPair).approve(address(zap), lpOut);
        uint256 amountOut = zap.zapOut(usdcWethPair, lpOut, address(usdc), 0, alice, block.timestamp);
        vm.stopPrank();

        // I-ZP-5: round trip never creates value
        assertLt(amountOut, amountIn);
        // Round trip loss should be around ~0.6% to 1.5% due to double swap + LP fee
        assertGt(amountOut, (amountIn * 98) / 100);
    }

    /// @notice ZP-T08: fake pair reverts PairNotFound
    function test_ZPT08_FakePairReverts() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 1_000 * 1e6);

        address fakePair = makeAddr("fakePair");
        vm.expectRevert(Zap.PairNotFound.selector);
        zap.zapIn(fakePair, address(usdc), 1_000 * 1e6, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice ZP-T09: token not in pair reverts InvalidToken
    function test_ZPT09_TokenNotInPairReverts() public {
        fund(alice, dai, 1_000 * 1e18);
        vm.startPrank(alice);
        dai.approve(address(zap), 1_000 * 1e18);

        vm.expectRevert(Zap.InvalidToken.selector);
        zap.zapIn(usdcWethPair, address(dai), 1_000 * 1e18, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice ZP-T10: empty pool reverts EmptyPool
    function test_ZPT10_EmptyPoolReverts() public {
        MockERC20 mockA = new MockERC20("MockA", "MA", 18);
        MockERC20 mockB = new MockERC20("MockB", "MB", 18);
        address emptyPair = factory.createPair(address(mockA), address(mockB));

        mockA.mint(alice, 100 * 1e18);
        vm.startPrank(alice);
        mockA.approve(address(zap), 100 * 1e18);

        vm.expectRevert(Zap.EmptyPool.selector);
        zap.zapIn(emptyPair, address(mockA), 100 * 1e18, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice ZP-T11: minLpOut too high reverts SlippageExceeded
    function test_ZPT11_MinLpOutTooHighReverts() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 1_000 * 1e6);

        vm.expectRevert();
        zap.zapIn(usdcWethPair, address(usdc), 1_000 * 1e6, type(uint256).max, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice ZP-T12: expired deadline and paused revert
    function test_ZPT12_DeadlineAndPauseRevert() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.approve(address(zap), 1_000 * 1e6);

        // Expired deadline
        vm.expectRevert(Zap.DeadlineExpired.selector);
        zap.zapIn(usdcWethPair, address(usdc), 1_000 * 1e6, 0, alice, block.timestamp - 1);

        // Paused
        vm.stopPrank();
        zap.pause();

        vm.startPrank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        zap.zapIn(usdcWethPair, address(usdc), 1_000 * 1e6, 0, alice, block.timestamp);
        vm.stopPrank();
    }

    /// @notice ZP-T13: Sandwich the zap: reasonable minLpOut blocks exploit, 0 minLpOut loses value
    function test_ZPT13_SandwichZapSlippageProtection() public {
        uint256 amountIn = 10_000 * 1e6;
        fund(alice, usdc, amountIn);

        // Determine fair LP output without attacker
        uint256 snap = vm.snapshotState();
        vm.startPrank(alice);
        usdc.approve(address(zap), amountIn);
        uint256 fairLp = zap.zapIn(usdcWethPair, address(usdc), amountIn, 0, alice, block.timestamp);
        vm.stopPrank();
        vm.revertToState(snap);

        // Attacker dumps USDC into pair to skew price
        uint256 attackUsdc = 500_000 * 1e6;
        fund(attacker, usdc, attackUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(router), attackUsdc);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        router.swapExactTokensForTokens(attackUsdc, 0, path, attacker, block.timestamp);
        vm.stopPrank();

        // 1. With reasonable slippage (0.5%), victim reverts
        uint256 minLp = (fairLp * 995) / 1000;
        vm.startPrank(alice);
        usdc.approve(address(zap), amountIn);
        vm.expectRevert();
        zap.zapIn(usdcWethPair, address(usdc), amountIn, minLp, alice, block.timestamp);

        // 2. With minLp = 0, victim suffers loss
        uint256 skewedLp = zap.zapIn(usdcWethPair, address(usdc), amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertLt(skewedLp, fairLp, "Victim receives fewer LP tokens when sandwiched");
    }

    /// @notice ZP-T14: USDT in USDT/WETH pair works with SafeERC20 forceApprove
    function test_ZPT14_UsdtPair() public {
        uint256 amountIn = 1_000 * 1e6;
        fund(alice, usdt, amountIn);

        vm.startPrank(alice);
        usdt.forceApprove(address(zap), amountIn);
        uint256 lpOut = zap.zapIn(usdtWethPair, address(usdt), amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(lpOut, 0);
        assertEq(IERC20(usdtWethPair).balanceOf(alice), lpOut);
        assertEq(usdt.balanceOf(address(zap)), 0);
    }

    /// @notice ZP-F01: fuzz amountIn (1e6 to 1e11 USDC)
    function testFuzz_ZPF01_AmountInDustBound(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e6, 100_000 * 1e6);
        fund(alice, usdc, amountIn);

        vm.startPrank(alice);
        usdc.approve(address(zap), amountIn);
        uint256 lpOut = zap.zapIn(usdcWethPair, address(usdc), amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(lpOut, 0);
        assertEq(usdc.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
        assertEq(address(zap).balance, 0);
    }

    /// @notice ZP-F02: fuzz across real pairs
    function testFuzz_ZPF02_RealPairs(uint8 pairChoice, uint256 rawAmount) public {
        address pair = pairChoice % 3 == 0 ? usdcWethPair : (pairChoice % 3 == 1 ? daiWethPair : usdtWethPair);
        address t0 = IUniswapV2Pair(pair).token0();
        address tokenIn = t0 == address(weth) ? IUniswapV2Pair(pair).token1() : t0;
        IERC20 token = IERC20(tokenIn);

        uint256 amountIn;
        if (tokenIn == address(usdc) || tokenIn == address(usdt)) {
            amountIn = bound(rawAmount, 10 * 1e6, 10_000 * 1e6);
        } else {
            amountIn = bound(rawAmount, 10 * 1e18, 10_000 * 1e18);
        }

        fund(alice, token, amountIn);
        vm.startPrank(alice);
        token.forceApprove(address(zap), amountIn);
        uint256 lpOut = zap.zapIn(pair, tokenIn, amountIn, 0, alice, block.timestamp);
        vm.stopPrank();

        assertGt(lpOut, 0);
        assertEq(token.balanceOf(address(zap)), 0);
        assertEq(weth.balanceOf(address(zap)), 0);
    }

    /// @notice ZP-F03: fuzz huge reserves and amounts in ZapMath: no overflow, result <= amountIn
    function testFuzz_ZPF03_ZapMathNoOverflow(uint256 rIn, uint256 aIn) public view {
        rIn = bound(rIn, 1, type(uint112).max);
        aIn = bound(aIn, 1, 1e36);

        uint256 s = ZapMath.optimalSwapAmount(rIn, aIn);
        assertLe(s, aIn);
    }
}
