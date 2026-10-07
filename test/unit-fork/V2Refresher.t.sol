// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ForkBase} from "test/base/ForkBase.sol";
import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";

contract V2Refresher is ForkBase {
    function testSmoke() public {
        IUniswapV2Pair pair = pairOf(address(usdc), address(weth));
        assertTrue(address(pair) != address(0));

        (uint112 r0, uint112 r1,) = pair.getReserves();
        assertGt(r0, 0);
        assertGt(r1, 0);
    }
}
