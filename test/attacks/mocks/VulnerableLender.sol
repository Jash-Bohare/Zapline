// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV2Pair} from "src/interfaces/IUniswapV2Pair.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test-only mock: Vulnerable lending pool relying on spot reserves
contract VulnerableLender {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken; // WETH
    IERC20 public immutable debtToken; // USDC
    IUniswapV2Pair public immutable pair; // WETH/USDC pair

    uint256 public constant LTV_BPS = 7500; // 75% LTV
    uint256 public constant BPS_DENOMINATOR = 10000;

    mapping(address => uint256) public userCollateral;
    mapping(address => uint256) public userDebt;

    error InsufficientCollateral();
    error TransferFailed();

    constructor(address _pair, address _collateral, address _debt) {
        pair = IUniswapV2Pair(_pair);
        collateralToken = IERC20(_collateral);
        debtToken = IERC20(_debt);
    }

    function depositCollateral(uint256 amount) external {
        collateralToken.safeTransferFrom(msg.sender, address(this), amount);
        userCollateral[msg.sender] += amount;
    }

    function borrow(uint256 amount) external {
        uint256 maxBorrow = maxBorrowOf(msg.sender);
        if (userDebt[msg.sender] + amount > maxBorrow) revert InsufficientCollateral();

        userDebt[msg.sender] += amount;
        debtToken.safeTransfer(msg.sender, amount);
    }

    /// @notice VULNERABILITY: Instant spot price from getReserves()
    function maxBorrowOf(address user) public view returns (uint256) {
        uint256 col = userCollateral[user];
        if (col == 0) return 0;

        (uint112 r0, uint112 r1,) = pair.getReserves();
        address t0 = pair.token0();
        // col is WETH (18 decimals), debt is USDC (6 decimals)
        uint256 rWeth = t0 == address(collateralToken) ? uint256(r0) : uint256(r1);
        uint256 rUsdc = t0 == address(debtToken) ? uint256(r0) : uint256(r1);

        // Spot valuation of col: (col * rUsdc) / rWeth
        uint256 colValueInDebt = (col * rUsdc) / rWeth;
        return (colValueInDebt * LTV_BPS) / BPS_DENOMINATOR;
    }

    function positionOf(address user) external view returns (uint256 collateral, uint256 debt) {
        return (userCollateral[user], userDebt[user]);
    }
}
