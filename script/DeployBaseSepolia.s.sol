// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console} from "forge-std/Script.sol";
import {SwapExecutor} from "src/SwapExecutor.sol";
import {Zap} from "src/Zap.sol";
import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {LPVault} from "src/LPVault.sol";
import {FlashSwap} from "src/FlashSwap.sol";
import {UniswapV2Router02} from "src/periphery/UniswapV2Router02.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";

contract DeployBaseSepoliaScript is Script {
    // Official Base Sepolia Addresses
    address public constant BASE_SEPOLIA_V2_FACTORY = 0x7Ae58f10f7849cA6F5fB71b7f45CB416c9204b1e;
    address public constant BASE_SEPOLIA_WETH = 0x4200000000000000000000000000000000000006;
    address public constant BASE_SEPOLIA_USDC = 0x036CbD53842c5426634e7929541eC2318f3dCF7e;
    address public constant BASE_SEPOLIA_USDC_WETH_PAIR = 0x0B9Ab53880be6fF805ebF8FBce515E5715ccE1bE;

    // Verified Pair Code Hash for Base Sepolia Factory
    bytes32 public constant BASE_SEPOLIA_PAIR_CODE_HASH =
        0x96e8ac4277198ff8b6f785478aa9a39f403cb768dd02cbee326c3e7da348845f;

    function run()
        external
        returns (
            UniswapV2Router02 router,
            UniswapV2Router02 sushiRouter,
            SwapExecutor swapExecutor,
            Zap zap,
            TwapOracle oracle,
            LPVault vault,
            FlashSwap flashSwap
        )
    {
        uint256 deployerPrivateKey = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("====================================================");
        console.log("Deploying Zapline Suite to Base Sepolia (Chain 84532)");
        console.log("Deployer Address:", deployer);
        console.log("====================================================");

        vm.startBroadcast(deployerPrivateKey);

        // 1. Deploy Primary UniswapV2Router02 for Base Sepolia
        router = new UniswapV2Router02(BASE_SEPOLIA_V2_FACTORY, BASE_SEPOLIA_WETH, BASE_SEPOLIA_PAIR_CODE_HASH);
        console.log("1. UniswapV2Router02 deployed at:", address(router));

        // 2. Deploy Secondary Router (SushiRouter) for Cross-Venue FlashSwap Arbitrage
        sushiRouter = new UniswapV2Router02(BASE_SEPOLIA_V2_FACTORY, BASE_SEPOLIA_WETH, BASE_SEPOLIA_PAIR_CODE_HASH);
        console.log("2. SushiRouter (Venue B) deployed at:", address(sushiRouter));

        // 3. Deploy SwapExecutor
        swapExecutor = new SwapExecutor(address(router));
        console.log("3. SwapExecutor deployed at:", address(swapExecutor));

        // 4. Deploy Zap
        zap = new Zap(address(router));
        console.log("4. Zap deployed at:", address(zap));

        // 5. Deploy TwapOracle (30m window, 10m spacing, 24h max age)
        oracle = new TwapOracle(1800, 600, 86400);
        console.log("5. TwapOracle deployed at:", address(oracle));

        // Seed initial TWAP observation for USDC-WETH pair
        try oracle.update(BASE_SEPOLIA_USDC_WETH_PAIR) {
            console.log("   -> Initial TWAP observation recorded for USDC-WETH pair");
        } catch {
            console.log("   -> TWAP observation skipped/failed (can be called post-deployment)");
        }

        // 6. Deploy LPVault on Base Sepolia USDC-WETH Pair
        vault = new LPVault(
            BASE_SEPOLIA_USDC_WETH_PAIR,
            BASE_SEPOLIA_USDC,
            BASE_SEPOLIA_WETH,
            address(zap),
            address(oracle),
            "Zapline USDC-WETH LP Vault",
            "zvUSDC"
        );
        console.log("6. LPVault deployed at:", address(vault));

        // 7. Deploy FlashSwap
        flashSwap = new FlashSwap(BASE_SEPOLIA_V2_FACTORY, address(sushiRouter));
        console.log("7. FlashSwap deployed at:", address(flashSwap));

        vm.stopBroadcast();

        console.log("====================================================");
        console.log("All Zapline contracts successfully deployed on Base Sepolia!");
        console.log("====================================================");
    }
}
