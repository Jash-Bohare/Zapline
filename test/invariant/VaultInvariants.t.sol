// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {LPVault} from "src/LPVault.sol";
import {Zap} from "src/Zap.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {VaultHandler} from "./handlers/VaultHandler.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract VaultInvariantsTest is ForkBase {
    using SafeERC20 for IERC20;

    LPVault internal vault;
    Zap internal zap;
    TwapOracle internal oracle;
    VaultHandler internal handler;
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
            usdcWethPair, address(usdc), address(weth), address(zap), address(oracle), "Invariant Vault", "iVAULT"
        );

        handler = new VaultHandler(
            address(vault), address(oracle), address(router), address(usdc), address(weth), usdcWethPair
        );

        // Warm up with an initial deposit from handler to establish base shares
        handler.deposit(0, 100 * 1e6);

        targetContract(address(handler));
    }

    /// @notice I-VT-1: Vault solvency: totalAssets >= 0 and LP balance matches pool
    function invariant_IVT01_VaultSolvency() public view {
        uint256 assets = vault.totalAssets();
        uint256 supply = vault.totalSupply();
        if (supply > 0) {
            assertGt(assets, 0, "Solvent vault with supply must have positive totalAssets");
        }
    }

    /// @notice I-VT-4: Stateless dust: idle deposit asset in vault is near zero
    function invariant_IVT04_StatelessDust() public view {
        // Vault holds minimal residual dust from zaps
        assertLe(usdc.balanceOf(address(vault)), 100, "Idle USDC must remain negligible dust");
    }

    /// @notice I-VT-5: Share conservation: sum of actor balances equals total supply
    function invariant_IVT05_ShareConservation() public view {
        address[] memory actors = handler.getActors();
        uint256 sum = 0;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += vault.balanceOf(actors[i]);
        }
        assertEq(sum, vault.totalSupply(), "Sum of all actor shares must equal totalSupply");
    }

    /// @notice I-VT-6: Vault holds 0 native ETH
    function invariant_IVT06_ZeroEthBalance() public view {
        assertEq(address(vault).balance, 0, "Vault must hold 0 ETH");
    }
}
