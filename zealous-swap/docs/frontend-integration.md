# FeeCollector — Frontend Integration Guide

FeeCollector wraps the Zealous Swap Router and charges a fee on every swap.  
The frontend integration is nearly identical to calling the Router directly — the only difference is that users approve and call **FeeCollector** instead of the Router.

---

## Contract Info

| Property | Value |
|----------|-------|
| Default fee rate | 0.75% (`feeRate / 10000`) |
| Fee source (token swaps) | Deducted from `amountIn` before forwarding to the Router |
| Fee source (KAS swaps) | Deducted from `msg.value` |

---

## Flow

```
User wallet
  │
  │  1. approve(FeeCollector, amountIn)   ← approve FeeCollector only
  │  2. swap(amountIn, ...)
  ▼
FeeCollector
  │  keeps fee
  │  approve(Router, netAmountIn)
  ▼
Zealous Swap Router  →  tokenOut → user
```

> ⚠️ Users do **not** need to approve the Router — only FeeCollector.

---

## ABI

```ts
export const FEE_COLLECTOR_ABI = [
  // ─── Read ──────────────────────────────────────────────────────────────────
  {
    name: "feeRate",
    type: "function",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
  {
    name: "calculateFee",
    type: "function",
    stateMutability: "view",
    inputs: [{ name: "amount", type: "uint256" }],
    outputs: [
      { name: "fee", type: "uint256" },
      { name: "netAmount", type: "uint256" },
    ],
  },
  {
    name: "getAmountsOut",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "path", type: "address[]" },
      { name: "isDiscountEligible", type: "bool" },
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }],
  },
  // ─── Token → Token ─────────────────────────────────────────────────────────
  {
    name: "swapExactTokensForTokens",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "path", type: "address[]" },
      { name: "to", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }],
  },
  // ─── Token → KAS ───────────────────────────────────────────────────────────
  {
    name: "swapExactTokensForKAS",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "amountIn", type: "uint256" },
      { name: "amountOutMin", type: "uint256" },
      { name: "path", type: "address[]" },
      { name: "to", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }],
  },
  // ─── KAS → Token ───────────────────────────────────────────────────────────
  {
    name: "swapExactKASForTokens",
    type: "function",
    stateMutability: "payable",
    inputs: [
      { name: "amountOutMin", type: "uint256" },
      { name: "path", type: "address[]" },
      { name: "to", type: "address" },
      { name: "deadline", type: "uint256" },
    ],
    outputs: [{ name: "amounts", type: "uint256[]" }],
  },
] as const;

export const ERC20_ABI = [
  {
    name: "approve",
    type: "function",
    stateMutability: "nonpayable",
    inputs: [
      { name: "spender", type: "address" },
      { name: "amount", type: "uint256" },
    ],
    outputs: [{ name: "", type: "bool" }],
  },
  {
    name: "allowance",
    type: "function",
    stateMutability: "view",
    inputs: [
      { name: "owner", type: "address" },
      { name: "spender", type: "address" },
    ],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;
```

---

## Examples

### 1. Get a Quote (with fee)

`getAmountsOut` on FeeCollector already deducts the fee before forwarding to the Router, so the returned amounts already reflect the true output.

```ts
import { createPublicClient, http, parseUnits, formatUnits } from "viem";

const publicClient = createPublicClient({ transport: http(RPC_URL) });

const amountIn = parseUnits("100", 18); // 100 USDT
const path = [USDT_ADDRESS, WKAS_ADDRESS] as const;

const amounts = await publicClient.readContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "getAmountsOut",
  args: [amountIn, path, false],
});
const expectedOut = amounts[amounts.length - 1];
console.log("Expected KAS out:", formatUnits(expectedOut, 18));

// Show fee breakdown to the user
const [fee, netAmountIn] = await publicClient.readContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "calculateFee",
  args: [amountIn],
});
console.log("Fee:", formatUnits(fee, 18), "USDT");
console.log("Net amount into router:", formatUnits(netAmountIn, 18), "USDT");
```

---

### 2. Token → Token Swap

```ts
import {
  createWalletClient,
  createPublicClient,
  custom,
  parseUnits,
} from "viem";

const publicClient = createPublicClient({ transport: http(RPC_URL) });
const walletClient = createWalletClient({ transport: custom(window.ethereum) });
const [account] = await walletClient.getAddresses();

const amountIn = parseUnits("100", 6); // 100 USDT (6 decimals)
const path = [USDT_ADDRESS, WBTC_ADDRESS] as const;
const deadline = BigInt(Math.floor(Date.now() / 1000) + 60 * 20); // 20 min

// 1. Get quote and apply 0.5% slippage
const amounts = await publicClient.readContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "getAmountsOut",
  args: [amountIn, path, false],
});
const amountOutMin = (amounts[amounts.length - 1] * 995n) / 1000n;

// 2. Approve FeeCollector (only if allowance is insufficient)
const allowance = await publicClient.readContract({
  address: USDT_ADDRESS,
  abi: ERC20_ABI,
  functionName: "allowance",
  args: [account, FEE_COLLECTOR_ADDRESS],
});
if (allowance < amountIn) {
  const approveTx = await walletClient.writeContract({
    address: USDT_ADDRESS,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [FEE_COLLECTOR_ADDRESS, amountIn],
    account,
  });
  await publicClient.waitForTransactionReceipt({ hash: approveTx });
}

// 3. Swap
const swapTx = await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "swapExactTokensForTokens",
  args: [amountIn, amountOutMin, path, account, deadline],
  account,
});
await publicClient.waitForTransactionReceipt({ hash: swapTx });
console.log("Swap confirmed:", swapTx);
```

---

### 3. Token → KAS Swap

```ts
const amountIn = parseUnits("50", 18);
const path = [USDT_ADDRESS, WKAS_ADDRESS] as const; // last token must be WKAS

const amounts = await publicClient.readContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "getAmountsOut",
  args: [amountIn, path, false],
});
const amountOutMin = (amounts[amounts.length - 1] * 995n) / 1000n;

// Approve
await publicClient.waitForTransactionReceipt({
  hash: await walletClient.writeContract({
    address: USDT_ADDRESS,
    abi: ERC20_ABI,
    functionName: "approve",
    args: [FEE_COLLECTOR_ADDRESS, amountIn],
    account,
  }),
});

// Swap
const tx = await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "swapExactTokensForKAS",
  args: [amountIn, amountOutMin, path, account, deadline],
  account,
});
await publicClient.waitForTransactionReceipt({ hash: tx });
```

---

### 4. KAS → Token Swap

No `approve` needed. The fee is deducted from `value`.

```ts
const kasIn = parseEther("10"); // 10 KAS
const path = [WKAS_ADDRESS, USDT_ADDRESS] as const; // first token must be WKAS

const amounts = await publicClient.readContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "getAmountsOut",
  args: [kasIn, path, false],
});
const amountOutMin = (amounts[amounts.length - 1] * 995n) / 1000n;

const tx = await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  functionName: "swapExactKASForTokens",
  args: [amountOutMin, path, account, deadline],
  value: kasIn, // fee is deducted from this value inside the contract
  account,
});
await publicClient.waitForTransactionReceipt({ hash: tx });
```

---

### 5. Display Fee to Users

```ts
async function getSwapPreview(amountIn: bigint, path: readonly `0x${string}`[]) {
  const [fee, netAmountIn] = await publicClient.readContract({
    address: FEE_COLLECTOR_ADDRESS,
    abi: FEE_COLLECTOR_ABI,
    functionName: "calculateFee",
    args: [amountIn],
  });

  const amounts = await publicClient.readContract({
    address: FEE_COLLECTOR_ADDRESS,
    abi: FEE_COLLECTOR_ABI,
    functionName: "getAmountsOut",
    args: [amountIn, path, false],
  });

  return {
    grossAmountIn: amountIn,
    fee,
    netAmountIn,
    expectedOut: amounts[amounts.length - 1],
  };
}

const preview = await getSwapPreview(parseUnits("100", 18), [USDT_ADDRESS, WKAS_ADDRESS]);
console.log("Fee:", formatUnits(preview.fee, 18), "USDT");
console.log("Expected out:", formatEther(preview.expectedOut), "KAS");
```

---

### 6. Listen for Fee Events

```ts
// Watch FeeCollected events in real time
const unwatch = publicClient.watchContractEvent({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  eventName: "FeeCollected",
  onLogs: (logs) => {
    for (const log of logs) {
      console.log("Fee collected:", log.args);
    }
  },
});

// Query historical events
const logs = await publicClient.getContractEvents({
  address: FEE_COLLECTOR_ADDRESS,
  abi: FEE_COLLECTOR_ABI,
  eventName: "FeeCollected",
  fromBlock: 0n,
});
```

---

## Slippage Note

Since `getAmountsOut` on FeeCollector already accounts for the fee internally, simply apply your slippage tolerance directly to the returned amount:

```ts
// ✅ Correct — use FeeCollector's getAmountsOut
const amounts = await fc.getAmountsOut(amountIn, path, false);
const amountOutMin = (amounts[amounts.length - 1] * 995n) / 1000n;

// ❌ Wrong — Router's getAmountsOut does not deduct the fee
const routerAmounts = await router.getAmountsOut(amountIn, path, false);
```

---

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `TransferFailed` | Insufficient allowance | Call `approve(FeeCollector, amountIn)` first |
| `InvalidPath` | `path.length < 2` | Ensure path has at least two token addresses |
| Swap reverted | `amountOutMin` too high (slippage) | Re-fetch quote and lower `amountOutMin` |

---

> For deployment, admin operations, and fee withdrawal, see [deployment.md](./deployment.md).
