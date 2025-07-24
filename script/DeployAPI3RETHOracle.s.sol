// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {API3Oracle} from "../src/adapter/api3/API3Oracle.sol";

/// @title DeployAPI3RETHOracle
/// @notice Deployment script for API3Oracle with rETH/ETH price feed
/// @dev Run with: forge script script/DeployAPI3RETHOracle.s.sol:DeployAPI3RETHOracle --rpc-url $RPC_URL --broadcast
contract DeployAPI3RETHOracle is Script {
    // Unichain addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    // rETH addresses (production)
    address constant RETH = 0x94Cac393f3444cEf63a651FfC18497E7e8bd036a; // rETH on Unichain
    address constant RETH_PRICE_FEED = 0x3Ce8154d55426e8c71F1F0EffDDc6183a92bE45f; // API3 rETH/ETH feed
    
    // Oracle parameters
    uint256 constant MAX_STALENESS = 24 hours + 10 seconds; // Maximum allowed age for price data (24h heartbeat + buffer)

    function run() public {
        vm.startBroadcast();
        
        // Deploy API3Oracle
        API3Oracle oracle = new API3Oracle(
            "rETH",         // base symbol
            RETH,           // base (rETH)
            "WETH",         // quote symbol
            WETH,           // quote (WETH)
            RETH_PRICE_FEED, // API3 Api3ReaderProxyV1 proxy
            MAX_STALENESS   // max staleness
        );
        
        vm.stopBroadcast();
        
        console2.log("API3Oracle deployed at:", address(oracle));
    }
}