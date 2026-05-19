# zealous-swap — FeeCollector

A Foundry project that wraps the [Zealous Swap](https://zealous-swap.gitbook.io/zealous-swap/) Router and charges a configurable fee on every swap.

---

## Overview

```
User
  │  approve(FeeCollector, amountIn)
  │  swap(amountIn, ...)
  ▼
FeeCollector          ← deducts fee, keeps it in contract
  │  approve(Router, netAmountIn)
  ▼
Zealous Swap Router   → tokenOut → user
```

- Default fee: **0.75%** (`75 / 10000`)
- Fee is taken from `amountIn` (or `msg.value` for KAS swaps) before forwarding to the Router
- Owner can update `feeRate` (max 10%) and `withdrawer` at any time

---

## Project Structure

```
zealous-swap/
├── src/
│   └── FeeCollector.sol       # Main contract
├── test/
│   └── FeeCollector.t.sol     # Forge test suite (33 tests)
├── script/
│   └── DeployFeeCollector.s.sol
└── docs/
    ├── frontend-integration.md
    └── deployment.md
```

---

## Docs

- [Frontend Integration Guide](./docs/frontend-integration.md) — ABI, swap examples (viem), slippage, events
- [Deployment & Operations Guide](./docs/deployment.md) — deploy, admin operations, fee withdrawal

---

## Development

**Prerequisites:** [Foundry](https://book.getfoundry.sh/getting-started/installation)

```bash
# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with verbosity
forge test -vv

# Gas snapshot
forge snapshot
```

---

## Deploy

```bash
OWNER=0x... \
WITHDRAWER=0x... \
FEE_PERCENT=75 \
ROUTER=0x... \
  forge script script/DeployFeeCollector.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

`FEE_PERCENT` is in basis points: `75` = 0.75%, `100` = 1%, `1000` = 10% (max).

---

## Contract Interface

### Swap (callable by anyone)

| Function | Description |
|----------|-------------|
| `swapExactTokensForTokens(amountIn, amountOutMin, path, to, deadline)` | Token → Token |
| `swapExactTokensForKAS(amountIn, amountOutMin, path, to, deadline)` | Token → KAS |
| `swapExactKASForTokens(amountOutMin, path, to, deadline) payable` | KAS → Token. `path[0]` must be WKAS. |
| `getAmountsOut(amountIn, path, isDiscountEligible)` | Quote (fee-adjusted) |
| `calculateFee(amount)` | Preview fee and net amount |

### Admin (owner only)

| Function | Description |
|----------|-------------|
| `transferOwnership(newOwner)` | Propose new owner (two-step). |
| `acceptOwnership()` | New owner accepts transfer. |
| `setFeeRate(feeRate)` | Update fee rate (max 1000 = 10%). |
| `setWithdrawer(newWithdrawer)` | Change withdrawer address. |

### Withdraw (owner or withdrawer)

| Function | Description |
|----------|-------------|
| `withdraw(token, to, amount)` | Withdraw specific ERC-20 amount. |
| `withdrawAll(token, to)` | Withdraw all accumulated ERC-20 fees. |
| `withdrawNative(to, amount)` | Withdraw specific native KAS amount. |
| `withdrawAllNative(to)` | Withdraw all accumulated native KAS fees. |

## Errors

| Error | Cause |
|---|---|
| `InvalidPath` | `path.length < 2` or `path[0] != WKAS` for KAS swaps |
| `TransferFailed` | ERC-20 transfer/approve failed |
| `InsufficientBalance` | Withdrawal amount exceeds contract balance |
| `FeeRateTooHigh` | Attempted fee rate > 1000 bps |
| `ZeroAddress` | Zero address passed to a setter |
| `NotOwner` / `NotWithdrawer` | Caller not authorized |

## Events

| Event | When |
|---|---|
| `FeeCollected(address indexed token, address indexed from, uint256 feeAmount)` | Fee charged on swap |
| `Withdrawn(address indexed token, address indexed to, uint256 amount)` | ERC-20 fee withdrawal |
| `NativeWithdrawn(address indexed to, uint256 amount)` | Native KAS fee withdrawal |
| `OwnerSet(address indexed prev, address indexed next)` | Ownership transferred |
| `OwnershipTransferProposed(address indexed current, address indexed proposed)` | Ownership transfer proposed |
| `WithdrawerSet(address indexed prev, address indexed next)` | Withdrawer changed |
| `FeeRateSet(uint256 prev, uint256 next)` | Fee rate changed |
