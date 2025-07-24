# API3 Oracle Deployment Guide

This guide explains how to deploy the API3Oracle for rETH exchange rate on Unichain.

## Deployment

### 1. Deploy the Oracle

```bash
forge script script/DeployAPI3RETHOracle.s.sol:DeployAPI3RETHOracle --rpc-url $RPC_URL --account $ACCOUNT_NAME --broadcast -vvv
```

### 2. Note the Deployed Address

The script will output the deployed API3Oracle address. Save this for integration with Euler.

## Testing the Oracle

### 1. Get a Price Quote
```bash
# Get price for 1 rETH in WETH
cast call $CONTRACT_ADDRESS "getQuote(uint256,address,address)" 1000000000000000000 0x94Cac393f3444cEf63a651FfC18497E7e8bd036a 0x4200000000000000000000000000000000000006 --rpc-url $RPC_URL
```

### 2. Get Reverse Quote
```bash
# Get price for 1 WETH in rETH
cast call $CONTRACT_ADDRESS "getQuote(uint256,address,address)" 1000000000000000000 0x4200000000000000000000000000000000000006 0x94Cac393f3444cEf63a651FfC18497E7e8bd036a --rpc-url $RPC_URL
```

### 3. Check Oracle Configuration
```bash
# Get oracle name
cast call $CONTRACT_ADDRESS "name()" --rpc-url $RPC_URL | xargs cast abi-decode "x()(string)"

# Get base token
cast call $CONTRACT_ADDRESS "base()" --rpc-url $RPC_URL

# Get quote token  
cast call $CONTRACT_ADDRESS "quote()" --rpc-url $RPC_URL

# Get price feed address
cast call $CONTRACT_ADDRESS "feed()" --rpc-url $RPC_URL

# Get max staleness
echo "$(cast call $CONTRACT_ADDRESS "maxStaleness()" --rpc-url $RPC_URL | xargs cast to-dec) seconds"
```

## Important Notes

- **Price Feed**: Uses API3 Api3ReaderProxyV1 for rETH/ETH exchange rate with 0.25% deviation threshold
- **Max Staleness**: 24 hours + 10 seconds (allows for small delays in heartbeat updates)
- **No Initialization Required**: Oracle is ready to use immediately after deployment
- **Stable Exchange Rate**: rETH exchange rate only increases over time under normal conditions

## Contract Addresses

### Unichain
- WETH: `0x4200000000000000000000000000000000000006`
- rETH: `0x94Cac393f3444cEf63a651FfC18497E7e8bd036a`
- rETH/ETH Price Feed: `0x3Ce8154d55426e8c71F1F0EffDDc6183a92bE45f` (API3)