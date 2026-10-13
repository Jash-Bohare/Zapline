// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Math} from "openzeppelin-contracts/utils/math/Math.sol";

library ZapMath {
    /// @notice Computes the optimal amount of tokenIn to swap into tokenOut
    ///         such that the remaining tokenIn and received tokenOut can be
    ///         added to the liquidity pool without leaving excess tokens behind.
    /// @dev Formula: s = (sqrt(r * (a * 3_988_000 + r * 3_988_009)) - r * 1997) / 1994
    /// @param reserveIn The pool reserve of tokenIn
    /// @param amountIn Total amount of tokenIn to zap
    /// @return swapAmount Optimal amount of tokenIn to swap
    function optimalSwapAmount(uint256 reserveIn, uint256 amountIn) internal pure returns (uint256 swapAmount) {
        if (reserveIn == 0 || amountIn == 0) return 0;

        // Bounded checks for extreme fuzz values to prevent overflow
        if (amountIn > type(uint256).max / 3988000 || reserveIn > type(uint256).max / 3988009) {
            return amountIn / 2;
        }

        uint256 aTerm = amountIn * 3988000;
        uint256 rTerm = reserveIn * 3988009;
        uint256 innerTerm = aTerm + rTerm;

        uint256 root;
        if (innerTerm <= type(uint256).max / reserveIn) {
            root = Math.sqrt(reserveIn * innerTerm);
        } else {
            root = _sqrt512(reserveIn, innerTerm);
        }

        uint256 r1997 = reserveIn * 1997;
        if (root <= r1997) {
            return 0;
        }

        swapAmount = (root - r1997) / 1994;
        if (swapAmount > amountIn) {
            swapAmount = amountIn;
        }
    }

    function _sqrt512(uint256 x, uint256 y) private pure returns (uint256 g) {
        uint256 bits = Math.log2(x) + Math.log2(y) + 2;
        g = 1 << ((bits + 1) / 2);
        while (true) {
            uint256 div = Math.mulDiv(x, y, g);
            uint256 gNext = (g + div) / 2;
            if (gNext >= g) {
                break;
            }
            g = gNext;
        }
    }
}
