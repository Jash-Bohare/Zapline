// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ERC4626} from "openzeppelin-contracts/token/ERC20/extensions/ERC4626.sol";
import {ERC20} from "openzeppelin-contracts/token/ERC20/ERC20.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "openzeppelin-contracts/access/Ownable.sol";
import {Pausable} from "openzeppelin-contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "openzeppelin-contracts/utils/ReentrancyGuard.sol";
import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

import {IUniswapV2Pair} from "./interfaces/IUniswapV2Pair.sol";
import {IUniswapV2Factory} from "./interfaces/IUniswapV2Factory.sol";
import {Zap} from "./Zap.sol";
import {TwapOracle} from "./oracle/TwapOracle.sol";

contract LPVault is ERC4626, Ownable, Pausable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IUniswapV2Pair public immutable pair;
    IERC20 public immutable depositToken; // Asset D
    IERC20 public immutable otherToken; // Asset O
    Zap public immutable zap;
    TwapOracle public immutable oracle;

    error ExactWithdrawUnsupported();
    error ExactMintUnsupported();
    error ProtectedToken();
    error InvalidRecipient();
    error ZeroAmount();
    error SlippageExceeded(uint256 actual, uint256 min);
    error InvalidPair();

    constructor(
        address _pair,
        address _asset,
        address _otherToken,
        address _zap,
        address _oracle,
        string memory _name,
        string memory _symbol
    ) ERC4626(IERC20(_asset)) ERC20(_name, _symbol) Ownable(msg.sender) {
        if (_pair == address(0) || _zap == address(0) || _oracle == address(0)) {
            revert InvalidRecipient();
        }
        pair = IUniswapV2Pair(_pair);
        depositToken = IERC20(_asset);
        otherToken = IERC20(_otherToken);
        zap = Zap(payable(_zap));
        oracle = TwapOracle(_oracle);

        address t0 = pair.token0();
        address t1 = pair.token1();
        if (!((t0 == _asset && t1 == _otherToken) || (t0 == _otherToken && t1 == _asset))) {
            revert InvalidPair();
        }
    }

    /// @notice Virtual share offset of 6 decimals to protect against first-depositor inflation attacks
    function _decimalsOffset() internal view virtual override returns (uint8) {
        return 6;
    }

    /// @notice Returns the total assets in units of deposit token using fair-reserves + TWAP valuation
    function totalAssets() public view virtual override returns (uint256) {
        uint256 vaultLp = pair.balanceOf(address(this));
        uint256 idleAsset = depositToken.balanceOf(address(this));

        if (vaultLp == 0) {
            return idleAsset;
        }

        uint256 totalLpSupply = pair.totalSupply();
        if (totalLpSupply == 0) {
            return idleAsset;
        }

        (uint112 r0, uint112 r1,) = pair.getReserves();
        address t0 = pair.token0();
        uint256 rD = t0 == address(depositToken) ? uint256(r0) : uint256(r1);
        uint256 rO = t0 == address(depositToken) ? uint256(r1) : uint256(r0);

        // Value of reserve rO in deposit token units via TWAP
        uint256 vO = oracle.consult(address(pair), address(otherToken), rO);

        // Fair pool value in D units: 2 * sqrt(rD * vO)
        uint256 fairPoolValue = 2 * Math.sqrt(rD * vO);

        uint256 lpValue = Math.mulDiv(fairPoolValue, vaultLp, totalLpSupply);
        return lpValue + idleAsset;
    }

    /// @notice Standard ERC-4626 deposit
    function deposit(uint256 assets, address receiver) public virtual override returns (uint256) {
        return depositWithMin(assets, receiver, 0);
    }

    /// @notice Deposit with slippage protection on shares minted
    function depositWithMin(uint256 assets, address receiver, uint256 minShares)
        public
        whenNotPaused
        nonReentrant
        returns (uint256 shares)
    {
        if (assets == 0) revert ZeroAmount();
        if (receiver == address(0) || receiver == address(this)) revert InvalidRecipient();

        uint256 totalBefore = totalAssets();

        // Pull assets from user
        depositToken.safeTransferFrom(msg.sender, address(this), assets);

        // Zap assets into LP tokens
        depositToken.forceApprove(address(zap), assets);
        zap.zapIn(address(pair), address(depositToken), assets, 0, address(this), block.timestamp);
        depositToken.forceApprove(address(zap), 0);

        uint256 totalAfter = totalAssets();
        uint256 valueAdded = totalAfter > totalBefore ? totalAfter - totalBefore : 0;

        // Shares minted based on actual value added
        shares = Math.mulDiv(valueAdded, totalSupply() + 10 ** _decimalsOffset(), totalBefore + 1, Math.Rounding.Floor);

        if (shares < minShares) revert SlippageExceeded(shares, minShares);

        _mint(receiver, shares);
        emit Deposit(msg.sender, receiver, assets, shares);
    }

    /// @notice Standard ERC-4626 redeem
    function redeem(uint256 shares, address receiver, address owner) public virtual override returns (uint256) {
        return redeemWithMin(shares, receiver, owner, 0);
    }

    /// @notice Redeem with slippage protection on assets received
    function redeemWithMin(uint256 shares, address receiver, address owner, uint256 minAssets)
        public
        nonReentrant
        returns (uint256 assetsOut)
    {
        if (shares == 0) revert ZeroAmount();
        if (receiver == address(0) || receiver == address(this)) revert InvalidRecipient();

        if (msg.sender != owner) {
            _spendAllowance(owner, msg.sender, shares);
        }

        uint256 vaultLp = pair.balanceOf(address(this));
        uint256 lpToBurn = Math.mulDiv(vaultLp, shares, totalSupply(), Math.Rounding.Floor);

        _burn(owner, shares);

        IERC20(address(pair)).forceApprove(address(zap), lpToBurn);
        assetsOut = zap.zapOut(address(pair), lpToBurn, address(depositToken), minAssets, receiver, block.timestamp);
        IERC20(address(pair)).forceApprove(address(zap), 0);

        emit Withdraw(msg.sender, receiver, owner, assetsOut, shares);
    }

    /// @notice mint() disabled due to unpredictable zap slippage
    function mint(uint256, address) public virtual override returns (uint256) {
        revert ExactMintUnsupported();
    }

    /// @notice withdraw() disabled due to unpredictable zap slippage
    function withdraw(uint256, address, address) public virtual override returns (uint256) {
        revert ExactWithdrawUnsupported();
    }

    function pause() external onlyOwner {
        _pause();
    }

    function unpause() external onlyOwner {
        _unpause();
    }

    function rescueToken(address token, address to, uint256 amount) external onlyOwner {
        if (token == address(pair) || token == address(depositToken)) revert ProtectedToken();
        if (to == address(0)) revert InvalidRecipient();
        IERC20(token).safeTransfer(to, amount);
    }
}
