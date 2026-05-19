# kasplex-bridge Fee Collector

A Foundry-based smart contract that wraps the [Kasplex Bridge](https://docs.kasplex.org/bridge/overview) `lockForBridge` function and charges a configurable fee on every L2 → L1 bridge transaction.

## Overview

```
User calls bridgeToL1(l1Recipient) with KAS
         │
         ▼
  FeeCollector (this contract)
  ┌─────────────────────────────────────┐
  │  fee = msg.value × feeRate / 10000  │
  │  net = msg.value − fee              │
  │  fee stays in FeeCollector          │
  └──────────────┬──────────────────────┘
                 │ net KAS + encoded payload
                 ▼
       Kasplex Bridge (lockForBridge)
                 │
                 ▼
         L1 Kaspa address
```

**Default fee rate:** 0.75% (75 basis points)  
**Bridge contract (mainnet):** `0x34606e6d01280f49791628b311cf33a808d1f7c6`

## Project Structure

```
kasplex-bridge/
├── src/
│   └── FeeCollector.sol    # Main contract
├── test/
│   └── FeeCollector.t.sol  # Forge test suite (34 tests)
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
cd kasplex-bridge
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
BRIDGE=0x34606e6d01280f49791628b311cf33a808d1f7c6 \
  forge script script/DeployFeeCollector.s.sol \
  --rpc-url $RPC_URL \
  --broadcast \
  --verify
```

### Using forge create

```bash
forge create src/FeeCollector.sol:FeeCollector \
  --rpc-url $RPC_URL \
  --constructor-args \
    $OWNER \
    $WITHDRAWER \
    75 \
    0x34606e6d01280f49791628b311cf33a808d1f7c6 \
  --broadcast
```

## Contract Interface

### Core

| Function | Description |
|---|---|
| `bridgeToL1(string l1Recipient) payable` | Bridge KAS to L1. Fee deducted from `msg.value`. |
| `calculateFee(uint256 amount) view` | Returns `(fee, netAmount)` for a given gross value. |

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
| `withdrawNative(address payable to, uint256 amount)` | Withdraw specific amount of KAS. |
| `withdrawAllNative(address payable to)` | Withdraw all accumulated KAS fees. |

## Fee Calculation

```
fee      = grossAmount × feeRate / 10000
netValue = grossAmount − fee
```

Example: bridging 100 KAS at default 0.75%
- Fee: 0.75 KAS (stays in FeeCollector)
- Forwarded to bridge: 99.25 KAS

## Kaspa Address Requirements

- Must start with `kaspa:`
- Max 90 bytes total
- Main-net addresses are exactly 69 characters
- No checksum validation — double-check your address before bridging

## Payload Encoding

The Kasplex Bridge expects the L1 address encoded as a UTF-8 hex string.  
This contract handles encoding internally — pass the plain Kaspa address:

```
"kaspa:qypr0qj7..." → "6b61737061 3a 7179 7072..."
```

## Errors

| Error | Cause |
|---|---|
| `InsufficientValue` | `msg.value == 0` |
| `InvalidAddress` | Kaspa address malformed or out of length range |
| `BridgeFailed` | Bridge `lockForBridge` returned false |
| `FeeRateTooHigh` | Attempted fee rate > 1000 bps |
| `ZeroAddress` | Zero address passed to a setter |
| `NotOwner` / `NotWithdrawer` | Caller not authorized |

## Events

| Event | When |
|---|---|
| `FeeCollected(address indexed from, uint256 feeAmount)` | Fee charged on bridge |
| `NativeWithdrawn(address indexed to, uint256 amount)` | Fee withdrawal |
| `OwnerSet(address indexed prev, address indexed next)` | Ownership transferred |
| `OwnershipTransferProposed(address indexed current, address indexed proposed)` | Ownership transfer proposed |
| `WithdrawerSet(address indexed prev, address indexed next)` | Withdrawer changed |
| `FeeRateSet(uint256 prev, uint256 next)` | Fee rate changed |
