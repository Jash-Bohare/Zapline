// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {FlashSwap} from "src/FlashSwap.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract FakePair {
    function token0() external pure returns (address) {
        return address(0x1);
    }

    function token1() external pure returns (address) {
        return address(0x2);
    }
}

contract FlashSwapTest is ForkBase {
    using SafeERC20 for IERC20;

    FlashSwap internal flashSwap;
    IUniswapV2Router02 internal sushiRouter;
    address internal usdcWethPair;
    address internal sushiUsdcWethPair;

    address internal sushiRouterAddr = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    function setUp() public override {
        super.setUp();
        sushiRouter = IUniswapV2Router02(sushiRouterAddr);
        usdcWethPair = factory.getPair(address(usdc), address(weth));
        sushiUsdcWethPair = IUniswapV2Factory(sushiRouter.factory()).getPair(address(usdc), address(weth));

        flashSwap = new FlashSwap(address(factory), sushiRouterAddr);
    }

    /// @notice Helper to push SushiSwap price up so selling WETH for USDC is highly profitable
    function _createSushiArbitrageGap() internal {
        address marketMover = makeAddr("market.mover");
        uint256 usdcDump = 2_000_000 * 1e6; // Dump 2M USDC into SushiSwap pool
        deal(address(usdc), marketMover, usdcDump);

        vm.startPrank(marketMover);
        usdc.forceApprove(sushiRouterAddr, usdcDump);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        sushiRouter.swapExactTokensForTokens(usdcDump, 0, path, marketMover, block.timestamp);
        vm.stopPrank();
    }

    /// @notice FS-T01: Engineered price gap, executeArb generates profit, forwards to recipient, contract stateless
    function test_FST01_EngineeredGapProfitableExecution() public {
        _createSushiArbitrageGap();

        uint256 borrowAmount = 2 ether;
        uint256 recipientBefore = usdc.balanceOf(alice);

        uint256 profit = flashSwap.executeArb(usdcWethPair, address(weth), borrowAmount, 0, alice);

        assertGt(profit, 0, "Arbitrage must yield positive profit");
        assertEq(usdc.balanceOf(alice) - recipientBefore, profit, "Recipient must receive exact profit");
        assertEq(usdc.balanceOf(address(flashSwap)), 0, "I-FS-2: Contract must hold 0 USDC after arb");
        assertEq(weth.balanceOf(address(flashSwap)), 0, "I-FS-2: Contract must hold 0 WETH after arb");
    }

    /// @notice FS-T02: Repayment math matches Router.getAmountsIn
    function test_FST02_RepaymentMathMatchesRouter() public view {
        uint256 borrowAmount = 1 ether;
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(usdcWethPair).getReserves();
        address t0 = IUniswapV2Pair(usdcWethPair).token0();
        uint256 rBorrow = address(weth) == t0 ? uint256(r0) : uint256(r1);
        uint256 rRepay = address(weth) == t0 ? uint256(r1) : uint256(r0);

        uint256 expectedRepay = (rRepay * borrowAmount * 1000) / ((rBorrow - borrowAmount) * 997) + 1;

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        uint256[] memory routerAmounts = router.getAmountsIn(borrowAmount, path);

        assertEq(expectedRepay, routerAmounts[0], "Flash swap repay amount must match Router.getAmountsIn");
    }

    /// @notice FS-T03: No price gap reverts Unprofitable and reserves remain unchanged
    function test_FST03_NoGapRevertsUnprofitableReservesUnchanged() public {
        (uint112 r0Before, uint112 r1Before,) = IUniswapV2Pair(usdcWethPair).getReserves();

        vm.expectRevert();
        flashSwap.executeArb(usdcWethPair, address(weth), 1 ether, 0, alice);

        (uint112 r0After, uint112 r1After,) = IUniswapV2Pair(usdcWethPair).getReserves();
        assertEq(r0After, r0Before, "I-FS-3: Reserve0 must be unchanged on revert");
        assertEq(r1After, r1Before, "I-FS-3: Reserve1 must be unchanged on revert");
    }

    /// @notice FS-T04: minProfit too high reverts Unprofitable
    function test_FST04_MinProfitTooHighReverts() public {
        _createSushiArbitrageGap();

        uint256 excessiveMinProfit = 10_000_000 * 1e6; // 10M USDC minimum profit
        vm.expectRevert();
        flashSwap.executeArb(usdcWethPair, address(weth), 1 ether, excessiveMinProfit, alice);
    }

    /// @notice FS-T05: Direct call to uniswapV2Call from EOA reverts UnauthorizedCaller
    function test_FST05_DirectCallbackCallRevertsUnauthorized() public {
        bytes memory dummyData = abi.encode(address(weth), address(usdc), 1 ether, 2000 * 1e6, 0, alice);

        vm.prank(alice);
        vm.expectRevert(FlashSwap.UnauthorizedCaller.selector);
        flashSwap.uniswapV2Call(alice, 0, 0, dummyData);
    }

    /// @notice FS-T06: Fake pair contract calling callback reverts UnauthorizedCaller
    function test_FST06_FakePairCallbackReverts() public {
        FakePair fake = new FakePair();
        bytes memory dummyData = abi.encode(address(weth), address(usdc), 1 ether, 2000 * 1e6, 0, alice);

        vm.prank(address(fake));
        vm.expectRevert(FlashSwap.UnauthorizedCaller.selector);
        flashSwap.uniswapV2Call(alice, 0, 0, dummyData);
    }

    /// @notice FS-T07: Real pair swap initiated by attacker reverts UnauthorizedCaller
    function test_FST07_HostileInitiatorReverts() public {
        bytes memory attackData = abi.encode(address(weth), address(usdc), 1 ether, 2000 * 1e6, 0, attacker);

        address token0 = IUniswapV2Pair(usdcWethPair).token0();
        uint256 amount0Out = token0 == address(weth) ? 1 ether : 0;
        uint256 amount1Out = token0 == address(weth) ? 0 : 1 ether;

        vm.prank(attacker);
        vm.expectRevert(FlashSwap.UnauthorizedCaller.selector);
        IUniswapV2Pair(usdcWethPair).swap(amount0Out, amount1Out, address(flashSwap), attackData);
    }

    /// @notice FS-T08: Borrow amount 0 or >= reserve reverts InvalidBorrow
    function test_FST08_InvalidBorrowAmountsRevert() public {
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(usdcWethPair).getReserves();
        address t0 = IUniswapV2Pair(usdcWethPair).token0();
        uint256 rWeth = address(weth) == t0 ? uint256(r0) : uint256(r1);

        // 0 amount
        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArb(usdcWethPair, address(weth), 0, 0, alice);

        // >= reserve
        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArb(usdcWethPair, address(weth), rWeth, 0, alice);

        // > reserve
        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArb(usdcWethPair, address(weth), rWeth + 1 ether, 0, alice);
    }

    /// @notice FS-T09: Pair invariant k has not decreased after flash swap
    function test_FST09_KInvariantDoesNotDecrease() public {
        _createSushiArbitrageGap();

        (uint112 r0Before, uint112 r1Before,) = IUniswapV2Pair(usdcWethPair).getReserves();
        uint256 kBefore = uint256(r0Before) * uint256(r1Before);

        flashSwap.executeArb(usdcWethPair, address(weth), 1 ether, 0, alice);

        (uint112 r0After, uint112 r1After,) = IUniswapV2Pair(usdcWethPair).getReserves();
        uint256 kAfter = uint256(r0After) * uint256(r1After);

        assertGe(kAfter, kBefore, "I-FS-4: k invariant must not decrease after swap");
    }

    /// @notice FS-T10: Same token repayment fee formula
    function test_FST10_SameTokenRepaymentFormula() public pure {
        uint256 borrow = 10 ether;
        uint256 repay = (borrow * 1000) / 997 + 1;
        uint256 fee = repay - borrow;

        // ~0.3009% fee
        assertGt(fee, (borrow * 3) / 1000, "Fee should exceed 0.3000%");
        assertLt(fee, (borrow * 31) / 10000, "Fee should be below 0.3100%");
    }

    /// @notice FS-F01: Fuzz borrow amount on engineered gap
    function testFuzz_FSF01_ArbitrageExecution(uint256 borrowRaw) public {
        _createSushiArbitrageGap();

        // Bound borrow amount between 0.05 ether and 5 ether
        uint256 borrowAmount = bound(borrowRaw, 0.05 ether, 5 ether);
        uint256 recipientBefore = usdc.balanceOf(alice);

        uint256 profit = flashSwap.executeArb(usdcWethPair, address(weth), borrowAmount, 0, alice);

        assertGt(profit, 0, "Profitable borrow amount must produce profit");
        assertEq(usdc.balanceOf(alice) - recipientBefore, profit, "Recipient receives exact profit");
        assertEq(usdc.balanceOf(address(flashSwap)), 0, "Vault holds 0 USDC");
        assertEq(weth.balanceOf(address(flashSwap)), 0, "Vault holds 0 WETH");
    }

    /// @notice FS-T11: executeArbSameToken reverts Unprofitable without external surplus
    function test_FST11_ExecuteArbSameTokenRevertsUnprofitable() public {
        vm.expectRevert();
        flashSwap.executeArbSameToken(usdcWethPair, address(weth), 1 ether, 0, alice);
    }

    /// @notice FS-T12: executeArbSameToken succeeds and distributes profit when funded with arbitrage surplus
    function test_FST12_ExecuteArbSameTokenSuccessWithSurplus() public {
        // Pre-fund flashSwap with surplus to simulate profitable return in borrowed token
        uint256 fee = (uint256(1 ether) * 1000) / 997 + 1 - 1 ether + 0.05 ether;
        deal(address(weth), address(flashSwap), fee);

        uint256 aliceBefore = weth.balanceOf(alice);
        uint256 profit = flashSwap.executeArbSameToken(usdcWethPair, address(weth), 1 ether, 0, alice);
        assertGt(profit, 0, "Arbitrage should yield profit");
        assertEq(weth.balanceOf(alice) - aliceBefore, profit, "Alice receives profit");
        assertEq(weth.balanceOf(address(flashSwap)), 0, "FlashSwap holds 0 residual tokens");
    }
}
