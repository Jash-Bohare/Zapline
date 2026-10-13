// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {TwapOracle} from "src/oracle/TwapOracle.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Test-only mock: Secure lending pool relying on TwapOracle
contract FixedLender {
    using SafeERC20 for IERC20;

    IERC20 public immutable collateralToken; // WETH
    IERC20 public immutable debtToken; // USDC
    address public immutable pair; // WETH/USDC pair
    TwapOracle public immutable oracle;

    uint256 public constant LTV_BPS = 7500; // 75% LTV
    uint256 public constant BPS_DENOMINATOR = 10000;

    mapping(address => uint256) public userCollateral;
    mapping(address => uint256) public userDebt;

    error InsufficientCollateral();

    constructor(address _pair, address _collateral, address _debt, address _oracle) {
        pair = _pair;
        collateralToken = IERC20(_collateral);
        debtToken = IERC20(_debt);
        oracle = TwapOracle(_oracle);
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

    /// @notice SECURE VALUATION: Uses TwapOracle.consult
    function maxBorrowOf(address user) public view returns (uint256) {
        uint256 col = userCollateral[user];
        if (col == 0) return 0;

        uint256 colValueInDebt = oracle.consult(pair, address(collateralToken), col);
        return (colValueInDebt * LTV_BPS) / BPS_DENOMINATOR;
    }

    function positionOf(address user) external view returns (uint256 collateral, uint256 debt) {
        return (userCollateral[user], userDebt[user]);
    }
}
