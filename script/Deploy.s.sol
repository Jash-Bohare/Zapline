// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SwapExecutor} from "src/SwapExecutor.sol";
import {Zap} from "src/Zap.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {LPVault} from "src/LPVault.sol";
import {FlashSwap} from "src/FlashSwap.sol";
import {Constants} from "test/base/Constants.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";

contract DeployScript is Script {
    function run()
        external
        returns (SwapExecutor swapExecutor, Zap zap, TwapOracle oracle, LPVault vault, FlashSwap flashSwap)
    {
        address deployer = msg.sender;
        console.log("Deploying Zapline contracts from:", deployer);

        vm.startBroadcast();

        // 1. SwapExecutor
        swapExecutor = new SwapExecutor(Constants.V2_ROUTER);
        console.log("SwapExecutor deployed at:", address(swapExecutor));

        // 2. Zap
        zap = new Zap(Constants.V2_ROUTER);
        console.log("Zap deployed at:", address(zap));

        // 3. TwapOracle (30m window, 10m spacing, 24h max age)
        oracle = new TwapOracle(1800, 600, 86400);
        console.log("TwapOracle deployed at:", address(oracle));

        // 4. LPVault (USDC / WETH pair)
        address usdcWethPair = IUniswapV2Factory(Constants.V2_FACTORY).getPair(Constants.USDC, Constants.WETH);
        require(usdcWethPair != address(0), "USDC-WETH pair not found");

        vault = new LPVault(
            usdcWethPair,
            Constants.USDC,
            Constants.WETH,
            address(zap),
            address(oracle),
            "Zapline USDC-WETH LP Vault",
            "zvUSDC"
        );
        console.log("LPVault deployed at:", address(vault));

        // 5. FlashSwap (Uniswap V2 borrow venue, SushiSwap sell venue)
        flashSwap = new FlashSwap(Constants.V2_FACTORY, Constants.SUSHI_ROUTER);
        console.log("FlashSwap deployed at:", address(flashSwap));

        vm.stopBroadcast();
        console.log("All Zapline contracts deployed successfully.");
    }
}
