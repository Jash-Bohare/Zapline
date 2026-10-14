// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {IUniswapV2Factory} from "../interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "../interfaces/IUniswapV2Router02.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {V2Library} from "../libraries/V2Library.sol";

contract UniswapV2Router02 is IUniswapV2Router02 {
    using SafeERC20 for IERC20;

    address public immutable override factory;
    address public immutable override WETH;
    bytes32 public immutable pairCodeHash;

    struct AddLiquidityParams {
        address tokenA;
        address tokenB;
        uint256 amountADesired;
        uint256 amountBDesired;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
    }

    struct RemoveLiquidityParams {
        address tokenA;
        address tokenB;
        uint256 liquidity;
        uint256 amountAMin;
        uint256 amountBMin;
        address to;
    }

    modifier ensure(uint256 deadline) {
        require(deadline >= block.timestamp, "UniswapV2Router: EXPIRED");
        _;
    }

    constructor(address _factory, address _weth, bytes32 _pairCodeHash) {
        factory = _factory;
        WETH = _weth;
        pairCodeHash = _pairCodeHash;
    }

    receive() external payable {
        assert(msg.sender == WETH);
    }

    function pairFor(address tokenA, address tokenB) public view returns (address pair) {
        if (pairCodeHash != bytes32(0)) {
            (address token0, address token1) = V2Library.sortTokens(tokenA, tokenB);
            pair = address(
                uint160(
                    uint256(
                        keccak256(
                            abi.encodePacked(
                                hex"ff", factory, keccak256(abi.encodePacked(token0, token1)), pairCodeHash
                            )
                        )
                    )
                )
            );
        } else {
            pair = IUniswapV2Factory(factory).getPair(tokenA, tokenB);
        }
    }

    function _calculateLiquidityAmounts(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin
    ) internal view returns (uint256 amountA, uint256 amountB) {
        (uint256 reserveA, uint256 reserveB,) = V2Library.getReservesSorted(factory, tokenA, tokenB);
        if (reserveA == 0 && reserveB == 0) {
            return (amountADesired, amountBDesired);
        }
        uint256 amountBOptimal = (amountADesired * reserveB) / reserveA;
        if (amountBOptimal <= amountBDesired) {
            require(amountBOptimal >= amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
            return (amountADesired, amountBOptimal);
        } else {
            uint256 amountAOptimal = (amountBDesired * reserveA) / reserveB;
            assert(amountAOptimal <= amountADesired);
            require(amountAOptimal >= amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
            return (amountAOptimal, amountBDesired);
        }
    }

    function _executeAddLiquidity(AddLiquidityParams memory p)
        internal
        returns (uint256 amountA, uint256 amountB, uint256 liquidity)
    {
        if (IUniswapV2Factory(factory).getPair(p.tokenA, p.tokenB) == address(0)) {
            IUniswapV2Factory(factory).createPair(p.tokenA, p.tokenB);
        }
        (amountA, amountB) = _calculateLiquidityAmounts(
            p.tokenA, p.tokenB, p.amountADesired, p.amountBDesired, p.amountAMin, p.amountBMin
        );
        address pair = pairFor(p.tokenA, p.tokenB);
        IERC20(p.tokenA).safeTransferFrom(msg.sender, pair, amountA);
        IERC20(p.tokenB).safeTransferFrom(msg.sender, pair, amountB);
        liquidity = IUniswapV2Pair(pair).mint(p.to);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external override ensure(deadline) returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        return _executeAddLiquidity(
            AddLiquidityParams(tokenA, tokenB, amountADesired, amountBDesired, amountAMin, amountBMin, to)
        );
    }

    function _executeRemoveLiquidity(RemoveLiquidityParams memory p)
        internal
        returns (uint256 amountA, uint256 amountB)
    {
        address pair = pairFor(p.tokenA, p.tokenB);
        IERC20(pair).safeTransferFrom(msg.sender, pair, p.liquidity);
        (uint256 amount0, uint256 amount1) = IUniswapV2Pair(pair).burn(p.to);
        (address token0,) = V2Library.sortTokens(p.tokenA, p.tokenB);
        (amountA, amountB) = p.tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= p.amountAMin, "UniswapV2Router: INSUFFICIENT_A_AMOUNT");
        require(amountB >= p.amountBMin, "UniswapV2Router: INSUFFICIENT_B_AMOUNT");
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) public override ensure(deadline) returns (uint256 amountA, uint256 amountB) {
        return _executeRemoveLiquidity(RemoveLiquidityParams(tokenA, tokenB, liquidity, amountAMin, amountBMin, to));
    }

    function _swap(uint256[] memory amounts, address[] memory path, address _to) internal {
        for (uint256 i = 0; i < path.length - 1; i++) {
            (address input, address output) = (path[i], path[i + 1]);
            (address token0,) = V2Library.sortTokens(input, output);
            uint256 amountOut = amounts[i + 1];
            (uint256 amount0Out, uint256 amount1Out) =
                input == token0 ? (uint256(0), amountOut) : (amountOut, uint256(0));
            address to = i < path.length - 2 ? pairFor(output, path[i + 2]) : _to;
            IUniswapV2Pair(pairFor(input, output)).swap(amount0Out, amount1Out, to, new bytes(0));
        }
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override ensure(deadline) returns (uint256[] memory amounts) {
        amounts = V2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, pairFor(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapTokensForExactTokens(
        uint256 amountOut,
        uint256 amountInMax,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override ensure(deadline) returns (uint256[] memory amounts) {
        amounts = V2Library.getAmountsIn(factory, amountOut, path);
        require(amounts[0] <= amountInMax, "UniswapV2Router: EXCESSIVE_INPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, pairFor(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapExactETHForTokens(uint256 amountOutMin, address[] calldata path, address to, uint256 deadline)
        external
        payable
        override
        ensure(deadline)
        returns (uint256[] memory amounts)
    {
        require(path[0] == WETH, "UniswapV2Router: INVALID_PATH");
        amounts = V2Library.getAmountsOut(factory, msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        IWETH(WETH).deposit{value: amounts[0]}();
        IERC20(WETH).safeTransfer(pairFor(path[0], path[1]), amounts[0]);
        _swap(amounts, path, to);
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external override ensure(deadline) returns (uint256[] memory amounts) {
        require(path[path.length - 1] == WETH, "UniswapV2Router: INVALID_PATH");
        amounts = V2Library.getAmountsOut(factory, amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "UniswapV2Router: INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[0]).safeTransferFrom(msg.sender, pairFor(path[0], path[1]), amounts[0]);
        _swap(amounts, path, address(this));
        IWETH(WETH).withdraw(amounts[amounts.length - 1]);
        (bool success,) = to.call{value: amounts[amounts.length - 1]}("");
        require(success, "UniswapV2Router: ETH_TRANSFER_FAILED");
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        return V2Library.getAmountsOut(factory, amountIn, path);
    }

    function getAmountsIn(uint256 amountOut, address[] calldata path)
        external
        view
        override
        returns (uint256[] memory amounts)
    {
        return V2Library.getAmountsIn(factory, amountOut, path);
    }
}
