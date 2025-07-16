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
        assertEq(API3Oracle(oracle).feed(), s.feed);
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
        vm.expectRevert();
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
        vm.expectRevert();
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
        setUpState(FuzzableState({
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
        }));
        
        assertEq(API3Oracle(oracle).name(), "API3Oracle");
    }
}