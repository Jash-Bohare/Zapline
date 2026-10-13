// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV2Callee} from "src/interfaces/IUniswapV2Callee.sol";
import {IERC20} from "openzeppelin-contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "openzeppelin-contracts/token/ERC20/utils/SafeERC20.sol";

contract NaiveFlashReceiver is IUniswapV2Callee {
    using SafeERC20 for IERC20;

    /// @notice Unsafe callback that trusts caller and decodes payee from calldata
    function uniswapV2Call(
        address, /* sender */
        uint256, /* amount0 */
        uint256, /* amount1 */
        bytes calldata data
    )
        external
        override
    {
        // VULNERABILITY (FR-SL-4):
        // 1. No check on msg.sender (does not verify it is a legitimate pair)
        // 2. No check on sender (does not verify who initiated the swap)
        // 3. Decodes payee directly from unauthenticated user data
        (address token, address payTo, uint256 amount) = abi.decode(data, (address, address, uint256));
        IERC20(token).safeTransfer(payTo, amount);
    }
}
