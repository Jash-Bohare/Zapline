// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {V2Library} from "src/libraries/V2Library.sol";
import {ZapMath} from "src/libraries/ZapMath.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {SwapExecutor} from "src/SwapExecutor.sol";
import {Zap} from "src/Zap.sol";
import {LPVault} from "src/LPVault.sol";
import {FlashSwap} from "src/FlashSwap.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract MockEmptyPair {
    function price0CumulativeLast() external pure returns (uint256) {
        return 0;
    }

    function price1CumulativeLast() external pure returns (uint256) {
        return 0;
    }

    function getReserves() external pure returns (uint112, uint112, uint32) {
        return (0, 0, 0);
    }

    function token0() external pure returns (address) {
        return address(0x1);
    }

    function token1() external pure returns (address) {
        return address(0x2);
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }

    function balanceOf(address) external pure returns (uint256) {
        return 0;
    }
}

contract V2LibraryWrapper {
    function sortTokens(address a, address b) external pure returns (address, address) {
        return V2Library.sortTokens(a, b);
    }

    function getAmountOut(uint256 a, uint256 rIn, uint256 rOut) external pure returns (uint256) {
        return V2Library.getAmountOut(a, rIn, rOut);
    }

    function getAmountIn(uint256 a, uint256 rIn, uint256 rOut) external pure returns (uint256) {
        return V2Library.getAmountIn(a, rIn, rOut);
    }

    function getReservesSorted(address f, address a, address b) external view returns (uint256, uint256, address) {
        return V2Library.getReservesSorted(f, a, b);
    }

    function getAmountsOut(address f, uint256 a, address[] memory p) external view returns (uint256[] memory) {
        return V2Library.getAmountsOut(f, a, p);
    }

    function getAmountsIn(address f, uint256 a, address[] memory p) external view returns (uint256[] memory) {
        return V2Library.getAmountsIn(f, a, p);
    }
}

contract ComprehensiveCoverageTest is ForkBase {
    using SafeERC20 for IERC20;

    TwapOracle internal oracle;
    SwapExecutor internal executor;
    Zap internal zap;
    LPVault internal vault;
    FlashSwap internal flashSwap;
    V2LibraryWrapper internal libWrapper;
    address internal usdcWethPair;
    address internal daiUsdcPair;

    address internal sushiRouterAddr = 0xd9e1cE17f2641f24aE83637ab66a2cca9C378B9F;

    function setUp() public override {
        super.setUp();
        usdcWethPair = factory.getPair(address(usdc), address(weth));
        daiUsdcPair = factory.getPair(address(dai), address(usdc));

        oracle = new TwapOracle(1800, 600, 86400);
        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + 1800);

        executor = new SwapExecutor(address(router));
        zap = new Zap(address(router));
        vm.deal(address(zap), 0);

        vault = new LPVault(
            usdcWethPair, address(usdc), address(weth), address(zap), address(oracle), "Coverage Vault", "cVAULT"
        );

        flashSwap = new FlashSwap(address(factory), sushiRouterAddr);
        libWrapper = new V2LibraryWrapper();
    }

    // ==========================================
    // 1. V2Library Unit Coverage
    // ==========================================

    function test_V2Library_SortTokens() public {
        (address t0, address t1) = libWrapper.sortTokens(address(usdc), address(weth));
        assertTrue(t0 < t1);

        (address r0, address r1) = libWrapper.sortTokens(address(weth), address(usdc));
        assertEq(t0, r0);
        assertEq(t1, r1);

        // Same tokens
        vm.expectRevert(V2Library.InvalidTokens.selector);
        libWrapper.sortTokens(address(usdc), address(usdc));

        // Zero address
        vm.expectRevert(V2Library.ZeroAddress.selector);
        libWrapper.sortTokens(address(0), address(usdc));
    }

    function test_V2Library_GetReservesSorted() public {
        (uint256 rA, uint256 rB, address p) =
            libWrapper.getReservesSorted(address(factory), address(usdc), address(weth));
        assertEq(p, usdcWethPair);
        assertGt(rA, 0);
        assertGt(rB, 0);

        // Inverted
        (uint256 rB2, uint256 rA2,) = libWrapper.getReservesSorted(address(factory), address(weth), address(usdc));
        assertEq(rA, rA2);
        assertEq(rB, rB2);

        // Pair does not exist
        vm.expectRevert(V2Library.PairNotFound.selector);
        libWrapper.getReservesSorted(address(factory), address(usdc), makeAddr("nonexistentToken"));
    }

    function test_V2Library_GetAmountOut() public {
        uint256 out = libWrapper.getAmountOut(1000, 100_000, 200_000);
        assertGt(out, 0);

        // Zero amount
        vm.expectRevert(V2Library.ZeroAmount.selector);
        libWrapper.getAmountOut(0, 100_000, 200_000);

        // Zero reserveIn
        vm.expectRevert(V2Library.InsufficientLiquidity.selector);
        libWrapper.getAmountOut(1000, 0, 200_000);

        // Zero reserveOut
        vm.expectRevert(V2Library.InsufficientLiquidity.selector);
        libWrapper.getAmountOut(1000, 100_000, 0);
    }

    function test_V2Library_GetAmountIn() public {
        uint256 inAmt = libWrapper.getAmountIn(1000, 100_000, 200_000);
        assertGt(inAmt, 0);

        // Zero amount
        vm.expectRevert(V2Library.ZeroAmount.selector);
        libWrapper.getAmountIn(0, 100_000, 200_000);

        // Zero reserveIn
        vm.expectRevert(V2Library.InsufficientLiquidity.selector);
        libWrapper.getAmountIn(1000, 0, 200_000);

        // Zero reserveOut
        vm.expectRevert(V2Library.InsufficientLiquidity.selector);
        libWrapper.getAmountIn(1000, 100_000, 0);

        // amountOut >= reserveOut
        vm.expectRevert(V2Library.InsufficientLiquidity.selector);
        libWrapper.getAmountIn(200_000, 100_000, 200_000);
    }

    function test_V2Library_GetAmountsOutAndInMultiHop() public {
        address[] memory path = new address[](3);
        path[0] = address(usdc);
        path[1] = address(weth);
        path[2] = address(dai);

        uint256[] memory amountsOut = libWrapper.getAmountsOut(address(factory), 1_000 * 1e6, path);
        assertEq(amountsOut.length, 3);
        assertEq(amountsOut[0], 1_000 * 1e6);
        assertGt(amountsOut[2], 0);

        uint256[] memory amountsIn = libWrapper.getAmountsIn(address(factory), amountsOut[2], path);
        assertEq(amountsIn.length, 3);
        assertLe(amountsIn[0], 1_000 * 1e6 + 2);

        // Invalid path length (< 2)
        address[] memory shortPath = new address[](1);
        shortPath[0] = address(usdc);
        vm.expectRevert(V2Library.InvalidTokens.selector);
        libWrapper.getAmountsOut(address(factory), 100, shortPath);

        vm.expectRevert(V2Library.InvalidTokens.selector);
        libWrapper.getAmountsIn(address(factory), 100, shortPath);
    }

    // ==========================================
    // 2. ZapMath Unit Coverage
    // ==========================================

    function test_ZapMath_ZeroInputs() public pure {
        assertEq(ZapMath.optimalSwapAmount(0, 1000), 0);
        assertEq(ZapMath.optimalSwapAmount(1000, 0), 0);
    }

    function test_ZapMath_ExtremeOverflowCap() public pure {
        uint256 maxAmount = type(uint256).max;
        uint256 res = ZapMath.optimalSwapAmount(1000, maxAmount);
        assertEq(res, maxAmount / 2);

        uint256 maxReserve = type(uint256).max;
        uint256 res2 = ZapMath.optimalSwapAmount(maxReserve, 1000);
        assertEq(res2, 500);
    }

    function test_ZapMath_Sqrt512Branch() public pure {
        uint256 reserveIn = 1e38;
        uint256 amountIn = 1e38;
        uint256 swapAmount = ZapMath.optimalSwapAmount(reserveIn, amountIn);
        assertGt(swapAmount, 0);
        assertLe(swapAmount, amountIn);
    }

    function test_ZapMath_RootLessThanR1997() public pure {
        uint256 swapAmount = ZapMath.optimalSwapAmount(1e18, 1);
        assertEq(swapAmount, 0);
    }

    // ==========================================
    // 3. TwapOracle Coverage
    // ==========================================

    function test_TwapOracle_CoverageGettersAndInvalidToken() public {
        assertGt(oracle.observationCount(usdcWethPair), 0);

        TwapOracle.Observation memory obs = oracle.getObservation(usdcWethPair, 0);
        assertGt(obs.timestamp, 0);

        // Invalid token in consult
        vm.expectRevert(TwapOracle.InvalidToken.selector);
        oracle.consult(usdcWethPair, makeAddr("invalidToken"), 1 ether);

        // Empty pool in currentCumulativePrices
        MockEmptyPair emptyPair = new MockEmptyPair();
        vm.expectRevert(TwapOracle.EmptyPool.selector);
        oracle.currentCumulativePrices(address(emptyPair));
    }

    // ==========================================
    // 4. SwapExecutor Coverage
    // ==========================================

    function test_SwapExecutor_ConstructorAndValidationReverts() public {
        vm.expectRevert(SwapExecutor.InvalidRecipient.selector);
        new SwapExecutor(address(0));

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        vm.expectRevert(SwapExecutor.ZeroAmount.selector);
        executor.swapExactIn(path, 0, 0, alice, block.timestamp);

        vm.expectRevert(SwapExecutor.InvalidRecipient.selector);
        executor.swapExactIn(path, 100, 0, address(0), block.timestamp);

        vm.expectRevert(SwapExecutor.InvalidRecipient.selector);
        executor.swapExactIn(path, 100, 0, address(executor), block.timestamp);

        vm.expectRevert(SwapExecutor.ZeroAmount.selector);
        executor.swapExactOut(path, 0, 1000, alice, block.timestamp);

        vm.expectRevert(SwapExecutor.InvalidRecipient.selector);
        executor.swapExactOut(path, 100, 1000, address(0), block.timestamp);

        vm.expectRevert(SwapExecutor.InvalidRecipient.selector);
        executor.swapExactOut(path, 100, 1000, address(executor), block.timestamp);
    }

    function test_SwapExecutor_Quotes() public view {
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        uint256[] memory outQuotes = executor.quoteExactIn(path, 1_000 * 1e6);
        assertEq(outQuotes.length, 2);
        assertGt(outQuotes[1], 0);

        uint256[] memory inQuotes = executor.quoteExactOut(path, 1 ether);
        assertEq(inQuotes.length, 2);
        assertGt(inQuotes[0], 0);
    }

    function test_SwapExecutor_UnpauseAndRescueTokens() public {
        executor.pause();
        executor.unpause();

        // Rescue ETH
        vm.deal(address(executor), 1 ether);
        uint256 aliceBefore = alice.balance;
        executor.rescueETH(payable(alice), 1 ether);
        assertEq(alice.balance - aliceBefore, 1 ether);

        // Rescue ERC20 token
        deal(address(dai), address(executor), 500 ether);
        executor.rescueToken(address(dai), alice, 500 ether);
        assertEq(dai.balanceOf(alice), 500 ether);

        // Zero address rescue recipient
        vm.expectRevert(SwapExecutor.InvalidRecipient.selector);
        executor.rescueETH(payable(address(0)), 1);

        vm.expectRevert(SwapExecutor.InvalidRecipient.selector);
        executor.rescueToken(address(usdc), address(0), 1);

        // Unexpected ETH receive
        vm.prank(alice);
        vm.expectRevert(SwapExecutor.UnexpectedETH.selector);
        (bool ok,) = address(executor).call{value: 1 ether}("");
    }

    // ==========================================
    // 5. Zap Coverage
    // ==========================================

    function test_Zap_ConstructorAndValidationReverts() public {
        vm.expectRevert(Zap.InvalidRecipient.selector);
        new Zap(address(0));

        // zapIn validations
        vm.expectRevert(Zap.ZeroAmount.selector);
        zap.zapIn(usdcWethPair, address(usdc), 0, 0, alice, block.timestamp);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.zapIn(usdcWethPair, address(usdc), 100, 0, address(0), block.timestamp);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.zapIn(usdcWethPair, address(usdc), 100, 0, address(zap), block.timestamp);

        // zapInETH validations
        vm.expectRevert(Zap.ZeroAmount.selector);
        zap.zapInETH{value: 0}(usdcWethPair, 0, alice, block.timestamp);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.zapInETH{value: 1 ether}(usdcWethPair, 0, address(0), block.timestamp);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.zapInETH{value: 1 ether}(usdcWethPair, 0, address(zap), block.timestamp);

        // zapOut validations
        vm.expectRevert(Zap.ZeroAmount.selector);
        zap.zapOut(usdcWethPair, 0, address(usdc), 0, alice, block.timestamp);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.zapOut(usdcWethPair, 100, address(usdc), 0, address(0), block.timestamp);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.zapOut(usdcWethPair, 100, address(usdc), 0, address(zap), block.timestamp);

        // zapOutETH with non-WETH pair
        vm.expectRevert(Zap.InvalidToken.selector);
        zap.zapOutETH(daiUsdcPair, 100, 0, payable(alice), block.timestamp);
    }

    function test_Zap_QuoteAndAdminFunctions() public {
        uint256 quote = zap.quoteZapIn(usdcWethPair, address(usdc), 1_000 * 1e6);
        assertGt(quote, 0);

        zap.pause();
        zap.unpause();

        // rescueETH
        vm.deal(address(zap), 1 ether);
        uint256 aliceBefore = alice.balance;
        zap.rescueETH(payable(alice), 1 ether);
        assertEq(alice.balance - aliceBefore, 1 ether);

        // rescueToken
        deal(address(dai), address(zap), 200 ether);
        zap.rescueToken(address(dai), alice, 200 ether);
        assertEq(dai.balanceOf(alice), 200 ether);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.rescueETH(payable(address(0)), 1);

        vm.expectRevert(Zap.InvalidRecipient.selector);
        zap.rescueToken(address(usdc), address(0), 1);

        // Unexpected ETH receive
        vm.prank(alice);
        vm.expectRevert(Zap.UnexpectedETH.selector);
        (bool ok,) = address(zap).call{value: 1 ether}("");
    }

    // ==========================================
    // 6. LPVault Coverage
    // ==========================================

    function test_LPVault_ConstructorAndValidationReverts() public {
        vm.expectRevert(LPVault.InvalidRecipient.selector);
        new LPVault(address(0), address(usdc), address(weth), address(zap), address(oracle), "V", "V");

        vm.expectRevert(LPVault.InvalidRecipient.selector);
        new LPVault(usdcWethPair, address(usdc), address(weth), address(0), address(oracle), "V", "V");

        vm.expectRevert(LPVault.InvalidRecipient.selector);
        new LPVault(usdcWethPair, address(usdc), address(weth), address(zap), address(0), "V", "V");

        // Invalid tokens for pair
        vm.expectRevert(LPVault.InvalidPair.selector);
        new LPVault(usdcWethPair, address(dai), address(weth), address(zap), address(oracle), "V", "V");

        // deposit validations
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.deposit(0, alice);

        vm.expectRevert(LPVault.InvalidRecipient.selector);
        vault.deposit(100, address(0));

        vm.expectRevert(LPVault.InvalidRecipient.selector);
        vault.deposit(100, address(vault));

        // redeem validations
        vm.expectRevert(LPVault.ZeroAmount.selector);
        vault.redeem(0, alice, alice);

        vm.expectRevert(LPVault.InvalidRecipient.selector);
        vault.redeem(100, address(0), alice);

        vm.expectRevert(LPVault.InvalidRecipient.selector);
        vault.redeem(100, address(vault), alice);

        // unpause
        vault.pause();
        vault.unpause();

        // rescueToken
        deal(address(dai), address(vault), 100 ether);
        vault.rescueToken(address(dai), alice, 100 ether);
        assertEq(dai.balanceOf(alice), 100 ether);

        vm.expectRevert(LPVault.InvalidRecipient.selector);
        vault.rescueToken(address(dai), address(0), 1);
    }

    function test_LPVault_RedeemSlippageExceeded() public {
        deal(address(usdc), alice, 100 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 100 * 1e6);
        uint256 shares = vault.deposit(100 * 1e6, alice);

        vm.expectRevert();
        vault.redeemWithMin(shares, alice, alice, 1_000_000 * 1e6);
        vm.stopPrank();
    }

    function test_LPVault_InvertedTokensPair() public {
        LPVault wethVault = new LPVault(
            usdcWethPair, address(weth), address(usdc), address(zap), address(oracle), "WETH Vault", "wVAULT"
        );

        deal(address(weth), alice, 2 ether);
        vm.startPrank(alice);
        weth.forceApprove(address(wethVault), 2 ether);
        uint256 shares = wethVault.deposit(2 ether, alice);
        assertGt(shares, 0);

        uint256 assets = wethVault.totalAssets();
        assertGt(assets, 0);

        uint256 out = wethVault.redeem(shares, alice, alice);
        assertGt(out, 0);
        vm.stopPrank();
    }

    // ==========================================
    // 7. FlashSwap Coverage
    // ==========================================

    function test_FlashSwap_ConstructorAndExecuteArbReverts() public {
        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        new FlashSwap(address(0), sushiRouterAddr);

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        new FlashSwap(address(factory), address(0));

        // executeArb invalid arguments
        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArb(address(0), address(weth), 1 ether, 0, alice);

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArb(usdcWethPair, address(weth), 1 ether, 0, address(0));

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArb(usdcWethPair, address(weth), 1 ether, 0, address(flashSwap));

        vm.expectRevert(FlashSwap.PairNotFound.selector);
        flashSwap.executeArb(makeAddr("fakePair"), address(weth), 1 ether, 0, alice);

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArb(usdcWethPair, address(dai), 1 ether, 0, alice);

        // executeArbSameToken invalid arguments
        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArbSameToken(address(0), address(weth), 1 ether, 0, alice);

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArbSameToken(usdcWethPair, address(weth), 1 ether, 0, address(0));

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArbSameToken(usdcWethPair, address(weth), 1 ether, 0, address(flashSwap));

        vm.expectRevert(FlashSwap.PairNotFound.selector);
        flashSwap.executeArbSameToken(makeAddr("fakePair"), address(weth), 1 ether, 0, alice);

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArbSameToken(usdcWethPair, address(dai), 1 ether, 0, alice);

        vm.expectRevert(FlashSwap.InvalidBorrow.selector);
        flashSwap.executeArbSameToken(usdcWethPair, address(weth), 0, 0, alice);
    }
}
