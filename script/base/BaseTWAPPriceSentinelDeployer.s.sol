// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {TWAPPriceSentinel} from "../../src/adapter/TWAPPriceSentinel.sol";
import {AggregatorV3Interface} from "../../src/adapter/chainlink/AggregatorV3Interface.sol";
import {stdJson} from "forge-std/StdJson.sol";

/// @title BaseTWAPPriceSentinelDeployer
/// @notice Base deployment script for TWAPPriceSentinel oracle with TWAP protection
/// @dev Provides common deployment logic and testing utilities
abstract contract BaseTWAPPriceSentinelDeployer is Script {
    using stdJson for string;

    struct DeploymentParams {
        address priceFeed;
        address base;
        address quote;
        uint256 maxDropBps;
        uint256 maxRiseBps;
        uint256 lambda;
        string description;
    }

    /// @notice Deploy and initialize TWAPPriceSentinel with proper price history
    /// @param params Deployment parameters
    /// @return sentinel The deployed TWAPPriceSentinel instance
    function deployAndInitialize(DeploymentParams memory params) internal returns (TWAPPriceSentinel sentinel) {
        console.log("\n=== Deploying TWAPPriceSentinel ===");
        console.log("Description:", params.description);

        // Deploy the sentinel
        sentinel = new TWAPPriceSentinel(
            params.priceFeed, params.base, params.quote, params.maxDropBps, params.maxRiseBps, params.lambda
        );

        console.log("TWAPPriceSentinel deployed at:", address(sentinel));
        console.log("Wrapping price feed at:", params.priceFeed);
        console.log("Base token:", params.base);
        console.log("Quote token:", params.quote);
        console.log("Max drop:", params.maxDropBps, "bps");
        console.log("Max rise:", params.maxRiseBps, "bps");
        console.log("Lambda:", params.lambda);

        // Initialize with price history
        console.log("\n=== Initializing Price History ===");
        initializePriceHistory(sentinel);

        return sentinel;
    }

    /// @notice Initialize the oracle with two price observations 30 seconds apart
    /// @param sentinel The TWAPPriceSentinel to initialize
    function initializePriceHistory(TWAPPriceSentinel sentinel) internal {
        console.log("Current observation count:", sentinel.getObservationCount());
        console.log("Oracle needs at least 2 observations to calculate EWTWAP");

        // First observation was already added in constructor
        (uint128 price1, uint128 timestamp1) = sentinel.getObservation(0);
        console.log("\nObservation 1 (from constructor):");
        console.log("  Price:", price1);
        console.log("  Timestamp:", timestamp1);

        // Wait 31 seconds (minimum is 30 seconds)
        console.log("\nWaiting 31 seconds for price update...");
        console.log("Please wait for the oracle to accept a new observation...");
        
        // Use vm.sleep to actually wait in real time
        vm.sleep(31 * 1000); // vm.sleep takes milliseconds

        // Add second observation
        console.log("Adding second observation...");
        sentinel.updatePrice();

        (uint128 price2, uint128 timestamp2) = sentinel.getObservation(1);
        console.log("\nObservation 2:");
        console.log("  Price:", price2);
        console.log("  Timestamp:", timestamp2);
        console.log("  Time elapsed:", timestamp2 - timestamp1, "seconds");

        console.log("\nPrice history initialized successfully!");
        console.log("Total observations:", sentinel.getObservationCount());
    }

    /// @notice Run comprehensive tests on the deployed oracle
    /// @param sentinel The TWAPPriceSentinel to test
    /// @param params The deployment parameters for context
    function runTests(TWAPPriceSentinel sentinel, DeploymentParams memory params) internal view {
        console.log("\n=== Running Oracle Tests ===");

        // Test 1: Basic getQuote functionality
        console.log("\n1. Testing getQuote (base -> quote):");
        try sentinel.getQuote(1e18, params.base, params.quote) returns (uint256 price) {
            console.log("   Success! Price for 1 base token:", price, "quote tokens");
        } catch Error(string memory reason) {
            console.log("   Failed:", reason);
        } catch (bytes memory) {
            console.log("   Failed with low-level error");
        }

        // Test 2: Reverse direction
        console.log("\n2. Testing getQuote (quote -> base):");
        try sentinel.getQuote(1e18, params.quote, params.base) returns (uint256 price) {
            console.log("   Success! Price for 1 quote token:", price, "base tokens");
        } catch Error(string memory reason) {
            console.log("   Failed:", reason);
        } catch (bytes memory) {
            console.log("   Failed with low-level error");
        }

        // Test 3: EWTWAP calculation
        console.log("\n3. Testing EWTWAP calculation:");
        try sentinel.calculateEWTWAP() returns (uint256 ewtwap) {
            console.log("   Success! Current EWTWAP:", ewtwap);

            // Compare with current feed price
            (, int256 currentPrice,,,) = AggregatorV3Interface(params.priceFeed).latestRoundData();
            console.log("   Current feed price:", uint256(currentPrice));

            if (uint256(currentPrice) > ewtwap) {
                uint256 deviation = (uint256(currentPrice) - ewtwap) * 10000 / ewtwap;
                console.log("   Price is", deviation, "bps above EWTWAP");
            } else {
                uint256 deviation = (ewtwap - uint256(currentPrice)) * 10000 / ewtwap;
                console.log("   Price is", deviation, "bps below EWTWAP");
            }
        } catch Error(string memory reason) {
            console.log("   Failed:", reason);
        } catch (bytes memory) {
            console.log("   Failed with low-level error");
        }

        // Test 4: Different amounts
        console.log("\n4. Testing different amounts:");
        uint256[4] memory testAmounts = [uint256(1e6), 1e12, 1e18, 1e24];
        for (uint256 i = 0; i < testAmounts.length; i++) {
            try sentinel.getQuote(testAmounts[i], params.base, params.quote) returns (uint256 price) {
                console.log("   Amount:", testAmounts[i], "-> Price:", price);
            } catch {
                console.log("   Amount:", testAmounts[i], "-> Failed");
            }
        }

        // Test 5: Observation details
        console.log("\n5. Observation details:");
        uint256 obsCount = sentinel.getObservationCount();
        console.log("   Total observations:", obsCount);
        for (uint256 i = 0; i < obsCount && i < 5; i++) {
            (uint128 price, uint128 timestamp) = sentinel.getObservation(i);
            console.log(string.concat("   Obs ", vm.toString(i), " - Price: ", vm.toString(price), " Timestamp: ", vm.toString(timestamp)));
        }
    }

    /// @notice Verify the price feed is working correctly
    /// @param feedAddress The address of the price feed to verify
    function verifyFeed(address feedAddress) internal view {
        console.log("\n=== Verifying Price Feed ===");
        console.log("Feed address:", feedAddress);

        try AggregatorV3Interface(feedAddress).decimals() returns (uint8 decimals) {
            console.log("Feed decimals:", decimals);
        } catch {
            console.log("Failed to get decimals - may not be a valid feed");
            return;
        }


        try AggregatorV3Interface(feedAddress).latestRoundData() returns (
            uint80 roundId, int256 price, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound
        ) {
            console.log("Latest round data:");
            console.log("  Round ID:", roundId);
            console.log("  Price:", uint256(price));
            console.log("  Updated at:", updatedAt);
            console.log("  Started at:", startedAt);
            console.log("  Answered in round:", answeredInRound);

            // Check if price is reasonable
            if (price <= 0) {
                console.log("  WARNING: Price is not positive!");
            }

            // Check staleness
            if (block.timestamp > updatedAt) {
                uint256 age = block.timestamp - updatedAt;
                console.log("  Age:", age, "seconds");
                if (age > 3600) {
                    console.log("  WARNING: Price is more than 1 hour old!");
                }
            }
        } catch Error(string memory reason) {
            console.log("Failed to get latest round data:", reason);
        } catch (bytes memory) {
            console.log("Failed to get latest round data with low-level error");
        }
    }

    /// @notice Get deployment parameters (to be implemented by child contracts)
    function getDeploymentParams() internal view virtual returns (DeploymentParams memory);

    /// @notice Main deployment function
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Get deployment parameters from child contract
        DeploymentParams memory params = getDeploymentParams();

        // Verify feed before deployment
        verifyFeed(params.priceFeed);

        // Start deployment
        vm.startBroadcast(deployerPrivateKey);

        // Deploy and initialize
        TWAPPriceSentinel sentinel = deployAndInitialize(params);

        vm.stopBroadcast();

        // Run tests (outside of broadcast to save gas)
        runTests(sentinel, params);

        console.log("\n=== Deployment Complete ===");
        console.log("TWAPPriceSentinel address:", address(sentinel));

        // Save deployment info to JSON
        saveDeploymentInfo(sentinel, params);
    }

    /// @notice Save deployment information to JSON file
    /// @param sentinel The deployed TWAPPriceSentinel instance
    /// @param params The deployment parameters used
    function saveDeploymentInfo(TWAPPriceSentinel sentinel, DeploymentParams memory params) internal {
        string memory json = "deployment";

        // Deployment address
        json.serialize("address", address(sentinel));

        // Constructor parameters
        string memory constructorParams = "constructorParams";
        constructorParams.serialize("priceFeed", params.priceFeed);
        constructorParams.serialize("base", params.base);
        constructorParams.serialize("quote", params.quote);
        constructorParams.serialize("maxDropBps", params.maxDropBps);
        constructorParams.serialize("maxRiseBps", params.maxRiseBps);
        constructorParams.serialize("lambda", params.lambda);
        json.serialize("constructorParams", constructorParams);

        // Add deployment metadata
        json.serialize("deploymentTimestamp", block.timestamp);
        json.serialize("deploymentBlock", block.number);
        json.serialize("chainId", block.chainid);

        // Create output directory path
        string memory outputDir = string(abi.encodePacked("output/", vm.toString(block.chainid)));

        // Get the script name from the name constant in child contract
        string memory scriptName = this.name();
        string memory filename = string(abi.encodePacked(scriptName, ".json"));
        string memory filepath = string(abi.encodePacked(outputDir, "/", filename));

        // Ensure directory exists
        string[] memory mkdirInputs = new string[](3);
        mkdirInputs[0] = "mkdir";
        mkdirInputs[1] = "-p";
        mkdirInputs[2] = outputDir;
        vm.ffi(mkdirInputs);

        // Write JSON to file
        vm.writeJson(json, filepath);

        console.log("\nDeployment info saved to:", filepath);
    }

    /// @notice Script name constant - must be defined by child contracts
    function name() external view virtual returns (string memory);
}
