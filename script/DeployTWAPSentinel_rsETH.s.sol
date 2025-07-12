// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.0;

import {BaseTWAPPriceSentinelDeployer} from "./base/BaseTWAPPriceSentinelDeployer.s.sol";

/// @title DeployTWAPSentinel_rsETH
/// @notice Deployment script for TWAPPriceSentinel with rsETH
/// @dev Run with: forge script script/DeployTWAPSentinel_rsETH.s.sol:DeployTWAPSentinel_rsETH --rpc-url $RPC_URL --broadcast
contract DeployTWAPSentinel_rsETH is BaseTWAPPriceSentinelDeployer {
    // Script name for output file
    string public constant override name = "DeployTWAPSentinel_rsETH";

    // Unichain addresses
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // rsETH addresses
    address constant RSETH = 0xc3eACf0612346366Db554C991D7858716db09f58; // rsETH token
    address constant RSETH_EULER_ADAPTER = 0xe6D9C66C0416C1c88Ca5F777D81a7F424D4Fa87b; // rsETH Adapter (Euler) - for reference
    address constant RSETH_PRICE_FEED = 0x85C4F855Bc0609D2584405819EdAEa3aDAbfE97D; // rsETH/ETH AggregatorV3

    // TWAPPriceSentinel parameters
    uint256 constant MAX_DROP_BPS = 150; // 1.5% max drop (tighter for liquidation protection)
    uint256 constant MAX_RISE_BPS = 300; // 3% max rise
    uint256 constant LAMBDA = 0.05e18; // Exponential decay factor (5% scaled by 1e18)

    /// @notice Get deployment parameters for rsETH
    function getDeploymentParams() internal pure override returns (DeploymentParams memory) {
        return DeploymentParams({
            priceFeed: RSETH_PRICE_FEED,
            base: RSETH,
            quote: WETH,
            maxDropBps: MAX_DROP_BPS,
            maxRiseBps: MAX_RISE_BPS,
            lambda: LAMBDA,
            description: "rsETH/WETH TWAPPriceSentinel (Testing)"
        });
    }
}
