// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {IERC20} from "forge-std/interfaces/IERC20.sol";
import {FixedPointMathLib} from "@solady/utils/FixedPointMathLib.sol";
import {AdapterHelper} from "test/adapter/AdapterHelper.sol";
import {boundAddr, distinct} from "test/utils/TestUtils.sol";
import {IApi3ReaderProxy} from "src/adapter/api3/IApi3ReaderProxy.sol";
import {API3Oracle} from "src/adapter/api3/API3Oracle.sol";

contract API3OracleHelper is AdapterHelper {
    uint256 internal constant MAX_STALENESS_LOWER_BOUND = 1 minutes;
    uint256 internal constant MAX_STALENESS_UPPER_BOUND = 72 hours;

    struct Bounds {
        uint8 minBaseDecimals;
        uint8 maxBaseDecimals;
        uint8 minQuoteDecimals;
        uint8 maxQuoteDecimals;
        uint256 minInAmount;
        uint256 maxInAmount;
        int224 minValue;
        int224 maxValue;
    }

    Bounds internal DEFAULT_BOUNDS = Bounds({
        minBaseDecimals: 0,
        maxBaseDecimals: 18,
        minQuoteDecimals: 0,
        maxQuoteDecimals: 18,
        minInAmount: 0,
        maxInAmount: type(uint128).max,
        minValue: 1,
        maxValue: int224(int256(1e27))
    });

    Bounds internal bounds = DEFAULT_BOUNDS;

    function setBounds(Bounds memory _bounds) internal {
        bounds = _bounds;
    }

    struct FuzzableState {
        // Config
        address base;
        address quote;
        address feed;
        uint256 maxStaleness;
        uint8 baseDecimals;
        uint8 quoteDecimals;
        // API3 Api3ReaderProxyV1 response
        int224 value;
        uint256 timestamp;
        // Environment
        uint256 blockTimestamp;
        uint256 inAmount;
    }

    function setUpState(FuzzableState memory s) internal {
        s.base = boundAddr(s.base);
        s.quote = boundAddr(s.quote);
        s.feed = boundAddr(s.feed);
        vm.assume(distinct(s.base, s.quote, s.feed));

        if (behaviors[Behavior.Constructor_MaxStalenessTooLow]) {
            s.maxStaleness = bound(s.maxStaleness, 0, MAX_STALENESS_LOWER_BOUND - 1);
        } else if (behaviors[Behavior.Constructor_MaxStalenessTooHigh]) {
            s.maxStaleness = bound(s.maxStaleness, MAX_STALENESS_UPPER_BOUND + 1, type(uint128).max);
        } else {
            s.maxStaleness = bound(s.maxStaleness, MAX_STALENESS_LOWER_BOUND, MAX_STALENESS_UPPER_BOUND);
        }

        s.baseDecimals = uint8(bound(s.baseDecimals, bounds.minBaseDecimals, bounds.maxBaseDecimals));
        s.quoteDecimals = uint8(bound(s.quoteDecimals, bounds.minQuoteDecimals, bounds.maxQuoteDecimals));

        vm.mockCall(s.base, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(s.baseDecimals));
        vm.mockCall(s.quote, abi.encodeWithSelector(IERC20.decimals.selector), abi.encode(s.quoteDecimals));

        if (behaviors[Behavior.Constructor_MaxStalenessTooLow] || behaviors[Behavior.Constructor_MaxStalenessTooHigh]) {
            // For constructor tests that should revert, we don't need to set up the full state
            oracle = address(new API3Oracle(s.base, s.quote, s.feed, s.maxStaleness));
            return;
        }

        oracle = address(new API3Oracle(s.base, s.quote, s.feed, s.maxStaleness));

        if (behaviors[Behavior.FeedReturnsZeroPrice]) {
            s.value = 0;
        } else if (behaviors[Behavior.FeedReturnsNegativePrice]) {
            s.value = int224(bound(int256(s.value), int256(type(int224).min), -1));
        } else {
            s.value = int224(bound(int256(s.value), int256(bounds.minValue), int256(bounds.maxValue)));
        }

        s.timestamp = bound(s.timestamp, 1, type(uint128).max);

        if (behaviors[Behavior.FeedReturnsStalePrice]) {
            s.blockTimestamp = bound(s.blockTimestamp, s.timestamp + s.maxStaleness + 1, type(uint256).max);
        } else {
            s.blockTimestamp = bound(s.blockTimestamp, s.timestamp, s.timestamp + s.maxStaleness);
        }

        s.inAmount = bound(s.inAmount, bounds.minInAmount, bounds.maxInAmount);

        if (behaviors[Behavior.FeedReverts]) {
            vm.mockCallRevert(s.feed, abi.encodeWithSelector(IApi3ReaderProxy.read.selector), "oops");
        } else {
            vm.mockCall(
                s.feed,
                abi.encodeWithSelector(IApi3ReaderProxy.read.selector),
                abi.encode(s.value, s.timestamp)
            );
        }

        vm.warp(s.blockTimestamp);
    }

    function calcOutAmount(FuzzableState memory s) internal pure returns (uint256) {
        // API3 Api3ReaderProxyV1 return values with 18 decimals
        uint8 feedDecimals = 18;
        return FixedPointMathLib.fullMulDiv(
            s.inAmount, uint256(uint224(s.value)) * 10 ** s.quoteDecimals, 10 ** (feedDecimals + s.baseDecimals)
        );
    }

    function calcOutAmountInverse(FuzzableState memory s) internal pure returns (uint256) {
        // API3 Api3ReaderProxyV1 return values with 18 decimals
        uint8 feedDecimals = 18;
        return FixedPointMathLib.fullMulDiv(
            s.inAmount, 10 ** (feedDecimals + s.baseDecimals), (uint256(uint224(s.value)) * 10 ** s.quoteDecimals)
        );
    }
}