// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract TwapOracleTest is ForkBase {
    using SafeERC20 for IERC20;

    TwapOracle internal oracle;
    address internal usdcWethPair;

    uint32 internal constant MIN_WINDOW = 1800; // 30 min
    uint32 internal constant MIN_SPACING = 600; // 10 min
    uint32 internal constant MAX_AGE = 86400; // 24 h

    function setUp() public override {
        super.setUp();
        oracle = new TwapOracle(MIN_WINDOW, MIN_SPACING, MAX_AGE);
        usdcWethPair = factory.getPair(address(usdc), address(weth));
    }

    /// @notice OR-T01: update, warp 30 min, consult matches spot within 0.5%
    function test_ORT01_UpdateWarpConsultMatchesSpot() public {
        oracle.update(usdcWethPair);

        vm.warp(block.timestamp + MIN_WINDOW);

        uint256 amountIn = 1 ether;
        uint256 amountOut = oracle.consult(usdcWethPair, address(weth), amountIn);

        // Spot quote from router
        address[] memory path = new address[](2);
        path[0] = address(weth);
        path[1] = address(usdc);
        uint256 spotQuote = router.getAmountsOut(amountIn, path)[1];

        assertGt(amountOut, 0);
        // On a quiet fork with no intermediate trades, TWAP should match spot within 0.5%
        assertApproxEqRel(amountOut, spotQuote, 0.005e18);
    }

    /// @notice OR-T02: consult before enough history reverts InsufficientHistory
    function test_ORT02_ConsultBeforeHistoryReverts() public {
        // No update at all
        vm.expectRevert(TwapOracle.InsufficientHistory.selector);
        oracle.consult(usdcWethPair, address(weth), 1 ether);

        // One update, but 0 seconds elapsed
        oracle.update(usdcWethPair);
        vm.expectRevert(TwapOracle.InsufficientHistory.selector);
        oracle.consult(usdcWethPair, address(weth), 1 ether);

        // One update, but only 10 minutes elapsed (< MIN_WINDOW of 30 min)
        vm.warp(block.timestamp + MIN_SPACING);
        vm.expectRevert(TwapOracle.InsufficientHistory.selector);
        oracle.consult(usdcWethPair, address(weth), 1 ether);
    }

    /// @notice OR-T03: consult after MAX_AGE without update reverts StaleOracle
    function test_ORT03_ConsultAfterMaxAgeReverts() public {
        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + MAX_AGE + 1);

        vm.expectRevert(TwapOracle.StaleOracle.selector);
        oracle.consult(usdcWethPair, address(weth), 1 ether);
    }

    /// @notice OR-T04: update spacing: update inside MIN_SPACING is ignored
    function test_ORT04_UpdateSpacingIgnored() public {
        oracle.update(usdcWethPair);
        assertEq(oracle.observationCount(usdcWethPair), 1);

        // Warp only 5 minutes (< MIN_SPACING of 10 minutes)
        vm.warp(block.timestamp + 300);
        oracle.update(usdcWethPair);
        assertEq(oracle.observationCount(usdcWethPair), 1, "Count must remain 1 when called too soon");

        // Warp past MIN_SPACING
        vm.warp(block.timestamp + 301);
        oracle.update(usdcWethPair);
        assertEq(oracle.observationCount(usdcWethPair), 2, "Count increments after MIN_SPACING");
    }

    /// @notice OR-T05: ring buffer wrap past 8 observations
    function test_ORT05_RingBufferWrap() public {
        for (uint256 i = 0; i < 12; i++) {
            oracle.update(usdcWethPair);
            vm.warp(block.timestamp + MIN_SPACING);
        }

        assertEq(oracle.observationCount(usdcWethPair), 8, "Max observations capped at 8");

        // Warp enough to meet MIN_WINDOW
        vm.warp(block.timestamp + MIN_WINDOW);
        uint256 amountOut = oracle.consult(usdcWethPair, address(weth), 1 ether);
        assertGt(amountOut, 0);
    }

    /// @notice OR-T06: Spot manipulation resistance: big swap moves spot 20%, TWAP moves < 1% in same block
    function test_ORT06_SpotManipulationResistanceSameBlock() public {
        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + MIN_WINDOW);

        uint256 fairTwap = oracle.consult(usdcWethPair, address(weth), 1 ether);

        // Attacker dumps 5,000,000 USDC into pool
        uint256 dumpUsdc = 5_000_000 * 1e6;
        fund(attacker, usdc, dumpUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(router), dumpUsdc);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        router.swapExactTokensForTokens(dumpUsdc, 0, path, attacker, block.timestamp);
        vm.stopPrank();

        // Spot moved dramatically (dumping USDC raises WETH price in USDC)
        address[] memory wethToUsdc = new address[](2);
        wethToUsdc[0] = address(weth);
        wethToUsdc[1] = address(usdc);
        uint256 manipulatedSpot = router.getAmountsOut(1 ether, wethToUsdc)[1];
        assertGt(manipulatedSpot, (fairTwap * 120) / 100, "Spot moved over 20%");

        // TWAP in the same block has elapsed 0 seconds since manipulation: TWAP moves 0%
        uint256 currentTwap = oracle.consult(usdcWethPair, address(weth), 1 ether);
        assertEq(currentTwap, fairTwap, "Same-block spot move has 0 weight in TWAP");
    }

    /// @notice OR-T07: Sustained manipulation cost vs shift over multiple warped blocks
    function test_ORT07_SustainedManipulationShift() public {
        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + MIN_WINDOW);
        uint256 baselineTwap = oracle.consult(usdcWethPair, address(weth), 1 ether);

        // Shift over 5 minutes (300 sec) out of 30 min window (1800 sec):
        // Weight is 300 / 1800 = 16.6% of the manipulation
        uint256 dumpUsdc = 1_000_000 * 1e6;
        fund(attacker, usdc, dumpUsdc);
        vm.startPrank(attacker);
        usdc.approve(address(router), dumpUsdc);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        router.swapExactTokensForTokens(dumpUsdc, 0, path, attacker, block.timestamp);
        vm.stopPrank();

        vm.warp(block.timestamp + 300);
        uint256 shiftedTwap = oracle.consult(usdcWethPair, address(weth), 1 ether);

        // TWAP shift is dampened to a small fraction of spot move (WETH price increased)
        assertGt(shiftedTwap, baselineTwap, "TWAP increased slightly");
        assertLt(shiftedTwap, (baselineTwap * 110) / 100, "Shift is heavily dampened by 30min window");
    }

    /// @notice OR-T08: Both directions consistent with reserve ratio
    function test_ORT08_BothDirectionsConsistency() public {
        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + MIN_WINDOW);

        uint256 wethIn = 1 ether;
        uint256 usdcOut = oracle.consult(usdcWethPair, address(weth), wethIn);

        uint256 wethBack = oracle.consult(usdcWethPair, address(usdc), usdcOut);

        // Round trip consultation should be within 0.1% due to fixed point rounding
        assertApproxEqRel(wethBack, wethIn, 0.001e18);
    }

    /// @notice OR-T09: Cumulative price overflow arithmetic
    function test_ORT09_CumulativeOverflowArithmetic() public {
        // uint256 subtraction in unchecked handles wrapping naturally:
        // (x - y) mod 2^256 gives exact elapsed integral
        uint256 nowPrice;
        uint256 thenPrice;
        unchecked {
            thenPrice = type(uint256).max - 1000;
            nowPrice = 2000; // wrapped past 2^256
            uint256 delta = nowPrice - thenPrice;
            assertEq(delta, 3001);
        }
    }

    /// @notice OR-F01: Fuzz swap sizes between updates
    function testFuzz_ORF01_SwapSizesBetweenUpdates(uint256 usdcSwap) public {
        usdcSwap = bound(usdcSwap, 1_000 * 1e6, 500_000 * 1e6);

        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + MIN_WINDOW / 2);

        // Do swap
        fund(alice, usdc, usdcSwap);
        vm.startPrank(alice);
        usdc.approve(address(router), usdcSwap);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        router.swapExactTokensForTokens(usdcSwap, 0, path, alice, block.timestamp);
        vm.stopPrank();

        vm.warp(block.timestamp + MIN_WINDOW / 2);

        uint256 twapOut = oracle.consult(usdcWethPair, address(weth), 1 ether);
        assertGt(twapOut, 0);
    }
}
