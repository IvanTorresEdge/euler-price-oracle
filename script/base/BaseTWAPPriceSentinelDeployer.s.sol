// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {TWAPPriceSentinel} from "../../src/adapter/TWAPPriceSentinel.sol";

/// @title BaseTWAPPriceSentinelDeployer
/// @notice Base deployment script for TWAPPriceSentinel oracle with TWAP protection
/// @dev Provides common deployment logic and testing utilities
abstract contract BaseTWAPPriceSentinelDeployer is Script {
    struct DeploymentParams {
        address priceFeed;
        address base;
        address quote;
        uint256 maxDropBps;
        uint256 maxRiseBps;
        uint256 lambda;
        string description;
    }

    /// @notice Deploy TWAPPriceSentinel
    /// @param params Deployment parameters
    /// @return sentinel The deployed TWAPPriceSentinel instance
    function deploy(DeploymentParams memory params) internal returns (TWAPPriceSentinel sentinel) {
        console.log("\n=== Deploying TWAPPriceSentinel ===");
        console.log("Description:", params.description);

        // Deploy the sentinel
        sentinel = new TWAPPriceSentinel(
            params.priceFeed, params.base, params.quote, params.maxDropBps, params.maxRiseBps, params.lambda
        );

        console.log("\nTWAPPriceSentinel deployed at:", address(sentinel));
        console.log("\nConfiguration:");
        console.log("  Price feed:", params.priceFeed);
        console.log("  Base token:", params.base);
        console.log("  Quote token:", params.quote);
        console.log(string.concat("  Max drop: ", vm.toString(params.maxDropBps), " bps"));
        console.log(string.concat("  Max rise: ", vm.toString(params.maxRiseBps), " bps"));
        console.log(string.concat("  Lambda: ", vm.toString(params.lambda)));

        return sentinel;
    }

    /// @notice Get deployment parameters (to be implemented by child contracts)
    function getDeploymentParams() internal view virtual returns (DeploymentParams memory);

    /// @notice Main deployment function
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");

        // Get deployment parameters from child contract
        DeploymentParams memory params = getDeploymentParams();

        // Start deployment
        vm.startBroadcast(deployerPrivateKey);

        // Deploy the oracle
        TWAPPriceSentinel sentinel = deploy(params);

        vm.stopBroadcast();

        console.log("\n=== Deployment Complete ===");
        console.log("TWAPPriceSentinel address:", address(sentinel));

        console.log("\n=== Next Steps ===");
        console.log("1. Wait at least 30 seconds");
        console.log("2. Call updatePrice() to add more observations:");
        console.log(
            "   cast send", address(sentinel), "\"updatePrice()\" --rpc-url $RPC_URL --private-key $PRIVATE_KEY"
        );
        console.log("3. See script/README.md for full initialization and testing instructions");
    }

    /// @notice Script name constant - must be defined by child contracts
    function name() external view virtual returns (string memory);
}
