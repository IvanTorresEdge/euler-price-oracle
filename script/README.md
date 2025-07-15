# TWAPPriceSentinel Deployment Guide

This guide explains how to deploy and initialize the TWAPPriceSentinel oracle wrapper for rETH.

## Deployment

### 1. Deploy the Oracle

```bash
forge script script/DeployTWAPSentinel_rETH.s.sol:DeployTWAPSentinel_rETH --rpc-url $RPC_URL --broadcast -vvv
```

### 2. Note the Deployed Address

The script will output the deployed TWAPPriceSentinel address. Save this for the next steps.

## Post-Deployment Initialization

The TWAPPriceSentinel requires at least 2 price observations to start calculating TWAP. The first observation is automatically added during deployment.

### Adding Additional Observations

1. **Wait at least 30 seconds** after deployment (minimum update interval)

2. Call `updatePrice()` to add a new observation:
   ```bash
   cast send <SENTINEL_ADDRESS> "updatePrice()" --rpc-url $RPC_URL --private-key $PRIVATE_KEY
   ```

3. Repeat step 2 to add more observations (wait 30+ seconds between each call)

## Testing the Oracle

### 1. Check Observation Count
```bash
cast call <SENTINEL_ADDRESS> "getObservationCount()" --rpc-url $RPC_URL
```
- Should return at least 2 for TWAP to work

### 2. Get a Price Quote
```bash
# Get price for 1 rETH in WETH
cast call <SENTINEL_ADDRESS> "getQuote(uint256,address,address)" 1000000000000000000 0x94Cac393f3444cEf63a651FfC18497E7e8bd036a 0x4200000000000000000000000000000000000006 --rpc-url $RPC_URL
```

### 3. View Individual Observations
```bash
# Get observation at index 0
cast call <SENTINEL_ADDRESS> "getObservation(uint256)" 0 --rpc-url $RPC_URL
```
Returns: (price, timestamp)

### 4. Calculate Current EWTWAP
```bash
cast call <SENTINEL_ADDRESS> "calculateEWTWAP()" --rpc-url $RPC_URL
```
Note: Requires at least 2 observations

## Important Notes

- **Update Frequency**: The underlying price feed must update at least every 30 minutes for proper TWAP calculation
- **Spam Protection**: Updates can only occur every 30 seconds minimum
- **Price Bounds**: The oracle enforces maximum price movements:
  - Max drop: 1.5% (150 bps)
  - Max rise: 3% (300 bps)
- **Observation Buffer**: Maintains up to 60 observations (30 minutes of history at minimum update rate)

## Troubleshooting

### "TWAPPriceSentinel_InsufficientObservations"
- The oracle needs at least 2 observations
- Call `updatePrice()` after waiting 30+ seconds

### "TWAPPriceSentinel_UpdateTooFrequent"
- Wait at least 30 seconds between update calls

### "TWAPPriceSentinel_PriceDeviationExceeded"
- The price moved more than allowed thresholds
- This is a protection mechanism against price manipulation

## Contract Addresses

### Unichain
- WETH: `0x4200000000000000000000000000000000000006`
- rETH: `0x94Cac393f3444cEf63a651FfC18497E7e8bd036a`
- rETH/ETH Price Feed: `0x3Ce8154d55426e8c71F1F0EffDDc6183a92bE45f` (API3)