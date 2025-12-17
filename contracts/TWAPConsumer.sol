// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "./Pair.sol";

/// @notice Executes limit orders using recorded TWAPs from a UniswapV2-style pair.
contract TWAPConsumer {
    struct Observation {
        uint32 timestamp;
        uint256 price0Cumulative;
        uint256 price1Cumulative;
    }

    mapping(address => Observation) public observations;

    event ObservationRecorded(address indexed pair, uint32 timestamp, uint256 price0, uint256 price1);
    event LimitOrderExecuted(
        address indexed pair,
        address indexed trader,
        bool zeroForOne,
        uint256 amountIn,
        uint256 amountOut
    );

    uint256 private constant Q112 = 1 << 112;

    /// @notice Record a fresh observation for the provided pair.
    function recordObservation(address pairAddress) external {
        Observation storage obs = observations[pairAddress];
        UniswapV2Pair pair = UniswapV2Pair(pairAddress);
        (, , uint32 blockTimestamp) = pair.getReserves();
        require(blockTimestamp > obs.timestamp, "TWAP: TIME_NOT_ADVANCED");

        obs.timestamp = blockTimestamp;
        obs.price0Cumulative = pair.price0CumulativeLast();
        obs.price1Cumulative = pair.price1CumulativeLast();

        emit ObservationRecorded(pairAddress, blockTimestamp, obs.price0Cumulative, obs.price1Cumulative);
    }

    /// @notice Executes a limit order that uses the TWAP instead of the spot price.
    /// @param pairAddress Address of the UniswapV2 pair.
    /// @param amountIn Amount of tokenIn to spend (token0 when zeroForOne == true).
    /// @param minAmountOut Minimum acceptable output amount.
    /// @param timeWindow Minimum amount of time that must have elapsed since the last observation.
    /// @param zeroForOne Direction flag; true means token0 -> token1.
    function executeLimitOrder(
        address pairAddress,
        uint256 amountIn,
        uint256 minAmountOut,
        uint32 timeWindow,
        bool zeroForOne
    ) external {
        require(amountIn > 0, "TWAP: ZERO_IN");
        require(timeWindow > 0, "TWAP: ZERO_WINDOW");

        Observation memory prev = observations[pairAddress];
        require(prev.timestamp != 0, "TWAP: NO_OBSERVATION");

        UniswapV2Pair pair = UniswapV2Pair(pairAddress);
        (uint112 reserve0, uint112 reserve1, uint32 currentTimestamp) = pair.getReserves();
        require(currentTimestamp > prev.timestamp, "TWAP: TIME_NOT_ADVANCED");

        uint32 elapsed = currentTimestamp - prev.timestamp;
        require(elapsed >= timeWindow, "TWAP: INSUFFICIENT_WINDOW");

        uint256 currentPriceCumulative = zeroForOne ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        uint256 prevPriceCumulative = zeroForOne ? prev.price0Cumulative : prev.price1Cumulative;
        uint256 cumulativeDelta = currentPriceCumulative - prevPriceCumulative;
        require(cumulativeDelta > 0, "TWAP: NO_PRICE_FLOW");

        uint256 twap = cumulativeDelta / elapsed;
        uint256 normalizedTwap = (amountIn * twap) >> 112;
        uint256 reserveIn = zeroForOne ? reserve0 : reserve1;
        uint256 reserveOut = zeroForOne ? reserve1 : reserve0;
        uint256 amountInWithFee = amountIn * 997;
        uint256 spotMax = (amountInWithFee * reserveOut) / (reserveIn * 1000 + amountInWithFee);
        uint256 amountOut = (normalizedTwap * 997) / 1000;
        if (amountOut > spotMax) {
            amountOut = spotMax;
        }
        require(amountOut >= minAmountOut, "TWAP: SLIPPAGE");

        IERC20 tokenIn = zeroForOne ? IERC20(pair.token0()) : IERC20(pair.token1());
        tokenIn.transferFrom(msg.sender, pairAddress, amountIn);

        if (zeroForOne) {
            pair.swap(0, amountOut, msg.sender, "");
        } else {
            pair.swap(amountOut, 0, msg.sender, "");
        }

        observations[pairAddress] = Observation({
            timestamp: currentTimestamp,
            price0Cumulative: pair.price0CumulativeLast(),
            price1Cumulative: pair.price1CumulativeLast()
        });

        emit LimitOrderExecuted(pairAddress, msg.sender, zeroForOne, amountIn, amountOut);
    }
}
