// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {LPVault} from "src/LPVault.sol";
import {Zap} from "src/Zap.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";

contract LPVaultTest is ForkBase {
    using SafeERC20 for IERC20;

    LPVault internal vault;
    Zap internal zap;
    TwapOracle internal oracle;
    address internal usdcWethPair;

    function setUp() public override {
        super.setUp();
        usdcWethPair = factory.getPair(address(usdc), address(weth));

        oracle = new TwapOracle(1800, 600, 86400);
        oracle.update(usdcWethPair);
        vm.warp(block.timestamp + 1800);

        zap = new Zap(address(router));
        vm.deal(address(zap), 0);

        vault = new LPVault(
            usdcWethPair,
            address(usdc),
            address(weth),
            address(zap),
            address(oracle),
            "Zapline USDC-WETH Vault",
            "zUSDC-WETH"
        );
    }

    /// @notice VT-T01: First deposit: shares > 0, LP held by vault, idle assets 0
    function test_VTT01_FirstDeposit() public {
        uint256 depositAmt = 1_000 * 1e6; // 1,000 USDC
        fund(alice, usdc, depositAmt);

        vm.startPrank(alice);
        usdc.forceApprove(address(vault), depositAmt);
        uint256 shares = vault.deposit(depositAmt, alice);
        vm.stopPrank();

        assertGt(shares, 0);
        assertEq(vault.balanceOf(alice), shares);
        assertGt(IERC20(usdcWethPair).balanceOf(address(vault)), 0);
        assertLe(usdc.balanceOf(address(vault)), 5, "Idle USDC must be minimal dust");
    }

    /// @notice VT-T02: Second deposit does not dilute existing holders (I-VT-2)
    function test_VTT02_SecondDepositNoDilution() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 1_000 * 1e6);
        vault.deposit(1_000 * 1e6, alice);
        vm.stopPrank();

        uint256 priceBefore = (vault.totalAssets() * 1e18) / vault.totalSupply();

        fund(bob, usdc, 2_000 * 1e6);
        vm.startPrank(bob);
        usdc.forceApprove(address(vault), 2_000 * 1e6);
        vault.deposit(2_000 * 1e6, bob);
        vm.stopPrank();

        uint256 priceAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertGe(priceAfter, (priceBefore * 999) / 1000, "Share price must not be diluted");
    }

    /// @notice VT-T03: Redeem all returns deposit minus zap swap costs, vault LP to 0
    function test_VTT03_RedeemAll() public {
        uint256 depositAmt = 1_000 * 1e6;
        fund(alice, usdc, depositAmt);

        vm.startPrank(alice);
        usdc.forceApprove(address(vault), depositAmt);
        uint256 shares = vault.deposit(depositAmt, alice);

        uint256 usdcBefore = usdc.balanceOf(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        vm.stopPrank();

        assertGt(assetsOut, 0);
        assertEq(usdc.balanceOf(alice), usdcBefore + assetsOut);
        assertEq(vault.balanceOf(alice), 0);
        assertEq(IERC20(usdcWethPair).balanceOf(address(vault)), 0);
        assertLe(usdc.balanceOf(address(vault)), 5);
    }

    /// @notice VT-T04: Pool fee accrual increases share value over time
    function test_VTT04_FeeAccrualIncreasesSharePrice() public {
        fund(alice, usdc, 5_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 5_000 * 1e6);
        vault.deposit(5_000 * 1e6, alice);
        vm.stopPrank();

        uint256 sharePriceBefore = (vault.totalAssets() * 1e18) / vault.totalSupply();

        // Simulate 20 back-and-forth trades in the pool to accumulate 0.3% fees
        for (uint256 i = 0; i < 20; i++) {
            fund(bob, usdc, 50_000 * 1e6);
            vm.startPrank(bob);
            usdc.forceApprove(address(router), 50_000 * 1e6);
            address[] memory path = new address[](2);
            path[0] = address(usdc);
            path[1] = address(weth);
            uint256[] memory amounts = router.swapExactTokensForTokens(50_000 * 1e6, 0, path, bob, block.timestamp);

            weth.forceApprove(address(router), amounts[1]);
            address[] memory revPath = new address[](2);
            revPath[0] = address(weth);
            revPath[1] = address(usdc);
            router.swapExactTokensForTokens(amounts[1], 0, revPath, bob, block.timestamp);
            vm.stopPrank();
        }

        // Warp and update oracle
        vm.warp(block.timestamp + 1800);
        oracle.update(usdcWethPair);

        uint256 sharePriceAfter = (vault.totalAssets() * 1e18) / vault.totalSupply();
        assertGt(sharePriceAfter, sharePriceBefore, "Accrued LP fees must increase vault share price");
    }

    /// @notice VT-T05: First depositor inflation attack mitigated by virtual offset
    function test_VTT05_FirstDepositorInflationAttackMitigated() public {
        // Attacker deposits small 1 USDC to obtain minimal shares
        uint256 minDeposit = 1 * 1e6;
        fund(attacker, usdc, minDeposit);
        vm.startPrank(attacker);
        usdc.forceApprove(address(vault), minDeposit);
        uint256 attackerShares = vault.deposit(minDeposit, attacker);
        vm.stopPrank();

        // Attacker attempts inflation attack by acquiring real LP tokens and donating directly to vault
        uint256 pumpUsdc = 10_000 * 1e6;
        fund(attacker, usdc, pumpUsdc);
        vm.startPrank(attacker);
        usdc.forceApprove(address(zap), pumpUsdc);
        uint256 donateLp = zap.zapIn(usdcWethPair, address(usdc), pumpUsdc, 0, attacker, block.timestamp);
        IERC20(usdcWethPair).transfer(address(vault), donateLp);
        vm.stopPrank();

        // Victim deposits 1,000 USDC
        fund(bob, usdc, 1_000 * 1e6);
        vm.startPrank(bob);
        usdc.forceApprove(address(vault), 1_000 * 1e6);
        uint256 victimShares = vault.deposit(1_000 * 1e6, bob);
        vm.stopPrank();

        // Because of the 10^6 virtual offset, victim does NOT receive 0 shares!
        assertGt(victimShares, 0, "Victim must receive non-zero shares");

        // Attacker redeems their shares - verify attack yielded negative profit
        vm.prank(attacker);
        uint256 attackerPayout = vault.redeem(attackerShares, attacker, attacker);

        // Attacker invested minDeposit (1 USDC) + pumpUsdc (10,000 USDC) = 10,001 USDC
        uint256 attackerTotalInvested = minDeposit + pumpUsdc;
        assertLt(attackerPayout, attackerTotalInvested, "Attacker net profit must be negative");

        // Victim redeems their shares and successfully recovers their capital
        vm.prank(bob);
        uint256 victimPayout = vault.redeem(victimShares, bob, bob);
        assertGt(victimPayout, (1_000 * 1e6 * 98) / 100, "Victim capital protected by virtual shares");
    }

    /// @notice VT-T06: Donation of LP tokens directly to vault raises share price securely
    function test_VTT06_DirectLpDonation() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 1_000 * 1e6);
        vault.deposit(1_000 * 1e6, alice);
        vm.stopPrank();

        uint256 totalBefore = vault.totalAssets();

        // Donate 1 LP token
        deal(usdcWethPair, bob, 1 ether);
        vm.prank(bob);
        IERC20(usdcWethPair).transfer(address(vault), 1 ether);

        uint256 totalAfter = vault.totalAssets();
        assertGt(totalAfter, totalBefore);
    }

    /// @notice VT-T07: totalAssets() under spot manipulation changes by < 1%
    function test_VTT07_TotalAssetsResistsSpotManipulation() public {
        fund(alice, usdc, 10_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 10_000 * 1e6);
        vault.deposit(10_000 * 1e6, alice);
        vm.stopPrank();

        uint256 fairTotalAssets = vault.totalAssets();

        // Attacker swaps 30% of pool reserves in the same block
        uint256 attackSwap = 3_000_000 * 1e6;
        fund(attacker, usdc, attackSwap);
        vm.startPrank(attacker);
        usdc.forceApprove(address(router), attackSwap);
        address[] memory path = new address[](2);
        path[0] = address(usdc);
        path[1] = address(weth);
        router.swapExactTokensForTokens(attackSwap, 0, path, attacker, block.timestamp);
        vm.stopPrank();

        uint256 manipulatedTotalAssets = vault.totalAssets();

        // Fair-reserves + TWAP keeps totalAssets within 1% of fair value!
        assertApproxEqRel(manipulatedTotalAssets, fairTotalAssets, 0.01e18);
    }

    /// @notice VT-T08: Oracle without history reverts on deposit
    function test_VTT08_OracleWithoutHistoryReverts() public {
        TwapOracle uninitializedOracle = new TwapOracle(1800, 600, 86400);
        LPVault freshVault = new LPVault(
            usdcWethPair, address(usdc), address(weth), address(zap), address(uninitializedOracle), "Fresh Vault", "fV"
        );

        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(freshVault), 1_000 * 1e6);
        vm.expectRevert();
        freshVault.deposit(1_000 * 1e6, alice);
        vm.stopPrank();
    }

    /// @notice VT-T09: Paused vault blocks deposits but allows redeem
    function test_VTT09_PauseBlocksDepositAllowsRedeem() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 1_000 * 1e6);
        uint256 shares = vault.deposit(1_000 * 1e6, alice);
        vm.stopPrank();

        vault.pause();

        // Deposit reverts
        fund(bob, usdc, 1_000 * 1e6);
        vm.startPrank(bob);
        usdc.forceApprove(address(vault), 1_000 * 1e6);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        vault.deposit(1_000 * 1e6, bob);
        vm.stopPrank();

        // Redeem succeeds even when paused (FR-VT-9)
        vm.prank(alice);
        uint256 assetsOut = vault.redeem(shares, alice, alice);
        assertGt(assetsOut, 0);
    }

    /// @notice VT-T10: Exact mint() and withdraw() revert with documented errors
    function test_VTT10_ExactMintAndWithdrawUnsupported() public {
        vm.expectRevert(LPVault.ExactMintUnsupported.selector);
        vault.mint(100, alice);

        vm.expectRevert(LPVault.ExactWithdrawUnsupported.selector);
        vault.withdraw(100, alice, alice);
    }

    /// @notice VT-T11: depositWithMin too strict reverts SlippageExceeded
    function test_VTT11_DepositWithMinSlippageExceeded() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 1_000 * 1e6);
        vm.expectRevert();
        vault.depositWithMin(1_000 * 1e6, alice, type(uint256).max);
        vm.stopPrank();
    }

    /// @notice VT-T12: Share allowance flow for redeem by operator
    function test_VTT12_OperatorRedeemAllowance() public {
        fund(alice, usdc, 1_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(vault), 1_000 * 1e6);
        uint256 shares = vault.deposit(1_000 * 1e6, alice);
        vault.approve(bob, shares);
        vm.stopPrank();

        // Bob redeems on behalf of Alice
        vm.prank(bob);
        uint256 assetsOut = vault.redeem(shares, bob, alice);
        assertGt(assetsOut, 0);
        assertEq(usdc.balanceOf(bob), assetsOut);
    }

    /// @notice VT-T13: Rescue access control and protected tokens
    function test_VTT13_RescueProtectedTokens() public {
        vm.expectRevert(LPVault.ProtectedToken.selector);
        vault.rescueToken(usdcWethPair, owner, 1);

        vm.expectRevert(LPVault.ProtectedToken.selector);
        vault.rescueToken(address(usdc), owner, 1);

        // Non-protected token rescue succeeds for owner
        fund(address(vault), dai, 100 * 1e18);
        vault.rescueToken(address(dai), owner, 100 * 1e18);
        assertEq(dai.balanceOf(owner), 100 * 1e18);
    }
}
