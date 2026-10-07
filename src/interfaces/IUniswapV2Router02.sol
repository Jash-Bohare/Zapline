// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IUniswapV2Router02 {
    function factory() external view returns (address);

    function WETH() external view returns (address);

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory);

    function getAmountsIn(uint256 amountOut, address[] calldata path) external view returns (uint256[] memory);

    function swapExactTokensForTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);

    function swapTokensForExactTokens(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);

    function swapExactETHForTokens(uint256, address[] calldata, address, uint256)
        external
        payable
        returns (uint256[] memory);

    function swapExactTokensForETH(uint256, uint256, address[] calldata, address, uint256)
        external
        returns (uint256[] memory);

    function addLiquidity(address, address, uint256, uint256, uint256, uint256, address, uint256)
        external
        returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    function removeLiquidity(address, address, uint256, uint256, uint256, address, uint256)
        external
        returns (uint256 amountA, uint256 amountB);
}
