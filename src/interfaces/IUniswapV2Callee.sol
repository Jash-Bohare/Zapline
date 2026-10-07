// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniswapV2Callee {
    function uniswapV2Call(address sender, uint256 a0, uint256 a1, bytes calldata data) external;
}
