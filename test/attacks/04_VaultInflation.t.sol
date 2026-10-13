// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {LPVault} from "src/LPVault.sol";
import {Zap} from "src/Zap.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test-only mock: Naive vault with 0 virtual decimals offset (vulnerable to inflation)
contract NaiveVault is ERC4626 {
    using SafeERC20 for IERC20;

    constructor(IERC20 asset) ERC4626(asset) ERC20("Naive Vault", "nVAULT") {}

    // No virtual decimals offset (offset = 0)
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 0;
    }
}

contract VaultInflationAttackTest is ForkBase {
    using SafeERC20 for IERC20;

    NaiveVault internal naiveVault;
    LPVault internal secureVault;
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

        naiveVault = new NaiveVault(usdc);
        secureVault = new LPVault(
            usdcWethPair, address(usdc), address(weth), address(zap), address(oracle), "Secure Vault", "sVAULT"
        );
    }

    /// @notice Demonstrates how a naive vault with offset=0 is drained by first-depositor inflation
    function test_Attack04_NaiveVaultVulnerableToInflation() public {
        // 1. Attacker deposits 1 wei USDC -> receives 1 share
        fund(attacker, usdc, 1);
        vm.startPrank(attacker);
        usdc.forceApprove(address(naiveVault), 1);
        uint256 attackerShares = naiveVault.deposit(1, attacker);
        vm.stopPrank();
        assertEq(attackerShares, 1);

        // 2. Attacker donates 10,000 USDC directly to naiveVault
        fund(attacker, usdc, 10_000 * 1e6);
        vm.prank(attacker);
        usdc.transfer(address(naiveVault), 10_000 * 1e6);

        // TotalAssets = 10,000.000001 USDC, TotalSupply = 1 share

        // 3. Victim deposits 5,000 USDC
        fund(alice, usdc, 2_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(naiveVault), 2_000 * 1e6);
        uint256 victimShares = naiveVault.deposit(2_000 * 1e6, alice);
        vm.stopPrank();

        // Victim receives 0 shares because 5,000 * 1 / 10,000 rounds down to 0!
        assertEq(victimShares, 0, "Victim suffers 100% loss due to rounding down to 0 shares!");

        // 4. Attacker redeems their single share and steals victim's deposit!
        vm.prank(attacker);
        uint256 payout = naiveVault.redeem(attackerShares, attacker, attacker);

        // Attacker gets back 10,000 donation + 5,000 stolen = 15,000 USDC!
        assertEq(payout, 6_000 * 1e6 + 1);
        emit log_named_uint("Naive vault: Attacker profit from victim (USDC):", 2_000 * 1e6);
    }

    /// @notice Demonstrates how LPVault with virtual offset of 6 decimals completely mitigates the attack
    function test_Attack04_SecureVaultMitigatesInflation() public {
        // 1. Attacker deposits 1 USDC
        uint256 minDeposit = 1 * 1e6;
        fund(attacker, usdc, minDeposit);
        vm.startPrank(attacker);
        usdc.forceApprove(address(secureVault), minDeposit);
        uint256 attackerShares = secureVault.deposit(minDeposit, attacker);
        vm.stopPrank();

        // 2. Attacker donates 10,000 USDC worth of real LP tokens
        fund(attacker, usdc, 10_000 * 1e6);
        vm.startPrank(attacker);
        usdc.forceApprove(address(zap), 10_000 * 1e6);
        uint256 donateLp = zap.zapIn(usdcWethPair, address(usdc), 10_000 * 1e6, 0, attacker, block.timestamp);
        IERC20(usdcWethPair).transfer(address(secureVault), donateLp);
        vm.stopPrank();

        // 3. Victim deposits 5,000 USDC
        fund(alice, usdc, 2_000 * 1e6);
        vm.startPrank(alice);
        usdc.forceApprove(address(secureVault), 2_000 * 1e6);
        uint256 victimShares = secureVault.deposit(2_000 * 1e6, alice);
        vm.stopPrank();

        // Thanks to virtual offset of 10^6, victim receives ample non-zero shares!
        assertGt(victimShares, 0, "Victim receives fair shares, cannot be rounded to 0");

        // 4. Attacker attempts to redeem their share
        vm.prank(attacker);
        uint256 attackerPayout = secureVault.redeem(attackerShares, attacker, attacker);

        // Attacker invested 10,001 USDC and payout is LESS than invested amount
        assertLt(attackerPayout, minDeposit + 10_000 * 1e6, "Attacker cannot profit");

        // Victim redeems and recovers their capital safely
        vm.prank(alice);
        uint256 victimPayout = secureVault.redeem(victimShares, alice, alice);
        assertGt(victimPayout, (2_000 * 1e6 * 98) / 100, "Victim capital safely recovered");

        emit log_string("Secure vault: Virtual shares successfully protected victim capital!");
    }
}
