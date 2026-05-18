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
│   └── FeeCollector.t.sol     # Forge tests
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
| `swapExactKASForTokens(amountOutMin, path, to, deadline) payable` | KAS → Token |
| `getAmountsOut(amountIn, path, isDiscountEligible)` | Quote (fee-adjusted) |
| `calculateFee(amount)` | Preview fee and net amount |

### Admin (owner only)

| Function | Description |
|----------|-------------|
| `setFeeRate(feeRate)` | Update fee rate (max 1000 = 10%) |
| `setOwner(newOwner)` | Transfer ownership |
| `setWithdrawer(newWithdrawer)` | Change withdrawer address |

### Withdraw (owner or withdrawer)

| Function | Description |
|----------|-------------|
| `withdraw(token, to, amount)` | Withdraw specific ERC-20 amount |
| `withdrawAll(token, to)` | Withdraw all accumulated ERC-20 fees |
| `withdrawNative(to, amount)` | Withdraw native KAS fees |
