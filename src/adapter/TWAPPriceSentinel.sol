// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter, Errors, IPriceOracle} from "../adapter/BaseAdapter.sol";
import {AggregatorV3Interface} from "../adapter/chainlink/AggregatorV3Interface.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {ScaleUtils, Scale} from "../lib/ScaleUtils.sol";

/// @title TWAPPriceSentinel
/// @custom:security-contact security@euler.xyz
/// @author Alphagrowth (https://alphagrowth.io)
/// @notice Oracle wrapper that monitors price movements using exponentially weighted TWAP
/// @dev Reverts if price moves beyond configured thresholds from the EWTWAP
contract TWAPPriceSentinel is BaseAdapter {
    using FixedPointMathLib for uint256;

    /// @notice Price observation data
    struct Observation {
        uint128 price; // Price at observation time
        uint128 timestamp; // Timestamp of observation
    }

    /// @inheritdoc IPriceOracle
    string public constant name = "TWAPPriceSentinel";

    /// @notice The underlying price feed (Chainlink compatible)
    AggregatorV3Interface public immutable priceFeed;

    /// @notice Base token address
    address public immutable base;

    /// @notice Quote token address
    address public immutable quote;

    /// @notice Maximum allowed price drop in basis points
    uint256 public immutable maxDropBps;

    /// @notice Maximum allowed price rise in basis points
    uint256 public immutable maxRiseBps;

    /// @notice Lambda parameter for exponential decay (scaled by 1e18)
    /// @dev Suggested value: 0.05e18 for ~7-8 min adaptation to 2.5% moves
    uint256 public immutable lambda;

    /// @notice Number of observations to maintain
    uint256 public constant OBSERVATION_BUFFER_SIZE = 60;

    /// @notice Minimum time between updates per caller (spam protection)
    uint256 public constant MIN_UPDATE_INTERVAL = 30 seconds;

    /// @notice Circular buffer of price observations
    Observation[OBSERVATION_BUFFER_SIZE] public observations;

    /// @notice Current write index in circular buffer
    uint256 public nextObservationIndex;

    /// @notice Total number of observations recorded (capped at OBSERVATION_BUFFER_SIZE)
    uint8 public observationCount;

    /// @notice Last actual price update timestamp (global spam protection)
    uint128 public lastUpdateTime;

    /// @notice Scale factors for decimal conversions
    Scale internal immutable scale;

    /// @notice Decimals of the price feed
    uint8 internal immutable feedDecimals;

    /// @notice Price deviation exceeded threshold
    error TWAPPriceSentinel_PriceDeviationExceeded(uint256 deviation, uint256 maxDeviation, bool isPriceDrop);

    /// @notice Update called too frequently
    error TWAPPriceSentinel_UpdateTooFrequent(uint256 timeSinceLastUpdate, uint256 requiredInterval);

    /// @notice Insufficient observations for TWAP calculation
    error TWAPPriceSentinel_InsufficientObservations();

    /// @notice Price feed returned invalid data
    error TWAPPriceSentinel_InvalidFeedPrice();

    /// @notice Observation has invalid timestamp
    error TWAPPriceSentinel_InvalidTimestamp();

    /// @notice Deploy TWAPPriceSentinel
    /// @param _priceFeed Address of Chainlink-compatible price feed
    /// @param _base Base token address
    /// @param _quote Quote token address
    /// @param _maxDropBps Maximum allowed price drop (e.g., 150 = 1.5%)
    /// @param _maxRiseBps Maximum allowed price rise (e.g., 300 = 3%)
    /// @param _lambda Exponential decay factor scaled by 1e18 (e.g., 0.05e18)
    constructor(
        address _priceFeed,
        address _base,
        address _quote,
        uint256 _maxDropBps,
        uint256 _maxRiseBps,
        uint256 _lambda
    ) {
        priceFeed = AggregatorV3Interface(_priceFeed);
        base = _base;
        quote = _quote;
        maxDropBps = _maxDropBps;
        maxRiseBps = _maxRiseBps;
        lambda = _lambda;

        // Get feed decimals
        feedDecimals = priceFeed.decimals();

        // Calculate scale factors
        uint8 baseDecimals = _getDecimals(_base);
        uint8 quoteDecimals = _getDecimals(_quote);
        scale = ScaleUtils.calcScale(baseDecimals, quoteDecimals, feedDecimals);

        // Initialize with current price
        _updatePrice();
    }

    /// @notice Update price observation in circular buffer
    /// @dev Anyone can call but global spam protection applies
    function updatePrice() external {
        // Global spam protection - check time since last actual update
        uint256 timeSinceLastUpdate = block.timestamp - lastUpdateTime;
        if (timeSinceLastUpdate < MIN_UPDATE_INTERVAL) {
            revert TWAPPriceSentinel_UpdateTooFrequent(timeSinceLastUpdate, MIN_UPDATE_INTERVAL);
        }

        _updatePrice();
    }

    /// @notice Internal price update logic
    function _updatePrice() private {
        // Get latest price from feed
        (, int256 price,, uint256 updatedAt,) = priceFeed.latestRoundData();

        // Validate price
        if (price <= 0) revert TWAPPriceSentinel_InvalidFeedPrice();

        // Store observation
        observations[nextObservationIndex] =
            Observation({price: uint128(uint256(price)), timestamp: uint128(updatedAt)});

        // Update circular buffer index
        nextObservationIndex = (nextObservationIndex + 1) % OBSERVATION_BUFFER_SIZE;

        // Track total observations (increment only until buffer is full)
        if (observationCount < OBSERVATION_BUFFER_SIZE) {
            observationCount++;
        }

        // Update last update timestamp after successful price update
        lastUpdateTime = uint128(block.timestamp);
    }

    /// @notice Calculate exponentially weighted TWAP
    /// @return ewtwap The exponentially weighted time-weighted average price
    function calculateEWTWAP() public view returns (uint256 ewtwap) {
        if (observationCount < 2) revert TWAPPriceSentinel_InsufficientObservations();

        uint256 currentTime = block.timestamp;
        uint256 weightedSum = 0;
        uint256 totalWeight = 0;

        // Iterate through observations (newest to oldest)
        uint256 count = observationCount;
        for (uint256 i = 0; i < count;) {
            // Calculate index in circular buffer
            uint256 index = (nextObservationIndex + OBSERVATION_BUFFER_SIZE - 1 - i) % OBSERVATION_BUFFER_SIZE;
            Observation memory obs = observations[index];

            // Skip if observation is too old (> 1 hour)
            // NOTE: If all observations are stale, the oracle will revert and become unusable
            // This is intentional - we prefer to fail closed rather than serve stale prices
            // Recovery requires 2 calls to updatePrice() spaced 30 seconds apart
            if (currentTime > obs.timestamp && currentTime - obs.timestamp > 3600) {
                unchecked {
                    ++i;
                }
                continue;
            }

            // Calculate age in seconds
            if (obs.timestamp > currentTime) revert TWAPPriceSentinel_InvalidTimestamp();
            uint256 age = currentTime - obs.timestamp;

            // Calculate exponential weight: e^(-lambda * age_in_minutes)
            // Convert age to minutes and scale lambda down
            uint256 ageInMinutes = age / 60;
            uint256 exponent = lambda.mulWad(ageInMinutes * 1e18 / 60); // lambda is already scaled by 1e18

            // Approximate e^(-x) using Taylor series for small x
            // e^(-x) ≈ 1 - x + x²/2 - x³/6 + ...
            // For simplicity and gas efficiency, use: e^(-x) ≈ 1 - x for x < 1
            uint256 weight;
            if (exponent >= 1e18) {
                // For large exponents, weight becomes negligible
                weight = 1e18 / (exponent / 1e18 + 1); // Rough approximation
            } else {
                // For small exponents, use linear approximation
                weight = 1e18 - exponent;
            }

            weightedSum += uint256(obs.price) * weight;
            totalWeight += weight;

            unchecked {
                ++i;
            }
        }

        if (totalWeight == 0) revert TWAPPriceSentinel_InsufficientObservations();

        ewtwap = weightedSum / totalWeight;
    }

    /// @notice Get quote with TWAP-based circuit breaker protection
    /// @param inAmount Amount of base token to quote
    /// @param _base Base token address
    /// @param _quote Quote token address
    /// @return outAmount Amount of quote tokens
    function _getQuote(uint256 inAmount, address _base, address _quote) internal view override returns (uint256) {
        // Verify this is the configured pair
        bool isForward = (_base == base && _quote == quote);
        bool isReverse = (_base == quote && _quote == base);

        if (!isForward && !isReverse) {
            revert Errors.PriceOracle_NotSupported(_base, _quote);
        }

        // Get current price from feed
        (, int256 currentPrice,,,) = priceFeed.latestRoundData();
        if (currentPrice <= 0) revert TWAPPriceSentinel_InvalidFeedPrice();

        // Calculate EWTWAP
        uint256 ewtwap = calculateEWTWAP();

        // Check deviation
        uint256 deviation;
        bool isPriceDrop;

        if (uint256(currentPrice) >= ewtwap) {
            // Price rose
            deviation = (uint256(currentPrice) - ewtwap) * 10000 / ewtwap;
            isPriceDrop = false;

            if (deviation > maxRiseBps) {
                revert TWAPPriceSentinel_PriceDeviationExceeded(deviation, maxRiseBps, isPriceDrop);
            }
        } else {
            // Price dropped
            deviation = (ewtwap - uint256(currentPrice)) * 10000 / ewtwap;
            isPriceDrop = true;

            if (deviation > maxDropBps) {
                revert TWAPPriceSentinel_PriceDeviationExceeded(deviation, maxDropBps, isPriceDrop);
            }
        }

        // Price is within bounds, return the quote
        return ScaleUtils.calcOutAmount(inAmount, uint256(currentPrice), scale, isReverse);
    }

    /// @notice Get the current number of observations
    function getObservationCount() external view returns (uint256) {
        return observationCount;
    }

    /// @notice Get observation at specific index
    function getObservation(uint256 index) external view returns (uint128 price, uint128 timestamp) {
        if (index >= observationCount) revert();

        // Map logical index to circular buffer position
        uint256 bufferIndex;
        if (observationCount < OBSERVATION_BUFFER_SIZE) {
            bufferIndex = index;
        } else {
            bufferIndex = (nextObservationIndex + index) % OBSERVATION_BUFFER_SIZE;
        }

        Observation memory obs = observations[bufferIndex];
        return (obs.price, obs.timestamp);
    }
}
