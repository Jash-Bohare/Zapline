// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniswapV2Factory {
    function getPair(address a, address b) external view returns (address);
}
