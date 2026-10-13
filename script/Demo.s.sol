// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SwapExecutor} from "src/SwapExecutor.sol";
import {Zap} from "src/Zap.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {LPVault} from "src/LPVault.sol";
import {FlashSwap} from "src/FlashSwap.sol";
import {Constants} from "test/base/Constants.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract DemoScript is Script {
    using SafeERC20 for IERC20;

    function run() external {
        address user = msg.sender;
        console.log("Running Zapline end-to-end demo for user:", user);

        vm.startBroadcast();

        // 1. Deploy system contracts
        SwapExecutor swapExecutor = new SwapExecutor(Constants.V2_ROUTER);
        Zap zap = new Zap(Constants.V2_ROUTER);
        TwapOracle oracle = new TwapOracle(1800, 600, 86400);

        address usdcWethPair = IUniswapV2Factory(Constants.V2_FACTORY).getPair(Constants.USDC, Constants.WETH);

        // Seed oracle with an observation
        oracle.update(usdcWethPair);

        LPVault vault = new LPVault(
            usdcWethPair,
            Constants.USDC,
            Constants.WETH,
            address(zap),
            address(oracle),
            "Zapline USDC-WETH LP Vault",
            "zvUSDC"
        );

        FlashSwap flashSwap = new FlashSwap(Constants.V2_FACTORY, Constants.SUSHI_ROUTER);

        console.log("--- System Deployment Complete ---");
        console.log("SwapExecutor:", address(swapExecutor));
        console.log("Zap:         ", address(zap));
        console.log("TwapOracle:  ", address(oracle));
        console.log("LPVault:     ", address(vault));
        console.log("FlashSwap:   ", address(flashSwap));

        vm.stopBroadcast();
    }
}
