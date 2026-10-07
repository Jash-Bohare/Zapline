// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Constants} from "./Constants.sol";
import {IUniswapV2Factory} from "src/interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Router02} from "src/interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";

abstract contract ForkBase is Test {
    IUniswapV2Factory factory = IUniswapV2Factory(Constants.V2_FACTORY);
    IUniswapV2Router02 router = IUniswapV2Router02(Constants.V2_ROUTER);
    IERC20 usdc = IERC20(Constants.USDC);
    IERC20 weth = IERC20(Constants.WETH);
    IERC20 dai = IERC20(Constants.DAI);
    IERC20 usdt = IERC20(Constants.USDT);

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address attacker = makeAddr("attacker");
    address owner = makeAddr("owner");

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), vm.envUint("FORK_BLOCK"));
        vm.label(address(router), "V2Router");
        vm.label(address(factory), "V2Factory");
        vm.label(address(usdc), "USDC");
        vm.label(address(weth), "WETH");
        vm.label(address(dai), "DAI");
        vm.label(address(usdt), "USDT");
    }

    function fund(address who, IERC20 token, uint256 amount) internal {
        deal(address(token), who, amount);
    }

    function pairOf(address a, address b) internal view returns (IUniswapV2Pair) {
        return IUniswapV2Pair(factory.getPair(a, b));
    }
}
