// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTWAPPriceSentinelDeployer} from "./base/BaseTWAPPriceSentinelDeployer.s.sol";

/// @title DeployTWAPSentinel_rETH
/// @notice Deployment script for TWAPPriceSentinel with rETH
/// @dev Run with: forge script script/DeployTWAPSentinel_rETH.s.sol:DeployTWAPSentinel_rETH --rpc-url $RPC_URL --broadcast
contract DeployTWAPSentinel_rETH is BaseTWAPPriceSentinelDeployer {
    // Script name for output file
    string public constant override name = "DeployTWAPSentinel_rETH";

    // Unichain addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // rETH addresses (production)
    address constant RETH = 0x94Cac393f3444cEf63a651FfC18497E7e8bd036a; // rETH on Unichain
    address constant RETH_PRICE_FEED = 0x3Ce8154d55426e8c71F1F0EffDDc6183a92bE45f; // API3 rETH/ETH feed

    // TWAPPriceSentinel parameters
    uint256 constant MAX_DROP_BPS = 150; // 1.5% max drop (tighter for liquidation protection)
    uint256 constant MAX_RISE_BPS = 300; // 3% max rise
    uint256 constant LAMBDA = 0.05e18; // Exponential decay factor (5% scaled by 1e18)

    /// @notice Get deployment parameters for rETH
    function getDeploymentParams() internal pure override returns (DeploymentParams memory) {
        require(RETH_PRICE_FEED != address(0), "rETH price feed not yet available");

        return DeploymentParams({
            priceFeed: RETH_PRICE_FEED,
            base: RETH,
            quote: WETH,
            maxDropBps: MAX_DROP_BPS,
            maxRiseBps: MAX_RISE_BPS,
            lambda: LAMBDA,
            description: "rETH/WETH TWAPPriceSentinel (Production)"
        });
    }
}
