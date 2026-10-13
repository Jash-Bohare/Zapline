// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {ZapMath} from "./libraries/ZapMath.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

contract Zap is Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2Router02 public immutable router;
    IUniswapV2Factory public immutable factory;
    IWETH public immutable weth;

    event ZappedIn(
        address indexed user,
        address indexed pair,
        address tokenIn,
        uint256 amountIn,
        uint256 lpOut,
        uint256 dust0,
        uint256 dust1
    );

    event ZappedOut(address indexed user, address indexed pair, address tokenOut, uint256 lpIn, uint256 amountOut);

    error InvalidToken();
    error EmptyPool();
    error UnexpectedETH();
    error PairNotFound();
    error SlippageExceeded(uint256 actual, uint256 limit);
    error DeadlineExpired();
    error ZeroAmount();
    error InvalidRecipient();

    constructor(address _router) Ownable(msg.sender) {
        if (_router == address(0)) revert InvalidRecipient();
        router = IUniswapV2Router02(_router);
        factory = IUniswapV2Factory(router.factory());
        weth = IWETH(router.WETH());
    }

    /// @notice Zap a single ERC20 token into Uniswap V2 LP tokens
    function zapIn(address pair, address tokenIn, uint256 amountIn, uint256 minLpOut, address to, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 lpOut)
    {
        if (amountIn == 0) revert ZeroAmount();
        _validateCommon(to, deadline);
        address tokenOut = _validatePair(pair, tokenIn);

        uint256 beforeIn = IERC20(tokenIn).balanceOf(address(this));
        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        uint256 received = IERC20(tokenIn).balanceOf(address(this)) - beforeIn;
        if (received == 0) revert ZeroAmount();

        lpOut = _executeZapIn(pair, tokenIn, tokenOut, received, minLpOut, to, deadline);
    }

    /// @notice Zap native ETH into Uniswap V2 LP tokens for a WETH pair
    function zapInETH(address pair, uint256 minLpOut, address to, uint256 deadline)
        external
        payable
        whenNotPaused
        nonReentrant
        returns (uint256 lpOut)
    {
        if (msg.value == 0) revert ZeroAmount();
        _validateCommon(to, deadline);
        address tokenIn = address(weth);
        address tokenOut = _validatePair(pair, tokenIn);

        weth.deposit{value: msg.value}();
        lpOut = _executeZapIn(pair, tokenIn, tokenOut, msg.value, minLpOut, to, deadline);
    }

    /// @notice Zap LP tokens out to a single ERC20 token
    function zapOut(address pair, uint256 lpAmount, address tokenOut, uint256 minOut, address to, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amountOut)
    {
        _validateCommon(to, deadline);
        amountOut = _executeZapOut(pair, lpAmount, tokenOut, minOut, deadline);
        IERC20(tokenOut).safeTransfer(to, amountOut);
        emit ZappedOut(msg.sender, pair, tokenOut, lpAmount, amountOut);
    }

    /// @notice Zap LP tokens out to native ETH
    function zapOutETH(address pair, uint256 lpAmount, uint256 minOut, address payable to, uint256 deadline)
        external
        whenNotPaused
        nonReentrant
        returns (uint256 amountOut)
    {
        _validateCommon(to, deadline);
        amountOut = _executeZapOut(pair, lpAmount, address(weth), minOut, deadline);
        weth.withdraw(amountOut);
        (bool success,) = to.call{value: amountOut}("");
        require(success, "ETH transfer failed");
        emit ZappedOut(msg.sender, pair, address(weth), lpAmount, amountOut);
    }

    /// @notice Quote the optimal swap amount for a given tokenIn and amountIn
    function quoteZapIn(address pair, address tokenIn, uint256 amountIn) external view returns (uint256 swapAmount) {
        _validatePair(pair, tokenIn);
        (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
        if (r0 == 0 || r1 == 0) revert EmptyPool();

        address t0 = IUniswapV2Pair(pair).token0();
        uint256 rIn = tokenIn == t0 ? uint256(r0) : uint256(r1);
        return ZapMath.optimalSwapAmount(rIn, amountIn);
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

    function _executeZapIn(
        address pair,
        address tokenIn,
        address tokenOut,
        uint256 received,
        uint256 minLpOut,
        address to,
        uint256 deadline
    ) internal returns (uint256 lpOut) {
        uint256 swapAmt;
        {
            (uint112 r0, uint112 r1,) = IUniswapV2Pair(pair).getReserves();
            if (r0 == 0 || r1 == 0) revert EmptyPool();
            address t0 = IUniswapV2Pair(pair).token0();
            uint256 rIn = tokenIn == t0 ? uint256(r0) : uint256(r1);
            swapAmt = ZapMath.optimalSwapAmount(rIn, received);
        }
        if (swapAmt == 0 || swapAmt >= received) revert ZeroAmount();

        uint256 gotOut;
        {
            address[] memory path = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;

            uint256 beforeOut = IERC20(tokenOut).balanceOf(address(this));
            IERC20(tokenIn).forceApprove(address(router), swapAmt);
            router.swapExactTokensForTokens(swapAmt, 0, path, address(this), deadline);
            IERC20(tokenIn).forceApprove(address(router), 0);
            gotOut = IERC20(tokenOut).balanceOf(address(this)) - beforeOut;
        }

        {
            uint256 remainingIn = received - swapAmt;
            IERC20(tokenIn).forceApprove(address(router), remainingIn);
            IERC20(tokenOut).forceApprove(address(router), gotOut);
            (,, lpOut) = router.addLiquidity(tokenIn, tokenOut, remainingIn, gotOut, 0, 0, to, deadline);
            IERC20(tokenIn).forceApprove(address(router), 0);
            IERC20(tokenOut).forceApprove(address(router), 0);
        }

        if (lpOut < minLpOut) revert SlippageExceeded(lpOut, minLpOut);

        uint256 dustIn = IERC20(tokenIn).balanceOf(address(this));
        uint256 dustOut = IERC20(tokenOut).balanceOf(address(this));
        if (dustIn > 0) {
            IERC20(tokenIn).safeTransfer(msg.sender, dustIn);
        }
        if (dustOut > 0) {
            IERC20(tokenOut).safeTransfer(msg.sender, dustOut);
        }

        emit ZappedIn(msg.sender, pair, tokenIn, received, lpOut, dustIn, dustOut);
    }

    function _executeZapOut(address pair, uint256 lpAmount, address tokenOut, uint256 minOut, uint256 deadline)
        internal
        returns (uint256 amountOut)
    {
        if (lpAmount == 0) revert ZeroAmount();
        (address otherToken, uint256 directOut, uint256 otherAmt) =
            _removeLiquidityAndGetAmounts(pair, tokenOut, lpAmount, deadline);

        uint256 swappedOut = 0;
        if (otherAmt > 0) {
            swappedOut = _swapOtherForTokenOut(otherToken, tokenOut, otherAmt, deadline);
        }

        amountOut = directOut + swappedOut;
        if (amountOut < minOut) revert SlippageExceeded(amountOut, minOut);
    }

    function _removeLiquidityAndGetAmounts(address pair, address tokenOut, uint256 lpAmount, uint256 deadline)
        private
        returns (address otherToken, uint256 directOut, uint256 otherAmt)
    {
        otherToken = _validatePair(pair, tokenOut);
        IERC20(pair).safeTransferFrom(msg.sender, address(this), lpAmount);
        IERC20(pair).forceApprove(address(router), lpAmount);

        address t0 = IUniswapV2Pair(pair).token0();
        address t1 = IUniswapV2Pair(pair).token1();
        (uint256 a0, uint256 a1) = router.removeLiquidity(t0, t1, lpAmount, 0, 0, address(this), deadline);
        IERC20(pair).forceApprove(address(router), 0);

        directOut = tokenOut == t0 ? a0 : a1;
        otherAmt = tokenOut == t0 ? a1 : a0;
    }

    function _swapOtherForTokenOut(address otherToken, address tokenOut, uint256 otherAmt, uint256 deadline)
        private
        returns (uint256 gotOut)
    {
        address[] memory path = new address[](2);
        path[0] = otherToken;
        path[1] = tokenOut;

        uint256 beforeBal = IERC20(tokenOut).balanceOf(address(this));
        IERC20(otherToken).forceApprove(address(router), otherAmt);
        router.swapExactTokensForTokens(otherAmt, 0, path, address(this), deadline);
        IERC20(otherToken).forceApprove(address(router), 0);
        gotOut = IERC20(tokenOut).balanceOf(address(this)) - beforeBal;
    }

    function _validateCommon(address to, uint256 deadline) internal view {
        if (block.timestamp > deadline) revert DeadlineExpired();
        if (to == address(0) || to == address(this)) revert InvalidRecipient();
    }

    function _validatePair(address pair, address token) internal view returns (address otherToken) {
        if (pair == address(0) || pair.code.length == 0) revert PairNotFound();
        address t0 = IUniswapV2Pair(pair).token0();
        address t1 = IUniswapV2Pair(pair).token1();
        if (factory.getPair(t0, t1) != pair) revert PairNotFound();
        if (token != t0 && token != t1) revert InvalidToken();
        otherToken = token == t0 ? t1 : t0;
    }
}
