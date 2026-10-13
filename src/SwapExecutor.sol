// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

contract SwapExecutor is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2Router02 public immutable router;
    IWETH public immutable weth;

    uint256 public constant MAX_HOPS = 4;

    event Swapped(
        address indexed user, address indexed to, address tokenIn, address tokenOut, uint256 amountIn, uint256 amountOut
    );

    error InvalidPath();
    error DeadlineExpired();
    error ZeroAmount();
    error InvalidRecipient();
    error UnexpectedETH();
    error ETHValueMismatch();
    error PairNotFound();
    error SlippageExceeded(uint256 actual, uint256 limit);

    constructor(address _router) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRecipient();
        router = IUniswapV2Router02(_router);
        weth = IWETH(router.WETH());
    }

    /// @notice Swap exact input of tokens for maximum tokens out
    function swapExactIn(address[] calldata path, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (amountIn == 0) revert ZeroAmount();
        _validatePath(path);
        _validateCommon(to, deadline);

        address tokenIn = path[0];
        address tokenOut = path[path.length - 1];
        uint256 received;
        {
            uint256 beforeBal = IERC20(tokenIn).balanceOf(address(this));
            IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
            received = IERC20(tokenIn).balanceOf(address(this)) - beforeBal;
        }
        if (received == 0) revert ZeroAmount();

        IERC20(tokenIn).forceApprove(address(router), received);
        amounts = router.swapExactTokensForTokens(received, minOut, path, to, deadline);
        IERC20(tokenIn).forceApprove(address(router), 0);

        uint256 amountOut = amounts[amounts.length - 1];
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);

        emit Swapped(msg.sender, to, tokenIn, tokenOut, received, amountOut);
    }

    /// @notice Swap tokens for exact amount of tokens out, refunding any unused input
    function swapExactOut(address[] calldata path, uint256 amountOut, uint256 maxIn, address to, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (amountOut == 0) revert ZeroAmount();
        if (maxIn == 0) revert ZeroAmount();
        _validatePath(path);
        _validateCommon(to, deadline);

        address tokenIn = path[0];
        uint256 beforeBal = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), maxIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - beforeBal;

        IERC20(tokenIn).forceApprove(address(router), received);
        amounts = router.swapTokensForExactTokens(amountOut, received, path, to, deadline);
        IERC20(tokenIn).forceApprove(address(router), 0);

        uint256 spent = amounts[0];
        if (spent > maxIn) revert SlippageExceeded(spent, maxIn);

        // Refund unused tokens to msg.sender
        if (received > spent) {
            IERC20(tokenIn).safeTransfer(msg.sender, received - spent);
        }

        address tokenOut = path[path.length - 1];
        emit Swapped(msg.sender, to, tokenIn, tokenOut, spent, amountOut);
    }

    /// @notice Swap exact ETH in for tokens out
    function swapExactETHIn(address[] calldata path, uint256 minOut, address to, uint256 deadline)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (msg.value == 0) revert ETHValueMismatch();
        _validatePath(path);
        _validateCommon(to, deadline);
        if (path[0] != address(weth)) revert InvalidPath();

        address tokenOut = path[path.length - 1];
        amounts = router.swapExactETHForTokens{value: msg.value}(minOut, path, to, deadline);
        uint256 amountOut = amounts[amounts.length - 1];
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);

        emit Swapped(msg.sender, to, address(weth), tokenOut, msg.value, amountOut);
    }

    /// @notice Swap exact tokens in for ETH out
    function swapExactInForETH(address[] calldata path, uint256 amountIn, uint256 minOut, address to, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256[] memory amounts)
    {
        if (amountIn == 0) revert ZeroAmount();
        _validatePath(path);
        _validateCommon(to, deadline);
        if (path[path.length - 1] != address(weth)) revert InvalidPath();

        address tokenIn = path[0];
        uint256 beforeBal = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - beforeBal;
        if (received == 0) revert ZeroAmount();

        IERC20(tokenIn).forceApprove(address(router), received);
        amounts = router.swapExactTokensForETH(received, minOut, path, to, deadline);
        IERC20(tokenIn).forceApprove(address(router), 0);

        uint256 amountOut = amounts[amounts.length - 1];
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);

        emit Swapped(msg.sender, to, path[0], address(weth), received, amountOut);
    }

    /// @notice Read-only quote for exact-in swap
    function quoteExactIn(address[] calldata path, uint256 amountIn) external view returns (uint256[] memory amounts) {
        _validatePath(path);
        return router.getAmountsOut(amountIn, path);
    }

    /// @notice Read-only quote for exact-out swap
    function quoteExactOut(address[] calldata path, uint256 amountOut)
        external
        view
        returns (uint256[] memory amounts)
    {
        _validatePath(path);
        return router.getAmountsIn(amountOut, path);
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        IERC20(token).safeTransfer(to, amount);
    }

    function rescueETH(address payable to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert InvalidRecipient();
        (bool success,) = to.call{value: amount}("");
        require(success, "ETH transfer failed");
    }

    receive() external payable {
        if (msg.sender != address(weth)) revert UnexpectedETH();
    }

    function _validateCommon(address to, uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
    }

    function _validatePath(address[] calldata path) internal view {
        if (path.length < 2 || path.length > MAX_HOPS) revert InvalidPath();
        for (uint256 i = 0; i < path.length; i++) {
            if (path[i] == address(0)) revert InvalidPath();
        }
        address factory = router.factory();
        for (uint256 i = 0; i < path.length - 1; i++) {
            if (path[i] == path[i + 1]) revert InvalidPath();
            address pair = IUniswapV2Factory(factory).getPair(path[i], path[i + 1]);
            if (pair == address(0)) revert PairNotFound();
        }
    }
}
