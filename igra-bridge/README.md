# igra-bridge Fee Collector

A Foundry-based smart contract that wraps the [Igra KasExitBridge](https://igra-labs.gitbook.io/igralabs-docs/for-developers/kasexitbridge-developer-guide) `requestExit` function and charges a configurable fee on every iKAS → KAS exit.

## Overview

```
User calls bridgeToL1(kasPayoutAddress) with iKAS (wei)
         │
         ▼
  FeeCollector (this contract)
  ┌──────────────────────────────────────────────────────────┐
  │  ourFee   = msg.value × feeRate / 10000                  │
  │  netWei   = msg.value − ourFee                           │
  │  tentative = netWei / 1e10  (sompi)                      │
  │  bridgeFee = bridge.quoteFee(...)  (currently 0)         │
  │  actualUnlock = tentative − bridgeFee                    │
  │  bridgeWei    = tentative × 1e10  (exact, no overflow)   │
  └──────────────┬───────────────────────────────────────────┘
                 │ bridgeWei + kasPayoutAddress + actualUnlock
                 ▼
       Igra KasExitBridge (requestExit)
                 │
                 ▼
     actualUnlock KAS released on Kaspa L1
```

**Default fee rate:** 0.75% (75 basis points)  
**Minimum exit:** 1,000 KAS (`1e11` sompi)  
**Bridge contract (Igra Mainnet, chain 38833):** `0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0`

### Unit Conversion

| Unit | Value |
|------|-------|
| 1 KAS | 1e8 sompi = 1e18 wei |
| SOMPI_SCALE | 1e10 (sompi × 1e10 = wei) |

## Project Structure

```
igra-bridge/
├── src/
│   └── FeeCollector.sol    # Main contract
├── test/
│   └── FeeCollector.t.sol  # Forge test suite (37 tests)
├── script/
│   └── DeployFeeCollector.s.sol
├── lib/
│   └── forge-std/          # git submodule
└── foundry.toml
```

## Development

```bash
# Install dependencies (from repo root)
git submodule update --init --recursive

# Build
cd igra-bridge
forge build

# Test
forge test -vvv

# Format
forge fmt
```

## Deploy

### Using forge script

```bash
OWNER=0x... \
WITHDRAWER=0x... \
FEE_PERCENT=75 \
BRIDGE=0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0 \
  forge script script/DeployFeeCollector.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --gas-price 1100000000000
```

> **Note:** Igra minimum gas price is 1,000 gwei. Use `--gas-price 1100000000000` (1,100 gwei) for reliable inclusion.

### Using forge create

```bash
forge create src/FeeCollector.sol:FeeCollector \
  --rpc-url $RPC_URL \
  --constructor-args \
    $OWNER \
    $WITHDRAWER \
    75 \
    0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0 \
  --gas-price 1100000000000
```

## Contract Interface

### Core

| Function | Description |
|---|---|
| `bridgeToL1(string kasPayoutAddress) payable` | Bridge iKAS to Kaspa L1. Our fee deducted from `msg.value`; remainder forwarded to bridge. |
| `calculateFee(uint256 amount) view` | Returns `(fee, netAmount)` for a given gross wei value. |

### Admin (owner only)

| Function | Description |
|---|---|
| `transferOwnership(address)` | Propose new owner (two-step). |
| `acceptOwnership()` | New owner accepts transfer. |
| `setWithdrawer(address)` | Change fee withdrawer. |
| `setFeeRate(uint256)` | Set fee in basis points (max 1000 = 10%). |

### Withdraw (owner or withdrawer)

| Function | Description |
|---|---|
| `withdrawNative(address payable to, uint256 amount)` | Withdraw specific amount of native fees. |
| `withdrawAllNative(address payable to)` | Withdraw all accumulated native fees. |

## Fee & Amount Mechanics

```
ourFee        = grossWei × feeRate / 10000
netWei        = grossWei − ourFee
tentative     = netWei / 1e10              (sompi, truncated)
bridgeFee     = bridge.quoteFee(...)       (currently 0)
actualUnlock  = tentative − bridgeFee      (user receives this on L1)
bridgeWei     = tentative × 1e10          (forwarded to bridge)
dust          = netWei − bridgeWei         (truncation remainder, kept as fee)
```

Example: bridging 5,000 KAS at default 0.75%, bridge fee = 0
- Our fee: 37.5 KAS
- Net: 4,962.5 KAS → 496,250,000,000 sompi
- User receives on L1: 4,962.5 KAS

## Kaspa Address Requirements

- Must start with `kaspa:`
- Max 90 bytes total
- Main-net addresses are exactly 69 characters
- No checksum validation — double-check your address before bridging

## Errors

| Error | Cause |
|---|---|
| `InsufficientValue` | `msg.value == 0` |
| `BelowMinimum` | Net unlock < 1,000 KAS |
| `ValueTooLarge` | `msg.value` overflows uint64 sompi conversion |
| `BridgeFeeTooHigh` | Bridge protocol fee ≥ tentative unlock |
| `BridgeQuoteFailed` | `quoteFee` external call reverted |
| `InvalidAddress` | Kaspa address malformed or out of length range |
| `FeeRateTooHigh` | Attempted fee rate > 1000 bps |
| `ZeroAddress` | Zero address passed to a setter |
| `NotOwner` / `NotWithdrawer` | Caller not authorized |

## Events

| Event | When |
|---|---|
| `FeeCollected(address indexed from, uint256 feeAmount)` | Fee charged on exit |
| `NativeWithdrawn(address indexed to, uint256 amount)` | Fee withdrawal |
| `OwnerSet(address indexed prev, address indexed next)` | Ownership transferred |
| `OwnershipTransferProposed(address indexed current, address indexed proposed)` | Ownership transfer proposed |
| `WithdrawerSet(address indexed prev, address indexed next)` | Withdrawer changed |
| `FeeRateSet(uint256 prev, uint256 next)` | Fee rate changed |
