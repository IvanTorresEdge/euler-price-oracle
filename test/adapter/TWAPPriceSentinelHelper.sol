// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {AdapterHelper} from "test/adapter/AdapterHelper.sol";
import {TWAPPriceSentinel} from "src/adapter/TWAPPriceSentinel.sol";
import {AggregatorV3Interface} from "src/adapter/chainlink/ChainlinkOracle.sol";
import {boundAddr} from "test/utils/TestUtils.sol";
import {Errors} from "src/lib/Errors.sol";

contract MockAggregatorV3 is AggregatorV3Interface {
    struct RoundData {
        uint80 roundId;
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
        uint80 answeredInRound;
    }

    RoundData public latestRound;
    mapping(uint80 => RoundData) public rounds;
    uint8 public decimals;
    string public description;
    uint256 public version;

    bool public shouldRevert;
    bytes public revertReason;

    constructor(uint8 _decimals, string memory _description) {
        decimals = _decimals;
        description = _description;
        version = 1;
    }

    function setLatestRoundData(
        uint80 _roundId,
        int256 _answer,
        uint256 _startedAt,
        uint256 _updatedAt,
        uint80 _answeredInRound
    ) external {
        latestRound = RoundData(_roundId, _answer, _startedAt, _updatedAt, _answeredInRound);
        rounds[_roundId] = latestRound;
    }

    function setShouldRevert(bool _shouldRevert, bytes memory _reason) external {
        shouldRevert = _shouldRevert;
        revertReason = _reason;
    }

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        if (shouldRevert) {
            if (revertReason.length > 0) {
                bytes memory reason = revertReason;
                assembly {
                    revert(add(32, reason), mload(reason))
                }
            } else {
                revert("Mock revert");
            }
        }
        return (
            latestRound.roundId,
            latestRound.answer,
            latestRound.startedAt,
            latestRound.updatedAt,
            latestRound.answeredInRound
        );
    }

    function getRoundData(uint80 _roundId)
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound)
    {
        RoundData memory round = rounds[_roundId];
        return (round.roundId, round.answer, round.startedAt, round.updatedAt, round.answeredInRound);
    }
}

abstract contract TWAPPriceSentinelHelper is AdapterHelper {
    struct FuzzableState {
        address base;
        address quote;
        uint256 inAmount;
        uint256 maxDropBps;
        uint256 maxRiseBps;
        uint256 lambda;
        int256 initialPrice;
        uint8 feedDecimals;
    }

    MockAggregatorV3 public mockFeed;
    TWAPPriceSentinel public twapOracle;

    // Extend the base Behavior enum with TWAP-specific behaviors
    uint256 constant TWAP_FEED_REVERTS = 100;
    uint256 constant TWAP_FEED_RETURNS_ZERO_PRICE = 101;
    uint256 constant TWAP_FEED_RETURNS_NEGATIVE_PRICE = 102;

    // Custom behavior flags for TWAP-specific tests
    bool public feedShouldRevert;
    bool public feedShouldReturnZero;
    bool public feedShouldReturnNegative;

    function setTWAPBehavior(uint256 behaviorFlag, bool enabled) internal {
        if (behaviorFlag == TWAP_FEED_REVERTS) feedShouldRevert = enabled;
        else if (behaviorFlag == TWAP_FEED_RETURNS_ZERO_PRICE) feedShouldReturnZero = enabled;
        else if (behaviorFlag == TWAP_FEED_RETURNS_NEGATIVE_PRICE) feedShouldReturnNegative = enabled;
    }

    function setUpState(FuzzableState memory s) internal returns (address) {
        // Bound parameters to valid ranges
        s.base = boundAddr(s.base);
        s.quote = boundAddr(s.quote);
        vm.assume(s.base != s.quote);

        // Use very conservative bounds to ensure test stability
        s.inAmount = bound(s.inAmount, 1e6, 1e24);
        s.feedDecimals = uint8(bound(s.feedDecimals, 6, 18));

        // Force positive price in reasonable range
        uint256 priceUint = uint256(keccak256(abi.encode(s.initialPrice))) % (1e10 - 1e6) + 1e6;
        s.initialPrice = int256(priceUint);

        // Bound parameters to valid ranges
        s.maxDropBps = bound(s.maxDropBps, 50, 5000); // 0.5% to 50%
        s.maxRiseBps = bound(s.maxRiseBps, 50, 5000); // 0.5% to 50%
        s.lambda = bound(s.lambda, 1e15, 5e17); // 0.1% to 50% of 1e18

        // Create mock feed
        mockFeed = new MockAggregatorV3(s.feedDecimals, "Mock Feed");

        // Set initial price data based on behavior flags
        if (feedShouldReturnZero) {
            s.initialPrice = 0;
        } else if (feedShouldReturnNegative) {
            s.initialPrice = -1000;
        }

        mockFeed.setLatestRoundData(1, s.initialPrice, block.timestamp, block.timestamp, 1);

        if (feedShouldRevert) {
            mockFeed.setShouldRevert(true, "Feed error");
        }

        // Deploy TWAP oracle
        twapOracle = new TWAPPriceSentinel(address(mockFeed), s.base, s.quote, s.maxDropBps, s.maxRiseBps, s.lambda);

        oracle = address(twapOracle);
        return oracle;
    }

    function expectTWAPNotSupported(uint256 _inAmount, address _base, address _quote) internal {
        vm.expectRevert(abi.encodeWithSelector(Errors.PriceOracle_NotSupported.selector, _base, _quote));
        TWAPPriceSentinel(oracle).getQuote(_inAmount, _base, _quote);
    }

    function expectRevertWithCustomError(bytes4 selector) internal {
        vm.expectRevert(abi.encodeWithSelector(selector));
    }

    // Helper functions for setting up specific test scenarios
    function simulateTimePass(uint256 timeInSeconds) internal {
        vm.warp(block.timestamp + timeInSeconds);
    }

    function updateMockFeedPrice(int256 newPrice) internal {
        updateMockFeedPriceWithTimestamp(newPrice, block.timestamp);
    }

    function updateMockFeedPriceWithTimestamp(int256 newPrice, uint256 timestamp) internal {
        mockFeed.setLatestRoundData(
            latestRound().roundId + 1, newPrice, timestamp, timestamp, latestRound().roundId + 1
        );
    }

    function latestRound() internal view returns (MockAggregatorV3.RoundData memory) {
        (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound) =
            mockFeed.latestRoundData();
        return MockAggregatorV3.RoundData(roundId, answer, startedAt, updatedAt, answeredInRound);
    }

    function addPriceObservation(int256 price, uint256 timestamp) internal {
        vm.warp(timestamp);
        updateMockFeedPriceWithTimestamp(price, timestamp);
        // Trigger an observation by calling updatePrice if enough time has passed
        try twapOracle.updatePrice() {} catch {}
    }
}
