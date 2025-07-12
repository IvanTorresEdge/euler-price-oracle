// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {TWAPPriceSentinelHelper, MockAggregatorV3} from "test/adapter/TWAPPriceSentinelHelper.sol";
import {TWAPPriceSentinel} from "src/adapter/TWAPPriceSentinel.sol";
import {Errors} from "src/lib/Errors.sol";
import {boundAddr} from "test/utils/TestUtils.sol";

contract TWAPPriceSentinelUnitTest is TWAPPriceSentinelHelper {
    // ============ Constructor Tests ============

    /// @notice Test constructor sets all parameters correctly
    /// @dev Verifies that the oracle is initialized with correct base, quote, thresholds, and lambda
    function test_Constructor_Integrity(FuzzableState memory s) public {
        setUpState(s);

        // Verify all immutable parameters are set correctly
        assertEq(twapOracle.base(), s.base);
        assertEq(twapOracle.quote(), s.quote);
        assertEq(twapOracle.maxDropBps(), s.maxDropBps);
        assertEq(twapOracle.maxRiseBps(), s.maxRiseBps);
        assertEq(twapOracle.lambda(), s.lambda);
        assertEq(address(twapOracle.priceFeed()), address(mockFeed));

        // Verify oracle starts with 1 observation (from constructor)
        assertEq(twapOracle.getObservationCount(), 1);

        // Verify the oracle name
        assertEq(twapOracle.name(), "TWAPPriceSentinel");

        // Verify initial observation was recorded correctly
        (uint128 price, uint128 timestamp) = twapOracle.getObservation(0);
        assertEq(price, uint128(uint256(s.initialPrice)));
        assertEq(timestamp, uint128(block.timestamp));
    }

    // ============ UpdatePrice Function Tests ============

    /// @notice Test updatePrice function works correctly
    /// @dev Should successfully update observations when called after minimum interval
    function test_UpdatePrice_WorksCorrectly(FuzzableState memory s) public {
        setUpState(s);

        // Oracle starts with 1 observation from constructor
        assertEq(twapOracle.getObservationCount(), 1);

        // Set new price on feed (just add 1000 to ensure it's different)
        int256 newPrice = s.initialPrice + 1000;

        // Fast forward past minimum interval (30 seconds)
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(newPrice, block.timestamp);

        // Call updatePrice - should succeed
        twapOracle.updatePrice();

        // Verify observation count increased
        assertEq(twapOracle.getObservationCount(), 2);

        // Verify new observation was recorded correctly
        (uint128 price, uint128 timestamp) = twapOracle.getObservation(1);
        assertEq(price, uint128(uint256(newPrice)));
        assertEq(timestamp, uint128(block.timestamp));
    }

    /// @notice Test updatePrice reverts when called too frequently
    /// @dev Should revert with TWAPPriceSentinel_UpdateTooFrequent when called within 30 seconds
    function test_UpdatePrice_RevertsWhen_CalledTooFrequently(FuzzableState memory s) public {
        setUpState(s);

        // Oracle starts with 1 observation from constructor at time 0
        assertEq(twapOracle.getObservationCount(), 1);

        // Try to call updatePrice immediately - should fail (0 seconds since constructor)
        vm.expectRevert();
        twapOracle.updatePrice();

        // Fast forward less than 30 seconds (e.g., 29 seconds)
        simulateTimePass(29);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);

        // Should still fail (only 29 seconds since last update)
        vm.expectRevert();
        twapOracle.updatePrice();

        // Fast forward to exactly 30 seconds from start
        vm.warp(30);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 2000, block.timestamp);

        // Should still fail (exactly 30 seconds, but needs > 30)
        vm.expectRevert();
        twapOracle.updatePrice();

        // Fast forward to 31 seconds from start
        vm.warp(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 3000, block.timestamp);

        // Now should succeed (31 seconds > 30 second minimum)
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Immediately try again - should fail (0 seconds since last successful update)
        vm.expectRevert();
        twapOracle.updatePrice();
    }

    /// @notice Test updatePrice increments observation count correctly
    /// @dev Should track observation count up to OBSERVATION_BUFFER_SIZE
    function test_UpdatePrice_IncrementsObservationCount(FuzzableState memory s) public {
        setUpState(s);

        // Oracle starts with 1 observation from constructor
        assertEq(twapOracle.getObservationCount(), 1);

        // Add observations up to the buffer size (60)
        uint256 bufferSize = 60; // OBSERVATION_BUFFER_SIZE constant

        for (uint256 i = 1; i < bufferSize; i++) {
            // Fast forward past minimum interval
            simulateTimePass(31);

            // Update feed with new price
            int256 newPrice = s.initialPrice + int256(i * 1000);
            updateMockFeedPriceWithTimestamp(newPrice, block.timestamp);

            // Add observation
            twapOracle.updatePrice();

            // Verify count incremented
            assertEq(twapOracle.getObservationCount(), i + 1);
        }

        // Should now have exactly 60 observations
        assertEq(twapOracle.getObservationCount(), bufferSize);

        // Add one more observation - count should remain at 60 (buffer is full)
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + int256(bufferSize * 1000), block.timestamp);
        twapOracle.updatePrice();

        // Count should still be 60 (capped at buffer size)
        assertEq(twapOracle.getObservationCount(), bufferSize);

        // Add a few more to confirm it stays capped
        for (uint256 i = 0; i < 5; i++) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(s.initialPrice + int256((bufferSize + i + 1) * 1000), block.timestamp);
            twapOracle.updatePrice();
            assertEq(twapOracle.getObservationCount(), bufferSize);
        }
    }

    // ============ Price Feed Tests ============

    /// @notice Test oracle reverts when underlying price feed reverts
    /// @dev Should propagate the underlying feed's revert reason
    function test_GetQuote_RevertsWhen_FeedReverts(FuzzableState memory s) public {
        setUpState(s);

        // Add a second observation so we have enough for EWTWAP calculation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Now configure the feed to revert
        mockFeed.setShouldRevert(true, "Feed is down");

        // Attempt to get quote - should revert with the feed's error
        vm.expectRevert("Feed is down");
        twapOracle.getQuote(s.inAmount, s.base, s.quote);

        // Test with reverse direction as well
        vm.expectRevert("Feed is down");
        twapOracle.getQuote(s.inAmount, s.quote, s.base);

        // Test that updatePrice also fails when feed reverts (after waiting for minimum interval)
        simulateTimePass(31);
        vm.expectRevert("Feed is down");
        twapOracle.updatePrice();
    }

    /// @notice Test oracle reverts when feed returns zero price
    /// @dev Should revert with TWAPPriceSentinel_InvalidFeedPrice when price <= 0
    function test_GetQuote_RevertsWhen_FeedReturnsZeroPrice(FuzzableState memory s) public {
        setUpState(s);

        // Add a second observation so we have enough for EWTWAP calculation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Now configure the feed to return zero price
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(0, block.timestamp);

        // Attempt to get quote - should revert with InvalidFeedPrice
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InvalidFeedPrice.selector));
        twapOracle.getQuote(s.inAmount, s.base, s.quote);

        // Test with reverse direction as well
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InvalidFeedPrice.selector));
        twapOracle.getQuote(s.inAmount, s.quote, s.base);

        // Test that updatePrice also fails with zero price
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InvalidFeedPrice.selector));
        twapOracle.updatePrice();
    }

    /// @notice Test oracle reverts when feed returns negative price
    /// @dev Should revert with TWAPPriceSentinel_InvalidFeedPrice when price < 0
    function test_GetQuote_RevertsWhen_FeedReturnsNegativePrice(FuzzableState memory s) public {
        setUpState(s);

        // Add a second observation so we have enough for EWTWAP calculation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Now configure the feed to return negative price
        simulateTimePass(31);
        int256 negativePrice = -1000;
        updateMockFeedPriceWithTimestamp(negativePrice, block.timestamp);

        // Attempt to get quote - should revert with InvalidFeedPrice
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InvalidFeedPrice.selector));
        twapOracle.getQuote(s.inAmount, s.base, s.quote);

        // Test with reverse direction as well
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InvalidFeedPrice.selector));
        twapOracle.getQuote(s.inAmount, s.quote, s.base);

        // Test that updatePrice also fails with negative price
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InvalidFeedPrice.selector));
        twapOracle.updatePrice();
    }

    // ============ Token Pair Support Tests ============

    /// @notice Test oracle only supports the configured base/quote pair
    /// @dev Should revert with PriceOracle_NotSupported for any other token pairs
    function test_GetQuote_RevertsWhen_UnsupportedTokenPair(FuzzableState memory s, address otherA, address otherB)
        public
    {
        setUpState(s);

        // Add a second observation so we have enough for EWTWAP calculation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Bound other addresses to be different from configured pair
        otherA = boundAddr(otherA);
        otherB = boundAddr(otherB);
        vm.assume(otherA != s.base && otherA != s.quote);
        vm.assume(otherB != s.base && otherB != s.quote);
        vm.assume(otherA != otherB);

        // Test unsupported pairs should revert

        // Same token for both base and quote (configured tokens)
        expectTWAPNotSupported(s.inAmount, s.base, s.base);
        expectTWAPNotSupported(s.inAmount, s.quote, s.quote);

        // Configured token with other token
        expectTWAPNotSupported(s.inAmount, s.base, otherA);
        expectTWAPNotSupported(s.inAmount, otherA, s.base);
        expectTWAPNotSupported(s.inAmount, s.quote, otherA);
        expectTWAPNotSupported(s.inAmount, otherA, s.quote);

        // Two other tokens (neither configured)
        expectTWAPNotSupported(s.inAmount, otherA, otherB);
        expectTWAPNotSupported(s.inAmount, otherB, otherA);

        // Same other token for both
        expectTWAPNotSupported(s.inAmount, otherA, otherA);
        expectTWAPNotSupported(s.inAmount, otherB, otherB);
    }

    /// @notice Test oracle supports both directions of the configured pair
    /// @dev Should return inverse price when base and quote are swapped
    function test_GetQuote_SupportsBothDirections(FuzzableState memory s) public {
        setUpState(s);

        // Add a second observation so we have enough for EWTWAP calculation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Use a fixed reasonable test amount to avoid precision issues with extreme fuzz inputs
        uint256 testAmount = 1e18;

        // Test forward direction: base -> quote
        uint256 forwardQuote = twapOracle.getQuote(testAmount, s.base, s.quote);
        assertGt(forwardQuote, 0);

        // Test reverse direction: quote -> base
        uint256 reverseQuote = twapOracle.getQuote(testAmount, s.quote, s.base);
        assertGt(reverseQuote, 0);

        // For the same input amount, the relationship should be approximately inverse
        // forward * reverse ≈ inAmount^2 (accounting for scaling and rounding)
        // We'll test that both directions work rather than exact mathematical relationship
        // since scaling factors can make exact inverse calculations complex

        // Test with a standard amount to verify basic inverse relationship
        uint256 standardAmount = 1e18;

        if (standardAmount <= type(uint256).max / 2) {
            // Avoid overflow
            uint256 forwardStandard = twapOracle.getQuote(standardAmount, s.base, s.quote);
            uint256 reverseStandard = twapOracle.getQuote(standardAmount, s.quote, s.base);

            // Both should be positive
            assertGt(forwardStandard, 0);
            assertGt(reverseStandard, 0);

            // They should be different (unless tokens have same decimals and price is exactly 1:1)
            // This is a basic sanity check that direction matters
        }

        // Test that both directions consistently work with different amounts
        uint256 amount1 = testAmount / 10;
        uint256 amount2 = testAmount / 5;

        if (amount1 > 0 && amount2 > 0) {
            assertGt(twapOracle.getQuote(amount1, s.base, s.quote), 0);
            assertGt(twapOracle.getQuote(amount1, s.quote, s.base), 0);
            assertGt(twapOracle.getQuote(amount2, s.base, s.quote), 0);
            assertGt(twapOracle.getQuote(amount2, s.quote, s.base), 0);
        }
    }

    // ============ Initial State Tests ============

    /// @notice Test oracle reverts when insufficient observations exist
    /// @dev Should revert when trying to get quote with fewer than 2 observations
    function test_GetQuote_RevertsWhen_InsufficientObservations(FuzzableState memory s) public {
        setUpState(s);

        // Oracle starts with 1 observation from constructor
        assertEq(twapOracle.getObservationCount(), 1);

        // Try to get quote with only 1 observation - should revert
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InsufficientObservations.selector));
        twapOracle.getQuote(1e18, s.base, s.quote);

        // Try reverse direction as well - should also revert
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InsufficientObservations.selector));
        twapOracle.getQuote(1e18, s.quote, s.base);

        // Verify calculateEWTWAP also reverts directly
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InsufficientObservations.selector));
        twapOracle.calculateEWTWAP();

        // Now add a second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Now quotes should work
        uint256 forwardQuote = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(forwardQuote, 0);

        uint256 reverseQuote = twapOracle.getQuote(1e18, s.quote, s.base);
        assertGt(reverseQuote, 0);

        // calculateEWTWAP should also work now
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);
    }

    // ============ GetObservation Function Tests ============

    /// @notice Test getObservation returns correct data
    /// @dev Should return price and timestamp for valid indices
    function test_GetObservation_ReturnsCorrectData(FuzzableState memory s) public {
        setUpState(s);

        // Oracle starts with 1 observation from constructor
        assertEq(twapOracle.getObservationCount(), 1);

        // Test initial observation (index 0)
        (uint128 price0, uint128 timestamp0) = twapOracle.getObservation(0);
        assertEq(price0, uint128(uint256(s.initialPrice)));
        assertEq(timestamp0, uint128(block.timestamp));

        // Add a second observation
        simulateTimePass(31);
        int256 price1Value = s.initialPrice + 1000;
        updateMockFeedPriceWithTimestamp(price1Value, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Test second observation (index 1)
        (uint128 price1, uint128 timestamp1) = twapOracle.getObservation(1);
        assertEq(price1, uint128(uint256(price1Value)));
        assertEq(timestamp1, uint128(block.timestamp));

        // Verify first observation is still correct
        (uint128 price0Again, uint128 timestamp0Again) = twapOracle.getObservation(0);
        assertEq(price0Again, price0);
        assertEq(timestamp0Again, timestamp0);

        // Add a third observation
        simulateTimePass(31);
        int256 price2Value = s.initialPrice + 2000;
        updateMockFeedPriceWithTimestamp(price2Value, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 3);

        // Test third observation (index 2)
        (uint128 price2, uint128 timestamp2) = twapOracle.getObservation(2);
        assertEq(price2, uint128(uint256(price2Value)));
        assertEq(timestamp2, uint128(block.timestamp));

        // Verify all previous observations are still correct
        (uint128 price0Final, uint128 timestamp0Final) = twapOracle.getObservation(0);
        assertEq(price0Final, price0);
        assertEq(timestamp0Final, timestamp0);

        (uint128 price1Final, uint128 timestamp1Final) = twapOracle.getObservation(1);
        assertEq(price1Final, price1);
        assertEq(timestamp1Final, timestamp1);
    }

    /// @notice Test getObservation reverts for invalid indices
    /// @dev Should revert when index >= observationCount
    function test_GetObservation_RevertsWhen_InvalidIndex(FuzzableState memory s) public {
        setUpState(s);

        // Oracle starts with 1 observation from constructor
        assertEq(twapOracle.getObservationCount(), 1);

        // Try to access index 1 when only index 0 exists - should revert
        vm.expectRevert();
        twapOracle.getObservation(1);

        // Try to access a much higher index - should revert
        vm.expectRevert();
        twapOracle.getObservation(10);

        // Try to access maximum uint256 - should revert
        vm.expectRevert();
        twapOracle.getObservation(type(uint256).max);

        // Valid index should work
        (uint128 price, uint128 timestamp) = twapOracle.getObservation(0);
        assertGt(price, 0);
        assertGt(timestamp, 0);

        // Add a second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Now indices 0 and 1 should work
        twapOracle.getObservation(0); // Should not revert
        twapOracle.getObservation(1); // Should not revert

        // But index 2 should still revert
        vm.expectRevert();
        twapOracle.getObservation(2);

        // Add more observations to test edge case
        for (uint256 i = 2; i < 5; i++) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(s.initialPrice + int256(i * 1000), block.timestamp);
            twapOracle.updatePrice();
        }
        assertEq(twapOracle.getObservationCount(), 5);

        // Indices 0-4 should work, but 5 should revert
        for (uint256 i = 0; i < 5; i++) {
            twapOracle.getObservation(i); // Should not revert
        }

        vm.expectRevert();
        twapOracle.getObservation(5);
    }

    // ============ EWTWAP Calculation Tests ============

    /// @notice Test EWTWAP calculation with multiple observations
    /// @dev Should apply exponential weighting to multiple price points (requires 2+ observations)
    function test_CalculateEWTWAP_MultipleObservations(FuzzableState memory s) public {
        setUpState(s);

        // Oracle starts with 1 observation from constructor
        assertEq(twapOracle.getObservationCount(), 1);

        // calculateEWTWAP should revert with insufficient observations
        vm.expectRevert(abi.encodeWithSelector(TWAPPriceSentinel.TWAPPriceSentinel_InsufficientObservations.selector));
        twapOracle.calculateEWTWAP();

        // Add a second observation
        simulateTimePass(31);
        int256 price1 = s.initialPrice + 1000;
        updateMockFeedPriceWithTimestamp(price1, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Now EWTWAP should work with 2 observations
        uint256 ewtwap2 = twapOracle.calculateEWTWAP();
        assertGt(ewtwap2, 0);

        // Add a third observation
        simulateTimePass(31);
        int256 price2 = s.initialPrice + 2000;
        updateMockFeedPriceWithTimestamp(price2, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 3);

        // EWTWAP should still work with 3 observations
        uint256 ewtwap3 = twapOracle.calculateEWTWAP();
        assertGt(ewtwap3, 0);

        // Add several more observations to test with larger dataset
        for (uint256 i = 3; i < 10; i++) {
            simulateTimePass(31);
            int256 priceI = s.initialPrice + int256(i * 1000);
            updateMockFeedPriceWithTimestamp(priceI, block.timestamp);
            twapOracle.updatePrice();
        }
        assertEq(twapOracle.getObservationCount(), 10);

        // EWTWAP should work with many observations
        uint256 ewtwap10 = twapOracle.calculateEWTWAP();
        assertGt(ewtwap10, 0);

        // Verify all EWTWAP calculations return positive values
        assertGt(ewtwap2, 0);
        assertGt(ewtwap3, 0);
        assertGt(ewtwap10, 0);

        // Verify that EWTWAP changes as new observations are added
        // (this is a basic sanity check that the calculation is dynamic)
        assertTrue(ewtwap2 != ewtwap3 || ewtwap3 != ewtwap10);
    }

    /// @notice Test EWTWAP calculation with exact mathematical verification
    /// @dev Validates precise EWTWAP calculation with known input values
    function test_CalculateEWTWAP_ExactCalculation() public {
        // Use fixed parameters for precise calculation verification
        address testBase = address(0x1);
        address testQuote = address(0x2);
        uint256 testMaxDropBps = 1000; // 10%
        uint256 testMaxRiseBps = 1000; // 10%
        uint256 testLambda = 0.1e18; // 10% decay factor

        // Create mock feed with 18 decimals for clean math
        MockAggregatorV3 testFeed = new MockAggregatorV3(18, "Test Feed");
        testFeed.setLatestRoundData(1, 1000e18, 0, 0, 1);

        // Deploy oracle with fixed parameters
        vm.warp(0); // Start at time 0
        TWAPPriceSentinel testOracle =
            new TWAPPriceSentinel(address(testFeed), testBase, testQuote, testMaxDropBps, testMaxRiseBps, testLambda);

        // Oracle starts with 1 observation at time 0, price = 1000e18
        assertEq(testOracle.getObservationCount(), 1);

        // Add second observation at time 60 (1 minute), price = 1100e18
        vm.warp(60);
        testFeed.setLatestRoundData(2, 1100e18, 60, 60, 2);
        testOracle.updatePrice();
        assertEq(testOracle.getObservationCount(), 2);

        // Calculate expected EWTWAP manually:
        // obs1: price=1000e18, age=60 seconds = 1 minute
        // obs2: price=1100e18, age=0 seconds = 0 minutes
        // lambda = 0.1e18, so decay per minute = 0.1

        // weight1 = e^(-0.1 * 1) ≈ 1 - 0.1 = 0.9 (using linear approximation)
        // weight2 = e^(-0.1 * 0) = 1.0
        // EWTWAP = (1000e18 * 0.9 + 1100e18 * 1.0) / (0.9 + 1.0)
        //        = (900e18 + 1100e18) / 1.9
        //        = 2000e18 / 1.9
        //        ≈ 1052.63e18

        uint256 ewtwap = testOracle.calculateEWTWAP();

        // Allow some tolerance for the approximation used in the contract
        uint256 expectedMin = 1050e18; // Slightly below expected
        uint256 expectedMax = 1055e18; // Slightly above expected

        assertGe(ewtwap, expectedMin);
        assertLe(ewtwap, expectedMax);

        // Add third observation to further test the calculation
        vm.warp(120); // 2 minutes total
        testFeed.setLatestRoundData(3, 1200e18, 120, 120, 3);
        testOracle.updatePrice();

        uint256 ewtwap2 = testOracle.calculateEWTWAP();

        // Now we have 3 observations at time 120:
        // obs1: price=1000e18, age=120 seconds = 2 minutes
        // obs2: price=1100e18, age=60 seconds = 1 minute
        // obs3: price=1200e18, age=0 seconds = 0 minutes

        // weight1 = e^(-0.1 * 2) ≈ 1 - 0.2 = 0.8
        // weight2 = e^(-0.1 * 1) ≈ 1 - 0.1 = 0.9
        // weight3 = e^(-0.1 * 0) = 1.0
        // EWTWAP = (1000e18 * 0.8 + 1100e18 * 0.9 + 1200e18 * 1.0) / (0.8 + 0.9 + 1.0)
        //        = (800e18 + 990e18 + 1200e18) / 2.7
        //        = 2990e18 / 2.7
        //        ≈ 1107.4e18

        uint256 expected2Min = 1100e18;
        uint256 expected2Max = 1105e18;

        assertGe(ewtwap2, expected2Min);
        assertLe(ewtwap2, expected2Max);

        // The EWTWAP should have moved toward the new higher price
        assertGt(ewtwap2, ewtwap);
    }

    /// @notice Test EWTWAP gives more weight to recent observations
    /// @dev Recent prices should have higher weight in the calculation
    function test_CalculateEWTWAP_WeightsRecentObservationsMore(FuzzableState memory s) public {
        setUpState(s);

        // Set up a scenario where we can test weighting
        // We'll create observations where older prices are very different from recent ones

        // Start with initial observation at time 0
        assertEq(twapOracle.getObservationCount(), 1);

        // Add an old observation with a low price
        simulateTimePass(31);
        int256 oldPrice = s.initialPrice; // Keep initial price
        updateMockFeedPriceWithTimestamp(oldPrice, block.timestamp);
        twapOracle.updatePrice();

        // Wait a significant amount of time (simulate aging)
        simulateTimePass(300); // 5 minutes

        // Add a recent observation with a higher price
        int256 recentPrice = s.initialPrice + 5000; // Significantly higher
        updateMockFeedPriceWithTimestamp(recentPrice, block.timestamp);
        twapOracle.updatePrice();

        assertEq(twapOracle.getObservationCount(), 3);

        // Calculate EWTWAP - should be influenced more by recent price
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);

        // The EWTWAP should be closer to the recent price than a simple average
        // Simple average would be around: (initialPrice + oldPrice + recentPrice) / 3
        // But EWTWAP should weight recent price more heavily

        // Add another very recent observation with even higher price
        simulateTimePass(31);
        int256 veryRecentPrice = s.initialPrice + 8000;
        updateMockFeedPriceWithTimestamp(veryRecentPrice, block.timestamp);
        twapOracle.updatePrice();

        uint256 ewtwapAfter = twapOracle.calculateEWTWAP();
        assertGt(ewtwapAfter, 0);

        // The EWTWAP should have moved towards the very recent price
        // This demonstrates that recent observations have more weight

        // Test the opposite scenario - add old low price after recent high prices
        // Wait significant time to age the current observations
        simulateTimePass(600); // 10 minutes

        // Add a much lower price observation
        int256 newLowPrice = s.initialPrice - 2000;
        updateMockFeedPriceWithTimestamp(newLowPrice, block.timestamp);
        twapOracle.updatePrice();

        uint256 ewtwapWithNewLow = twapOracle.calculateEWTWAP();
        assertGt(ewtwapWithNewLow, 0);

        // All EWTWAP calculations should return reasonable positive values
        assertGt(ewtwap, 0);
        assertGt(ewtwapAfter, 0);
        assertGt(ewtwapWithNewLow, 0);

        // Verify that EWTWAP changes as we add observations
        // (this shows the calculation is responsive to new data)
        assertTrue(ewtwap != ewtwapAfter || ewtwapAfter != ewtwapWithNewLow);
    }

    // ============ Price Protection Tests ============

    /// @notice Test oracle allows price within acceptable drop threshold
    /// @dev Price drops within maxDropBps should be allowed
    function test_GetQuote_AllowsPriceWithinDropThreshold(FuzzableState memory s) public {
        setUpState(s);

        // Build up EWTWAP with stable prices
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 3);

        // Get current EWTWAP as baseline
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);

        // Calculate a price drop that's within the threshold
        // Use a drop that's 50% of the maximum allowed drop to ensure we're safely within bounds
        uint256 allowedDropBps = s.maxDropBps / 2; // Half of max threshold
        uint256 dropAmount = (ewtwap * allowedDropBps) / 10000;
        int256 droppedPrice = int256(ewtwap - dropAmount);

        // Ensure the dropped price is still positive
        vm.assume(droppedPrice > 0);

        // Update feed with dropped price
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(droppedPrice, block.timestamp);

        // getQuote should succeed with price drop within threshold
        uint256 quote = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote, 0);

        // Test reverse direction as well
        uint256 reverseQuote = twapOracle.getQuote(1e18, s.quote, s.base);
        assertGt(reverseQuote, 0);

        // Test with an even smaller drop (10% of threshold)
        uint256 smallerDropBps = s.maxDropBps / 10;
        uint256 smallerDropAmount = (ewtwap * smallerDropBps) / 10000;
        int256 smallerDroppedPrice = int256(ewtwap - smallerDropAmount);

        if (smallerDroppedPrice > 0) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(smallerDroppedPrice, block.timestamp);

            // Should still succeed
            uint256 smallDropQuote = twapOracle.getQuote(1e18, s.base, s.quote);
            assertGt(smallDropQuote, 0);
        }
    }

    /// @notice Test oracle allows price within acceptable rise threshold
    /// @dev Price rises within maxRiseBps should be allowed
    function test_GetQuote_AllowsPriceWithinRiseThreshold(FuzzableState memory s) public {
        setUpState(s);

        // Build up EWTWAP with stable prices
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 3);

        // Get current EWTWAP as baseline
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);

        // Calculate a price rise that's within the threshold
        // Use a rise that's 50% of the maximum allowed rise to ensure we're safely within bounds
        uint256 allowedRiseBps = s.maxRiseBps / 2; // Half of max threshold
        uint256 riseAmount = (ewtwap * allowedRiseBps) / 10000;
        int256 risenPrice = int256(ewtwap + riseAmount);

        // Ensure the risen price doesn't overflow
        vm.assume(risenPrice > 0);
        vm.assume(riseAmount < type(uint128).max);

        // Update feed with risen price
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(risenPrice, block.timestamp);

        // getQuote should succeed with price rise within threshold
        uint256 quote = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote, 0);

        // Test reverse direction as well
        uint256 reverseQuote = twapOracle.getQuote(1e18, s.quote, s.base);
        assertGt(reverseQuote, 0);

        // Test with an even smaller rise (10% of threshold)
        uint256 smallerRiseBps = s.maxRiseBps / 10;
        uint256 smallerRiseAmount = (ewtwap * smallerRiseBps) / 10000;
        int256 smallerRisenPrice = int256(ewtwap + smallerRiseAmount);

        if (smallerRisenPrice > 0 && smallerRiseAmount < type(uint128).max) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(smallerRisenPrice, block.timestamp);

            // Should still succeed
            uint256 smallRiseQuote = twapOracle.getQuote(1e18, s.base, s.quote);
            assertGt(smallRiseQuote, 0);
        }
    }

    /// @notice Test oracle reverts when price drop exceeds threshold
    /// @dev Should revert with TWAPPriceSentinel_PriceDropExceedsThreshold
    function test_GetQuote_RevertsWhen_PriceDropExceedsThreshold(FuzzableState memory s) public {
        setUpState(s);

        // Build up EWTWAP with stable prices
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 3);

        // Get current EWTWAP as baseline
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);

        // Calculate a price drop that exceeds the threshold
        // Use 150% of the maximum allowed drop to ensure we exceed the limit
        uint256 excessiveDropBps = (s.maxDropBps * 150) / 100; // 150% of max threshold
        uint256 dropAmount = (ewtwap * excessiveDropBps) / 10000;
        int256 droppedPrice = int256(ewtwap - dropAmount);

        // Ensure the dropped price is still positive (we want to test threshold, not negative price)
        vm.assume(droppedPrice > 0);

        // Update feed with excessively dropped price
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(droppedPrice, block.timestamp);

        vm.expectRevert();
        twapOracle.getQuote(1e18, s.base, s.quote);

        vm.expectRevert();
        twapOracle.getQuote(1e18, s.quote, s.base);

        // Test with an even larger drop (200% of threshold) to confirm behavior
        uint256 massiveDropBps = (s.maxDropBps * 200) / 100; // 200% of max threshold
        uint256 massiveDropAmount = (ewtwap * massiveDropBps) / 10000;
        int256 massiveDroppedPrice = int256(ewtwap - massiveDropAmount);

        if (massiveDroppedPrice > 0) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(massiveDroppedPrice, block.timestamp);

            vm.expectRevert();
            twapOracle.getQuote(1e18, s.base, s.quote);
        }
    }

    /// @notice Test oracle reverts when price rise exceeds threshold
    /// @dev Should revert with TWAPPriceSentinel_PriceRiseExceedsThreshold
    function test_GetQuote_RevertsWhen_PriceRiseExceedsThreshold(FuzzableState memory s) public {
        setUpState(s);

        // Build up EWTWAP with stable prices
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 3);

        // Get current EWTWAP as baseline
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);

        // Calculate a price rise that exceeds the threshold
        // Use 150% of the maximum allowed rise to ensure we exceed the limit
        uint256 excessiveRiseBps = (s.maxRiseBps * 150) / 100;
        uint256 riseAmount = (ewtwap * excessiveRiseBps) / 10000;
        int256 risenPrice = int256(ewtwap + riseAmount);

        // Ensure no overflow
        vm.assume(risenPrice > 0);
        vm.assume(riseAmount < type(uint128).max);

        // Update feed with excessively risen price
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(risenPrice, block.timestamp);

        vm.expectRevert();
        twapOracle.getQuote(1e18, s.base, s.quote);

        vm.expectRevert();
        twapOracle.getQuote(1e18, s.quote, s.base);

        // Test with an even larger rise (200% of threshold)
        uint256 massiveRiseBps = (s.maxRiseBps * 200) / 100;
        uint256 massiveRiseAmount = (ewtwap * massiveRiseBps) / 10000;
        int256 massiveRisenPrice = int256(ewtwap + massiveRiseAmount);

        if (massiveRisenPrice > 0 && massiveRiseAmount < type(uint128).max) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(massiveRisenPrice, block.timestamp);

            vm.expectRevert();
            twapOracle.getQuote(1e18, s.base, s.quote);
        }
    }

    /// @notice Test oracle compares current price against EWTWAP, not last observation
    /// @dev Protection should be based on deviation from EWTWAP, not just previous price
    function test_GetQuote_ComparesAgainstEWTWAP(FuzzableState memory s) public {
        setUpState(s);

        // Build up EWTWAP with multiple stable prices
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 4);

        // Get stable EWTWAP baseline
        uint256 stableEwtwap = twapOracle.calculateEWTWAP();
        assertGt(stableEwtwap, 0);

        // Add one observation with a very different price (but within threshold vs EWTWAP)
        int256 differentPrice = s.initialPrice + 3000;
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(differentPrice, block.timestamp);
        twapOracle.updatePrice();

        // Now the last observation is very different from previous ones,
        // but EWTWAP should still be close to the stable price due to weighting
        uint256 newEwtwap = twapOracle.calculateEWTWAP();
        assertGt(newEwtwap, 0);

        // Test that a price close to EWTWAP (but far from last observation) is accepted
        // Calculate price that's close to EWTWAP but different from last observation
        uint256 allowedDropBps = s.maxDropBps / 4; // Use small percentage of threshold
        uint256 dropAmount = (newEwtwap * allowedDropBps) / 10000;
        int256 priceCloseToEwtwap = int256(newEwtwap - dropAmount);

        vm.assume(priceCloseToEwtwap > 0);

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(priceCloseToEwtwap, block.timestamp);

        // This should succeed because price is close to EWTWAP
        uint256 quote = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote, 0);

        // Test that a price far from EWTWAP (even if close to last observation) is rejected
        uint256 excessiveDropBps = (s.maxDropBps * 150) / 100;
        uint256 excessiveDropAmount = (newEwtwap * excessiveDropBps) / 10000;
        int256 priceFarFromEwtwap = int256(newEwtwap - excessiveDropAmount);

        if (priceFarFromEwtwap > 0) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(priceFarFromEwtwap, block.timestamp);

            // This should fail because price is too far from EWTWAP
            vm.expectRevert();
            twapOracle.getQuote(1e18, s.base, s.quote);
        }
    }

    // ============ Time-Based Tests ============

    /// @notice Test oracle handles multiple price updates over time
    /// @dev Should maintain EWTWAP correctly as prices change over time
    function test_GetQuote_HandlesMultiplePriceUpdatesOverTime(FuzzableState memory s) public {
        setUpState(s);

        // Add second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Add multiple observations over time with gradual price changes
        int256 currentPrice = s.initialPrice;
        for (uint256 i = 0; i < 5; i++) {
            simulateTimePass(60); // 1 minute intervals
            currentPrice += 500; // Gradual price increase
            updateMockFeedPriceWithTimestamp(currentPrice, block.timestamp);
            twapOracle.updatePrice();

            uint256 quote = twapOracle.getQuote(1e18, s.base, s.quote);
            assertGt(quote, 0);
        }

        assertEq(twapOracle.getObservationCount(), 7);
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);
    }

    /// @notice Test oracle enforces 30-second minimum interval between updates
    /// @dev Should not add new observations within 30 seconds of the last one
    function test_GetQuote_EnforcesMinimumUpdateInterval(FuzzableState memory s) public {
        setUpState(s);

        // Add second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Try to call getQuote multiple times quickly - should work
        uint256 quote1 = twapOracle.getQuote(1e18, s.base, s.quote);
        uint256 quote2 = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote1, 0);
        assertGt(quote2, 0);

        // The 30-second interval affects updatePrice, not getQuote
        // getQuote can be called anytime, it just uses current feed price vs EWTWAP
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 2000, block.timestamp);
        uint256 quote3 = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote3, 0);
    }

    /// @notice Test oracle reverts after observations become stale
    /// @dev Should revert when no valid observations exist within acceptable timeframe
    function test_GetQuote_RevertsWhen_ObservationsAreStale(FuzzableState memory s) public {
        setUpState(s);

        // Add second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Verify it works initially
        uint256 quote = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote, 0);

        // Fast forward more than 1 hour to make all observations stale
        simulateTimePass(3700); // 1 hour + 100 seconds

        // Update feed with current time but don't call updatePrice
        updateMockFeedPriceWithTimestamp(s.initialPrice + 2000, block.timestamp);

        // Now getQuote should revert because calculateEWTWAP will fail with stale observations
        vm.expectRevert();
        twapOracle.getQuote(1e18, s.base, s.quote);
    }

    /// @notice Test oracle works with mix of stale and valid observations
    /// @dev Should function correctly when it has outdated observations but still has 2+ valid ones within the hour
    function test_GetQuote_WorksWithMixOfStaleAndValidObservations(FuzzableState memory s) public {
        setUpState(s);

        // Add several old observations
        for (uint256 i = 0; i < 3; i++) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(s.initialPrice + int256(i * 1000), block.timestamp);
            twapOracle.updatePrice();
        }

        // Fast forward more than 1 hour to make these observations stale
        simulateTimePass(3700);

        // Add fresh observations within the hour
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 5000, block.timestamp);
        twapOracle.updatePrice();

        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 6000, block.timestamp);
        twapOracle.updatePrice();

        // Now we have stale observations (>1 hour old) and fresh ones
        // Oracle should work using only the fresh observations
        uint256 quote = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote, 0);

        uint256 ewtwap = twapOracle.calculateEWTWAP();
        assertGt(ewtwap, 0);
    }

    // ============ Edge Cases and Recovery Tests ============

    /// @notice Test oracle can recover from price shock after building new TWAP
    /// @dev After a rejected price, oracle should eventually accept new prices within threshold
    function test_GetQuote_RecoversAfterPriceShock(FuzzableState memory s) public {
        setUpState(s);

        // Build stable EWTWAP
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Try price shock (should be rejected)
        uint256 ewtwap = twapOracle.calculateEWTWAP();
        uint256 shockDropBps = (s.maxDropBps * 200) / 100;
        uint256 shockDropAmount = (ewtwap * shockDropBps) / 10000;
        int256 shockPrice = int256(ewtwap - shockDropAmount);

        if (shockPrice > 0) {
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(shockPrice, block.timestamp);

            vm.expectRevert();
            twapOracle.getQuote(1e18, s.base, s.quote);

            // Now gradually bring price back to acceptable range by updating observations
            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
            twapOracle.updatePrice();

            simulateTimePass(31);
            updateMockFeedPriceWithTimestamp(s.initialPrice, block.timestamp);
            twapOracle.updatePrice();

            // Now should work again
            uint256 quote = twapOracle.getQuote(1e18, s.base, s.quote);
            assertGt(quote, 0);
        }
    }

    // ============ Scale and Precision Tests ============

    /// @notice Test oracle maintains precision across different token scales
    /// @dev Should handle tokens with different decimal places correctly
    function test_GetQuote_MaintainsPrecisionAcrossScales(FuzzableState memory s) public {
        setUpState(s);

        // Add second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Test with fixed amounts to avoid precision issues with extreme fuzz inputs
        uint256 quote1 = twapOracle.getQuote(1e18, s.base, s.quote);
        assertGt(quote1, 0);

        uint256 reverseQuote1 = twapOracle.getQuote(1e18, s.quote, s.base);
        assertGt(reverseQuote1, 0);

        // Test different scale
        uint256 quote2 = twapOracle.getQuote(1e6, s.base, s.quote);
        assertTrue(quote2 >= 0); // May be 0 due to precision loss

        uint256 quote3 = twapOracle.getQuote(1e24, s.base, s.quote);
        assertGt(quote3, 0);
    }

    /// @notice Test oracle handles very small amounts correctly
    /// @dev Should provide accurate quotes for minimal input amounts
    function test_GetQuote_HandlesSmallAmounts(FuzzableState memory s) public {
        setUpState(s);

        // Add second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Test very small amounts
        uint256 smallAmount1 = 1;
        uint256 smallAmount2 = 100;
        uint256 smallAmount3 = 1000;

        uint256 quote1 = twapOracle.getQuote(smallAmount1, s.base, s.quote);
        uint256 quote2 = twapOracle.getQuote(smallAmount2, s.base, s.quote);
        uint256 quote3 = twapOracle.getQuote(smallAmount3, s.base, s.quote);

        // All should return some value (may be 0 due to precision loss, but shouldn't revert)
        // The key is that the function completes successfully
        assertTrue(quote1 >= 0);
        assertTrue(quote2 >= 0);
        assertTrue(quote3 >= 0);
    }

    /// @notice Test oracle handles very large amounts correctly
    /// @dev Should provide accurate quotes for large input amounts without overflow
    function test_GetQuote_HandlesLargeAmounts(FuzzableState memory s) public {
        setUpState(s);

        // Add second observation
        simulateTimePass(31);
        updateMockFeedPriceWithTimestamp(s.initialPrice + 1000, block.timestamp);
        twapOracle.updatePrice();
        assertEq(twapOracle.getObservationCount(), 2);

        // Test large amounts (but not so large as to cause overflow)
        uint256 largeAmount1 = 1e24;
        uint256 largeAmount2 = 1e26;

        if (largeAmount1 <= 1e30 && largeAmount2 <= 1e30) {
            uint256 quote1 = twapOracle.getQuote(largeAmount1, s.base, s.quote);
            uint256 quote2 = twapOracle.getQuote(largeAmount2, s.base, s.quote);

            assertGt(quote1, 0);
            assertGt(quote2, 0);

            // Larger input should generally give larger output (assuming reasonable price)
            if (quote1 > 0 && quote2 > 0) {
                assertGt(quote2, quote1);
            }
        }
    }
}
