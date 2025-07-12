// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {Script, console} from "forge-std/Script.sol";
import {TWAPPriceSentinel} from "../src/adapter/TWAPPriceSentinel.sol";

/// @title DeployTWAPPriceSentinel
/// @notice Deployment script for TWAPPriceSentinel oracle with TWAP protection
/// @dev Deploys TWAPPriceSentinel with exponentially weighted TWAP and asymmetric thresholds
contract DeployTWAPPriceSentinel is Script {
    // Unichain addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;
    
    // For testing with rsETH (replace with rETH for production)
    address constant RETH = 0xc3eACf0612346366Db554C991D7858716db09f58; // rsETH for testing
    address constant REDSTONE_FEED = 0x85C4F855Bc0609D2584405819EdAEa3aDAbfE97D; // rsETH/ETH feed
    
    // TWAPPriceSentinel parameters
    uint256 constant MAX_DROP_BPS = 150;    // 1.5% max drop (tighter for liquidation protection)
    uint256 constant MAX_RISE_BPS = 300;    // 3% max rise
    uint256 constant LAMBDA = 0.05e18;      // Exponential decay factor (5% scaled by 1e18)

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        vm.startBroadcast(deployerPrivateKey);

        // Deploy TWAPPriceSentinel wrapping the Redstone feed
        TWAPPriceSentinel sentinel = new TWAPPriceSentinel(
            REDSTONE_FEED,  // Chainlink-compatible price feed
            RETH,           // base (rETH/rsETH)
            WETH,           // quote (WETH)
            MAX_DROP_BPS,   // max drop threshold
            MAX_RISE_BPS,   // max rise threshold
            LAMBDA          // exponential decay factor
        );

        vm.stopBroadcast();

        // Log deployed address
        console.log("TWAPPriceSentinel deployed at:", address(sentinel));
        
        // Test the oracle
        try sentinel.getQuote(1e18, RETH, WETH) returns (uint256 price) {
            console.log("Current rETH/WETH price:", price);
        } catch {
            console.log("Price query failed - may need price history first");
        }
        
        // Get current observation count
        uint256 obsCount = sentinel.getObservationCount();
        console.log("Current observation count:", obsCount);
        
        // Calculate EWTWAP if possible
        if (obsCount > 0) {
            uint256 ewtwap = sentinel.calculateEWTWAP();
            console.log("Current EWTWAP:", ewtwap);
        }
    }

    // Function to get deployment parameters for production rETH
    function getProductionParameters() external pure returns (
        address rETH,
        address wETH,
        address priceFeed,
        uint256 maxDropBps,
        uint256 maxRiseBps,
        uint256 lambda
    ) {
        // Production parameters for actual rETH on Unichain
        rETH = address(0x94Cac393f3444cEf63a651FfC18497E7e8bd036a); // rETH on Unichain
        wETH = address(0x4200000000000000000000000000000000000006);  // WETH on Unichain
        priceFeed = address(0); // TODO: Add rETH/ETH Redstone feed when available
        maxDropBps = 150;       // 1.5% max drop
        maxRiseBps = 300;       // 3% max rise
        lambda = 0.05e18;       // 5% exponential decay
    }
}