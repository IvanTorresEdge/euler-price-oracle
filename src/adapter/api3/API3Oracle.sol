// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseAdapter, Errors, IPriceOracle} from "../BaseAdapter.sol";
import {IApi3ReaderProxy} from "./IApi3ReaderProxy.sol";
import {ScaleUtils, Scale} from "../../lib/ScaleUtils.sol";

/// @title API3Oracle
/// @custom:security-contact security@euler.xyz
/// @author AlphaGrowth (https://www.alphagrowth.io/)
/// @notice PriceOracle adapter for API3 Api3ReaderProxyV1 price feeds
/// @dev Integration Note: `maxStaleness` is an immutable parameter set in the constructor.
/// API3 Api3ReaderProxyV1 are updated by API3's Airnode operators when price deviations exceed thresholds.
contract API3Oracle is BaseAdapter {
    /// @inheritdoc IPriceOracle
    string public constant name = "API3Oracle";
    /// @notice The minimum permitted value for `maxStaleness`.
    uint256 internal constant MAX_STALENESS_LOWER_BOUND = 1 minutes;
    /// @notice The maximum permitted value for `maxStaleness`.
    uint256 internal constant MAX_STALENESS_UPPER_BOUND = 72 hours;
    /// @notice The address of the base asset corresponding to the feed.
    address public immutable base;
    /// @notice The address of the quote asset corresponding to the feed.
    address public immutable quote;
    /// @notice The address of the API3 Api3ReaderProxyV1 proxy.
    /// @dev https://docs.api3.org/dapps/integration/contract-integration.html
    address public immutable feed;
    /// @notice The maximum allowed age of the price.
    /// @dev Reverts if block.timestamp - timestamp > maxStaleness.
    uint256 public immutable maxStaleness;
    /// @notice The scale factors used for decimal conversions.
    Scale internal immutable scale;

    /// @notice Deploy an API3Oracle.
    /// @param _base The address of the base asset corresponding to the feed.
    /// @param _quote The address of the quote asset corresponding to the feed.
    /// @param _feed The address of the API3 Api3ReaderProxyV1 proxy.
    /// @param _maxStaleness The maximum allowed age of the price.
    /// @dev API3 Api3ReaderProxyV1 have configurable deviation thresholds and heartbeat intervals.
    /// Consider the Api3ReaderProxyV1's configuration when setting `_maxStaleness`.
    constructor(address _base, address _quote, address _feed, uint256 _maxStaleness) {
        if (_maxStaleness < MAX_STALENESS_LOWER_BOUND || _maxStaleness > MAX_STALENESS_UPPER_BOUND) {
            revert Errors.PriceOracle_InvalidConfiguration();
        }

        base = _base;
        quote = _quote;
        feed = _feed;
        maxStaleness = _maxStaleness;

        // The scale factor is used to correctly convert decimals.
        uint8 baseDecimals = _getDecimals(base);
        uint8 quoteDecimals = _getDecimals(quote);
        // API3 Api3ReaderProxyV1 return values with 18 decimals
        uint8 feedDecimals = 18;
        scale = ScaleUtils.calcScale(baseDecimals, quoteDecimals, feedDecimals);
    }

    /// @notice Get the quote from the API3 Api3ReaderProxyV1.
    /// @param inAmount The amount of `base` to convert.
    /// @param _base The token that is being priced.
    /// @param _quote The token that is the unit of account.
    /// @return The converted amount using the API3 Api3ReaderProxyV1.
    function _getQuote(uint256 inAmount, address _base, address _quote) internal view override returns (uint256) {
        bool inverse = ScaleUtils.getDirectionOrRevert(_base, base, _quote, quote);

        (int224 value, uint256 timestamp) = IApi3ReaderProxy(feed).read();
        if (value <= 0) revert Errors.PriceOracle_InvalidAnswer();
        uint256 staleness = block.timestamp - timestamp;
        if (staleness > maxStaleness) revert Errors.PriceOracle_TooStale(staleness, maxStaleness);

        uint256 price = uint256(uint224(value));
        return ScaleUtils.calcOutAmount(inAmount, price, scale, inverse);
    }
}