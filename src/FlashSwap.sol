// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Router02} from "./interfaces/IUniswapV2Router02.sol";
import {IUniswapV2Callee} from "./interfaces/IUniswapV2Callee.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";

contract FlashSwap is IUniswapV2Callee, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2Factory public immutable factory; // Borrow venue (Uniswap V2)
    IUniswapV2Router02 public immutable sellRouter; // Sell venue (e.g. SushiSwap)

    address private _activePair;

    event FlashSwapExecuted(
        address indexed pair,
        address indexed borrowToken,
        uint256 borrowed,
        uint256 repaid,
        uint256 profit,
        address indexed recipient
    );

    error UnauthorizedCaller();
    error UnauthorizedSender();
    error Unprofitable(uint256 got, uint256 needed);
    error InvalidBorrow();
    error PairNotFound();

    struct CallbackData {
        address borrowToken;
        address repayToken;
        uint256 borrowAmount;
        uint256 repayAmount;
        uint256 minProfit;
        address recipient;
    }

    constructor(address _factory, address _sellRouter) {
        if (_factory == address(0) || _sellRouter == address(0)) revert InvalidBorrow();
        factory = IUniswapV2Factory(_factory);
        sellRouter = IUniswapV2Router02(_sellRouter);
    }

    /// @notice Initiates a flash swap arbitrage borrowing from Uniswap V2 and repaying in the OTHER token
    function executeArb(
        address borrowPair,
        address borrowToken,
        uint256 borrowAmount,
        uint256 minProfit,
        address profitRecipient
    ) external nonReentrant returns (uint256 profit) {
        if (borrowPair == address(0) || profitRecipient == address(0) || profitRecipient == address(this)) {
            revert InvalidBorrow();
        }
        if (borrowPair.code.length == 0) revert PairNotFound();

        address repayToken;
        bytes memory data;
        {
            address token0 = IUniswapV2Pair(borrowPair).token0();
            address token1 = IUniswapV2Pair(borrowPair).token1();
            if (factory.getPair(token0, token1) != borrowPair) revert PairNotFound();
            if (borrowToken != token0 && borrowToken != token1) revert InvalidBorrow();

            (uint112 r0, uint112 r1,) = IUniswapV2Pair(borrowPair).getReserves();
            uint256 rBorrow = borrowToken == token0 ? uint256(r0) : uint256(r1);
            uint256 rRepay = borrowToken == token0 ? uint256(r1) : uint256(r0);
            if (borrowAmount == 0 || borrowAmount >= rBorrow) revert InvalidBorrow();

            repayToken = borrowToken == token0 ? token1 : token0;
            uint256 repayAmount = (rRepay * borrowAmount * 1000) / ((rBorrow - borrowAmount) * 997) + 1;

            data = abi.encode(
                CallbackData({
                    borrowToken: borrowToken,
                    repayToken: repayToken,
                    borrowAmount: borrowAmount,
                    repayAmount: repayAmount,
                    minProfit: minProfit,
                    recipient: profitRecipient
                })
            );
        }

        uint256 beforeBal = IERC20(repayToken).balanceOf(profitRecipient);

        _activePair = borrowPair;
        {
            address t0 = IUniswapV2Pair(borrowPair).token0();
            uint256 a0 = borrowToken == t0 ? borrowAmount : 0;
            uint256 a1 = borrowToken == t0 ? 0 : borrowAmount;
            IUniswapV2Pair(borrowPair).swap(a0, a1, address(this), data);
        }
        _activePair = address(0);

        profit = IERC20(repayToken).balanceOf(profitRecipient) - beforeBal;
    }

    /// @notice Initiates a flash swap arbitrage borrowing and repaying in the SAME token
    function executeArbSameToken(
        address borrowPair,
        address borrowToken,
        uint256 borrowAmount,
        uint256 minProfit,
        address profitRecipient
    ) external nonReentrant returns (uint256 profit) {
        if (borrowPair == address(0) || profitRecipient == address(0) || profitRecipient == address(this)) {
            revert InvalidBorrow();
        }
        if (borrowPair.code.length == 0) revert PairNotFound();

        bytes memory data;
        {
            address token0 = IUniswapV2Pair(borrowPair).token0();
            address token1 = IUniswapV2Pair(borrowPair).token1();
            if (factory.getPair(token0, token1) != borrowPair) revert PairNotFound();
            if (borrowToken != token0 && borrowToken != token1) revert InvalidBorrow();

            (uint112 r0, uint112 r1,) = IUniswapV2Pair(borrowPair).getReserves();
            uint256 rBorrow = borrowToken == token0 ? uint256(r0) : uint256(r1);
            if (borrowAmount == 0 || borrowAmount >= rBorrow) revert InvalidBorrow();

            uint256 repayAmount = (borrowAmount * 1000) / 997 + 1;

            data = abi.encode(
                CallbackData({
                    borrowToken: borrowToken,
                    repayToken: borrowToken,
                    borrowAmount: borrowAmount,
                    repayAmount: repayAmount,
                    minProfit: minProfit,
                    recipient: profitRecipient
                })
            );
        }

        uint256 beforeBal = IERC20(borrowToken).balanceOf(profitRecipient);

        _activePair = borrowPair;
        {
            address t0 = IUniswapV2Pair(borrowPair).token0();
            uint256 a0 = borrowToken == t0 ? borrowAmount : 0;
            uint256 a1 = borrowToken == t0 ? 0 : borrowAmount;
            IUniswapV2Pair(borrowPair).swap(a0, a1, address(this), data);
        }
        _activePair = address(0);

        profit = IERC20(borrowToken).balanceOf(profitRecipient) - beforeBal;
    }

    /// @notice Uniswap V2 flash swap callback
    function uniswapV2Call(address sender, uint256, uint256, bytes calldata data) external override {
        // SECURITY CHECKS (FR-FS-3, Attack 3 fix)
        if (msg.sender != _activePair) revert UnauthorizedCaller();
        if (sender != address(this)) revert UnauthorizedSender();

        {
            address t0 = IUniswapV2Pair(msg.sender).token0();
            address t1 = IUniswapV2Pair(msg.sender).token1();
            if (factory.getPair(t0, t1) != msg.sender) revert UnauthorizedCaller();
        }

        CallbackData memory params = abi.decode(data, (CallbackData));

        if (IERC20(params.borrowToken).balanceOf(address(this)) < params.borrowAmount) {
            revert InvalidBorrow();
        }

        uint256 gotRepayToken;
        if (params.borrowToken != params.repayToken) {
            gotRepayToken = _sellOnRouter(params.borrowToken, params.repayToken, params.borrowAmount);
        } else {
            gotRepayToken = IERC20(params.borrowToken).balanceOf(address(this));
        }

        if (gotRepayToken < params.repayAmount + params.minProfit) {
            revert Unprofitable(gotRepayToken, params.repayAmount + params.minProfit);
        }

        // Repay the V2 pair
        IERC20(params.repayToken).safeTransfer(msg.sender, params.repayAmount);

        // Forward profit to recipient
        uint256 profit = gotRepayToken - params.repayAmount;
        if (profit > 0) {
            IERC20(params.repayToken).safeTransfer(params.recipient, profit);
        }

        emit FlashSwapExecuted(
            msg.sender, params.borrowToken, params.borrowAmount, params.repayAmount, profit, params.recipient
        );
    }

    function _sellOnRouter(address fromToken, address toToken, uint256 amount) internal returns (uint256 got) {
        IERC20(fromToken).forceApprove(address(sellRouter), amount);
        address[] memory path = new address[](2);
        path[0] = fromToken;
        path[1] = toToken;

        uint256 beforeBal = IERC20(toToken).balanceOf(address(this));
        sellRouter.swapExactTokensForTokens(amount, 0, path, address(this), block.timestamp);
        IERC20(fromToken).forceApprove(address(sellRouter), 0);
        got = IERC20(toToken).balanceOf(address(this)) - beforeBal;
    }
}
