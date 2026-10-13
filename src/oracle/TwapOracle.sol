// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IUniswapV2Pair} from "../interfaces/IUniswapV2Pair.sol";

contract TwapOracle {
    uint32 public immutable MIN_WINDOW;
    uint32 public immutable MIN_SPACING;
    uint32 public immutable MAX_AGE;
    uint8 public constant MAX_OBS = 8;

    struct Observation {
        uint32 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    mapping(address pair => Observation[MAX_OBS]) private _obs;
    mapping(address pair => uint8) private _head;
    mapping(address pair => uint8) private _count;

    event Updated(address indexed pair, uint256 price0Cumulative, uint256 price1Cumulative, uint256 timestamp);

    error InsufficientHistory();
    error StaleOracle();
    error InvalidToken();
    error EmptyPool();
    error InvalidParams();
    error ZeroAmount();

    constructor(uint32 _minWindow, uint32 _minSpacing, uint32 _maxAge) {
        if (_minWindow == 0 || _minSpacing == 0 || _maxAge <= _minWindow) revert InvalidParams();
        MIN_WINDOW = _minWindow;
        MIN_SPACING = _minSpacing;
        MAX_AGE = _maxAge;
    }

    /// @notice Records a new price observation for the pair if MIN_SPACING has elapsed
    function update(address pair) external {
        uint8 count = _count[pair];
        if (count > 0) {
            uint8 lastIdx = (_head[pair] + MAX_OBS - 1) % MAX_OBS;
            Observation memory lastObs = _obs[pair][lastIdx];
            if (block.timestamp - lastObs.timestamp < MIN_SPACING) {
                // Decision Q1: silently no-op when called within MIN_SPACING
                return;
            }
        }

        (uint256 price0Cum, uint256 price1Cum) = currentCumulativePrices(pair);

        uint8 head = _head[pair];
        _obs[pair][head] =
            Observation({timestamp: uint32(block.timestamp), price0Cumulative: price0Cum, price1Cumulative: price1Cum});

        _head[pair] = (head + 1) % MAX_OBS;
        if (count < MAX_OBS) {
            _count[pair] = count + 1;
        }

        emit Updated(pair, price0Cum, price1Cum, block.timestamp);
    }

    /// @notice Returns current cumulative prices for a pair, factoring in elapsed time since last sync
    function currentCumulativePrices(address pair)
        public
        view
        returns (uint256 price0Cumulative, uint256 price1Cumulative)
    {
        price0Cumulative = IUniswapV2Pair(pair).price0CumulativeLast();
        price1Cumulative = IUniswapV2Pair(pair).price1CumulativeLast();

        (uint112 r0, uint112 r1, uint32 blockTimestampLast) = IUniswapV2Pair(pair).getReserves();
        if (r0 == 0 || r1 == 0) revert EmptyPool();

        uint32 timeElapsed;
        unchecked {
            timeElapsed = uint32(block.timestamp) - blockTimestampLast;
        }

        if (timeElapsed > 0) {
            unchecked {
                // UQ112x112 price
                price0Cumulative += ((uint256(r1) << 112) / r0) * timeElapsed;
                price1Cumulative += ((uint256(r0) << 112) / r1) * timeElapsed;
            }
        }
    }

    /// @notice Computes TWAP-derived amountOut for a given tokenIn and amountIn
    function consult(address pair, address tokenIn, uint256 amountIn) external view returns (uint256 amountOut) {
        if (amountIn == 0) return 0;
        uint8 count = _count[pair];
        if (count == 0) revert InsufficientHistory();

        // Check newest observation for staleness
        uint8 newestIdx = (_head[pair] + MAX_OBS - 1) % MAX_OBS;
        Observation memory newestObs = _obs[pair][newestIdx];
        if (block.timestamp - newestObs.timestamp > MAX_AGE) revert StaleOracle();

        // Find the oldest observation that is within [MIN_WINDOW, MAX_AGE]
        // Iterate backwards from newest or forwards from oldest
        bool found = false;
        Observation memory targetObs;
        uint32 bestElapsed = 0;

        uint8 startIdx = count == MAX_OBS ? _head[pair] : 0;
        for (uint8 i = 0; i < count; i++) {
            uint8 idx = (startIdx + i) % MAX_OBS;
            Observation memory obs = _obs[pair][idx];
            uint32 elapsed;
            unchecked {
                elapsed = uint32(block.timestamp) - obs.timestamp;
            }
            if (elapsed >= MIN_WINDOW && elapsed <= MAX_AGE) {
                // Choose oldest valid observation to maximize window stability
                if (!found || elapsed > bestElapsed) {
                    targetObs = obs;
                    bestElapsed = elapsed;
                    found = true;
                }
            }
        }

        if (!found) revert InsufficientHistory();

        (uint256 price0Now, uint256 price1Now) = currentCumulativePrices(pair);
        address token0 = IUniswapV2Pair(pair).token0();
        address token1 = IUniswapV2Pair(pair).token1();

        if (tokenIn == token0) {
            uint256 price0Average;
            unchecked {
                price0Average = (price0Now - targetObs.price0Cumulative) / bestElapsed;
            }
            amountOut = (price0Average * amountIn) >> 112;
        } else if (tokenIn == token1) {
            uint256 price1Average;
            unchecked {
                price1Average = (price1Now - targetObs.price1Cumulative) / bestElapsed;
            }
            amountOut = (price1Average * amountIn) >> 112;
        } else {
            revert InvalidToken();
        }
    }

    function observationCount(address pair) external view returns (uint8) {
        return _count[pair];
    }

    function getObservation(address pair, uint8 index) external view returns (Observation memory) {
        return _obs[pair][index];
    }
}
