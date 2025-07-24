// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {API3OracleHelper} from "test/adapter/api3/API3OracleHelper.sol";
import {boundAddr} from "test/utils/TestUtils.sol";
import {API3Oracle} from "src/adapter/api3/API3Oracle.sol";
import {Errors} from "src/lib/Errors.sol";

contract API3OracleTest is API3OracleHelper {
    function test_Constructor_Integrity(FuzzableState memory s) public {
        setUpState(s);
        assertEq(API3Oracle(oracle).base(), s.base);
        assertEq(API3Oracle(oracle).quote(), s.quote);
        assertEq(address(API3Oracle(oracle).feed()), s.feed);
        assertEq(API3Oracle(oracle).maxStaleness(), s.maxStaleness);
    }

    function test_Constructor_RevertsWhen_MaxStalenessTooLow(FuzzableState memory s) public {
        setBounds(
            Bounds({
                minBaseDecimals: 6,
                maxBaseDecimals: 18,
                minQuoteDecimals: 6,
                maxQuoteDecimals: 18,
                minInAmount: 1e6,
                maxInAmount: 1e20,
                minValue: 1e8,
                maxValue: 1e20
            })
        );
        setBehavior(Behavior.Constructor_MaxStalenessTooLow, true);
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        setUpState(s);
    }

    function test_Constructor_RevertsWhen_MaxStalenessTooHigh(FuzzableState memory s) public {
        setBounds(
            Bounds({
                minBaseDecimals: 6,
                maxBaseDecimals: 18,
                minQuoteDecimals: 6,
                maxQuoteDecimals: 18,
                minInAmount: 1e6,
                maxInAmount: 1e20,
                minValue: 1e8,
                maxValue: 1e20
            })
        );
        setBehavior(Behavior.Constructor_MaxStalenessTooHigh, true);
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        setUpState(s);
    }

    function test_Quote_RevertsWhen_InvalidTokens(FuzzableState memory s, address otherA, address otherB) public {
        setUpState(s);
        otherA = boundAddr(otherA);
        otherB = boundAddr(otherB);
        vm.assume(otherA != s.base && otherA != s.quote);
        vm.assume(otherB != s.base && otherB != s.quote);
        expectNotSupported(s.inAmount, s.base, s.base);
        expectNotSupported(s.inAmount, s.quote, s.quote);
        expectNotSupported(s.inAmount, s.base, otherA);
        expectNotSupported(s.inAmount, otherA, s.base);
        expectNotSupported(s.inAmount, s.quote, otherA);
        expectNotSupported(s.inAmount, otherA, s.quote);
        expectNotSupported(s.inAmount, otherA, otherA);
        expectNotSupported(s.inAmount, otherA, otherB);
    }

    function test_Quote_RevertsWhen_ProxyReverts(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReverts, true);
        setUpState(s);

        bytes memory err = abi.encodePacked("oops");
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_ZeroPrice(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsZeroPrice, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_NegativePrice(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsNegativePrice, true);
        setUpState(s);

        bytes memory err = abi.encodeWithSelector(Errors.PriceOracle_InvalidAnswer.selector);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_RevertsWhen_TooStale(FuzzableState memory s) public {
        setBehavior(Behavior.FeedReturnsStalePrice, true);
        setUpState(s);

        bytes memory err =
            abi.encodeWithSelector(Errors.PriceOracle_TooStale.selector, s.blockTimestamp - s.timestamp, s.maxStaleness);
        expectRevertForAllQuotePermutations(s.inAmount, s.base, s.quote, err);
    }

    function test_Quote_Integrity(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmount(s);
        uint256 outAmount = API3Oracle(oracle).getQuote(s.inAmount, s.base, s.quote);
        assertEq(outAmount, expectedOutAmount);

        (uint256 bidOutAmount, uint256 askOutAmount) = API3Oracle(oracle).getQuotes(s.inAmount, s.base, s.quote);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_Quote_Integrity_Inverse(FuzzableState memory s) public {
        setUpState(s);

        uint256 expectedOutAmount = calcOutAmountInverse(s);
        uint256 outAmount = API3Oracle(oracle).getQuote(s.inAmount, s.quote, s.base);
        assertEq(outAmount, expectedOutAmount);

        (uint256 bidOutAmount, uint256 askOutAmount) = API3Oracle(oracle).getQuotes(s.inAmount, s.quote, s.base);
        assertEq(bidOutAmount, expectedOutAmount);
        assertEq(askOutAmount, expectedOutAmount);
    }

    function test_Name() public {
        setUpState(
            FuzzableState({
                base: address(0x1),
                quote: address(0x2),
                feed: address(0x3),
                maxStaleness: 1 hours,
                baseDecimals: 18,
                quoteDecimals: 18,
                value: 1e18,
                timestamp: 1000,
                blockTimestamp: 1000,
                inAmount: 1e18
            })
        );

        assertEq(API3Oracle(oracle).name(), "API3Oracle BASE/QUOTE");
    }

    function test_Constructor_RevertsWhen_BaseIsZero() public {
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        new API3Oracle(
            "ETH",
            address(0), // base is zero
            "USD",
            address(0x348),
            address(0x3),
            1 hours
        );
    }

    function test_Constructor_RevertsWhen_QuoteIsZero() public {
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        new API3Oracle(
            "ETH",
            address(0x1),
            "USD",
            address(0), // quote is zero
            address(0x3),
            1 hours
        );
    }

    function test_Constructor_RevertsWhen_FeedIsZero() public {
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        new API3Oracle(
            "ETH",
            address(0x1),
            "USD",
            address(0x348),
            address(0), // feed is zero
            1 hours
        );
    }

    function test_Constructor_SucceedsAt26Hours() public {
        // Mock feed decimals call
        address mockFeed = address(0x3);
        vm.mockCall(mockFeed, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(18)));

        // Should succeed at exactly 26 hours (24h + 2h buffer)
        API3Oracle oracle = new API3Oracle("ETH", address(0x1), "USD", address(0x348), mockFeed, 26 hours);

        assertEq(oracle.maxStaleness(), 26 hours);
        assertEq(oracle.feedDecimals(), 18);
    }

    function test_Constructor_RevertsAt26HoursPlus1Second() public {
        // Should revert at 26 hours + 1 second
        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        new API3Oracle("ETH", address(0x1), "USD", address(0x348), address(0x3), 26 hours + 1 seconds);
    }

    function test_Constructor_RevertsWhen_USDFeedReturnsNon18Decimals() public {
        // Mock a feed that returns non-18 decimals for USD
        address mockFeed = address(0x123);
        vm.mockCall(mockFeed, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(8)));

        vm.expectRevert(Errors.PriceOracle_InvalidConfiguration.selector);
        new API3Oracle(
            "ETH",
            address(0x1),
            "USD", // USD symbol with non-18 decimals should revert
            address(0x348),
            mockFeed,
            1 hours
        );
    }

    function test_Constructor_SucceedsWhen_USDFeedReturns18Decimals() public {
        // Mock a feed that returns 18 decimals for USD
        address mockFeed = address(0x124);
        vm.mockCall(mockFeed, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(18)));
        vm.mockCall(
            mockFeed,
            abi.encodeWithSelector(bytes4(keccak256("read()"))),
            abi.encode(int224(1e18), uint256(block.timestamp))
        );

        API3Oracle oracle = new API3Oracle(
            "ETH",
            address(0x1),
            "USD", // USD symbol with 18 decimals should succeed
            address(0x348),
            mockFeed,
            1 hours
        );

        assertEq(oracle.feedDecimals(), 18);
    }

    function test_Constructor_SucceedsWhen_NonUSDFeedReturnsNon18Decimals() public {
        // Mock a feed that returns non-18 decimals for non-USD pair
        address mockFeed = address(0x125);
        vm.mockCall(mockFeed, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), abi.encode(uint8(8)));
        vm.mockCall(
            mockFeed,
            abi.encodeWithSelector(bytes4(keccak256("read()"))),
            abi.encode(int224(1e8), uint256(block.timestamp))
        );

        API3Oracle oracle = new API3Oracle(
            "rETH",
            address(0x1),
            "WETH", // Non-USD symbol with non-18 decimals should succeed
            address(0x2),
            mockFeed,
            1 hours
        );

        assertEq(oracle.feedDecimals(), 8);
    }

    function test_Constructor_FallbackTo18DecimalsWhen_DecimalsCallFails() public {
        // Mock a feed that doesn't implement decimals()
        address mockFeed = address(0x126);
        vm.mockCallRevert(mockFeed, abi.encodeWithSelector(bytes4(keccak256("decimals()"))), "not implemented");
        vm.mockCall(
            mockFeed,
            abi.encodeWithSelector(bytes4(keccak256("read()"))),
            abi.encode(int224(1e18), uint256(block.timestamp))
        );

        API3Oracle oracle = new API3Oracle("ETH", address(0x1), "USD", address(0x348), mockFeed, 1 hours);

        assertEq(oracle.feedDecimals(), 18); // Should fallback to 18
    }
}
