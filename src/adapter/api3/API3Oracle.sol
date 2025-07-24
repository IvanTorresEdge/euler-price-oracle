// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter, Errors, IPriceOracle} from "../BaseAdapter.sol";
import {IApi3ReaderProxy} from "./IApi3ReaderProxy.sol";
import {AggregatorV3Interface} from "../chainlink/AggregatorV3Interface.sol";
import {ScaleUtils, Scale} from "../../lib/ScaleUtils.sol";

/// @title API3Oracle
/// @custom:security-contact security@euler.xyz
/// @author AlphaGrowth (https://www.alphagrowth.io/)
/// @notice PriceOracle adapter for API3 Api3ReaderProxyV1 price feeds
/// @dev Integration Note: `maxStaleness` is an immutable parameter set in the constructor.
/// API3 Api3ReaderProxyV1 are updated by API3's Airnode operators when price deviations exceed thresholds.
contract API3Oracle is BaseAdapter {
    /// @inheritdoc IPriceOracle
    string public name;
    /// @notice The minimum permitted value for `maxStaleness`.
    uint256 internal constant MAX_STALENESS_LOWER_BOUND = 1 minutes;
    /// @notice The maximum permitted value for `maxStaleness`.
    uint256 internal constant MAX_STALENESS_UPPER_BOUND = 26 hours; // 24h + 2h buffer
    /// @notice The address of the base asset corresponding to the feed.
    address public immutable base;
    /// @notice The address of the quote asset corresponding to the feed.
    address public immutable quote;
    /// @notice The API3 Api3ReaderProxyV1 proxy.
    /// @dev https://docs.api3.org/dapps/integration/contract-integration.html
    IApi3ReaderProxy public immutable feed;
    /// @notice The maximum allowed age of the price.
    /// @dev Reverts if block.timestamp - timestamp > maxStaleness.
    uint256 public immutable maxStaleness;
    /// @notice The decimals returned by the feed.
    uint8 public immutable feedDecimals;
    /// @notice The scale factors used for decimal conversions.
    Scale internal immutable scale;

    /// @notice Deploy an API3Oracle.
    /// @param _baseSymbol The symbol of the base asset (e.g., "ETH", "rETH").
    /// @param _base The address of the base asset corresponding to the feed.
    /// @param _quoteSymbol The symbol of the quote asset (e.g., "USD", "WETH").
    /// @param _quote The address of the quote asset corresponding to the feed.
    /// @param _feed The address of the API3 Api3ReaderProxyV1 proxy.
    /// @param _maxStaleness The maximum allowed age of the price.
    /// @dev API3 Api3ReaderProxyV1 have configurable deviation thresholds and heartbeat intervals.
    /// Consider the Api3ReaderProxyV1's configuration when setting `_maxStaleness`.
    constructor(
        string memory _baseSymbol,
        address _base,
        string memory _quoteSymbol,
        address _quote,
        address _feed,
        uint256 _maxStaleness
    ) {
        if (_maxStaleness < MAX_STALENESS_LOWER_BOUND || _maxStaleness > MAX_STALENESS_UPPER_BOUND) {
            revert Errors.PriceOracle_InvalidConfiguration();
        }
        if (_base == address(0) || _quote == address(0) || _feed == address(0)) {
            revert Errors.PriceOracle_InvalidConfiguration();
        }

        base = _base;
        quote = _quote;
        feed = IApi3ReaderProxy(_feed);
        maxStaleness = _maxStaleness;

        // Try to get actual feed decimals, fallback to 18
        try AggregatorV3Interface(_feed).decimals() returns (uint8 decimals) {
            feedDecimals = decimals;
        } catch {
            feedDecimals = 18; // API3 default
        }

        // Validate USD feeds return 18 decimals (standard for price feeds)
        if (keccak256(bytes(_quoteSymbol)) == keccak256(bytes("USD")) && feedDecimals != 18) {
            revert Errors.PriceOracle_InvalidConfiguration();
        }

        // Construct dynamic name
        name = string.concat("API3Oracle ", _baseSymbol, "/", _quoteSymbol);

        // The scale factor is used to correctly convert decimals.
        uint8 baseDecimals = _getDecimals(base);
        uint8 quoteDecimals = _getDecimals(quote);
        scale = ScaleUtils.calcScale(baseDecimals, quoteDecimals, feedDecimals);
    }

    /// @notice Get the quote from the API3 Api3ReaderProxyV1.
    /// @param inAmount The amount of `base` to convert.
    /// @param _base The token that is being priced.
    /// @param _quote The token that is the unit of account.
    /// @return The converted amount using the API3 Api3ReaderProxyV1.
    function _getQuote(uint256 inAmount, address _base, address _quote) internal view override returns (uint256) {
        bool inverse = ScaleUtils.getDirectionOrRevert(_base, base, _quote, quote);

        (int224 value, uint256 timestamp) = feed.read();
        if (value <= 0) revert Errors.PriceOracle_InvalidAnswer();
        uint256 staleness = block.timestamp - timestamp;
        if (staleness > maxStaleness) revert Errors.PriceOracle_TooStale(staleness, maxStaleness);

        uint256 price = uint256(uint224(value));
        return ScaleUtils.calcOutAmount(inAmount, price, scale, inverse);
    }
}
