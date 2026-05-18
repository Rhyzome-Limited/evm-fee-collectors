# FeeCollector — Deployment & Operations Guide

---

## Deployment

### Constructor Arguments

```solidity
constructor(
    address _owner,       // admin: can change feeRate / withdrawer
    address _withdrawer,  // can call withdraw functions
    uint256 _feeRate,     // stored as basis points internally (feeRate / 10000)
                          // pass percentage × 100: 0.75% → 75, 1% → 100, 10% → 1000 (max)
    address _router       // Zealous Swap Router address
)
```

### Deploy with Forge

```bash
forge create src/FeeCollector.sol:FeeCollector \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --constructor-args \
    <OWNER_ADDRESS> \
    <WITHDRAWER_ADDRESS> \
    75 \             # percentage × 100: 0.75% → 75
    <ZEALOUS_ROUTER_ADDRESS>
```

### Deploy with a Forge Script

Create `script/DeployFeeCollector.s.sol`:

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script, console} from "forge-std/Script.sol";
import {FeeCollector} from "../src/FeeCollector.sol";

contract DeployFeeCollector is Script {
    function run() external {
        address owner      = vm.envAddress("OWNER");
        address withdrawer = vm.envAddress("WITHDRAWER");
        address router     = vm.envAddress("ROUTER");

        // FEE_PERCENT is the human-readable percentage × 100
        // e.g. FEE_PERCENT=75 means 0.75%  (stored as 75 / 10000 internally)
        //      FEE_PERCENT=100 means 1.00%
        //      FEE_PERCENT=1000 means 10.00% (max)
        uint256 feeBps = vm.envUint("FEE_PERCENT");

        vm.startBroadcast();
        FeeCollector fc = new FeeCollector(owner, withdrawer, feeBps, router);
        vm.stopBroadcast();

        console.log("FeeCollector deployed at:", address(fc));
        console.log("Fee rate:", feeBps, "bps =", feeBps, "/ 10000");
    }
}
```

Run:

```bash
# FEE_PERCENT: percentage × 100  →  0.75% = 75 | 1% = 100 | 5% = 500
OWNER=0x... WITHDRAWER=0x... FEE_PERCENT=75 ROUTER=0x... \
  forge script script/DeployFeeCollector.s.sol \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

---

## Admin Operations

Only the `owner` can call these functions.

### Change fee rate

```bash
# cast
cast send $FEE_COLLECTOR "setFeeRate(uint256)" 100 \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
```

```ts
// viem
await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: [
    {
      name: "setFeeRate",
      type: "function",
      stateMutability: "nonpayable",
      inputs: [{ name: "_feeRate", type: "uint256" }],
      outputs: [],
    },
  ],
  functionName: "setFeeRate",
  args: [100n], // 1.0%
  account,
});
```

### Transfer ownership

```bash
cast send $FEE_COLLECTOR "setOwner(address)" $NEW_OWNER \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
```

```ts
await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: [
    {
      name: "setOwner",
      type: "function",
      stateMutability: "nonpayable",
      inputs: [{ name: "_newOwner", type: "address" }],
      outputs: [],
    },
  ],
  functionName: "setOwner",
  args: [NEW_OWNER_ADDRESS],
  account,
});
```

### Change withdrawer

```bash
cast send $FEE_COLLECTOR "setWithdrawer(address)" $NEW_WITHDRAWER \
  --rpc-url $RPC_URL --private-key $OWNER_KEY
```

```ts
await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: [
    {
      name: "setWithdrawer",
      type: "function",
      stateMutability: "nonpayable",
      inputs: [{ name: "_newWithdrawer", type: "address" }],
      outputs: [],
    },
  ],
  functionName: "setWithdrawer",
  args: [NEW_WITHDRAWER_ADDRESS],
  account,
});
```

---

## Withdrawing Collected Fees

Both `owner` and `withdrawer` can call withdraw functions.

### Check accumulated fee balance

```bash
# ERC-20 balance
cast call $TOKEN "balanceOf(address)(uint256)" $FEE_COLLECTOR --rpc-url $RPC_URL

# Native KAS balance
cast balance $FEE_COLLECTOR --rpc-url $RPC_URL
```

```ts
import { erc20Abi } from "viem";

// ERC-20 fee balance
const balance = await publicClient.readContract({
  address: TOKEN_ADDRESS,
  abi: erc20Abi,
  functionName: "balanceOf",
  args: [FEE_COLLECTOR_ADDRESS],
});
console.log("Accumulated fees:", formatUnits(balance, 18));

// Native KAS balance
const kasBalance = await publicClient.getBalance({ address: FEE_COLLECTOR_ADDRESS });
console.log("Accumulated KAS fees:", formatEther(kasBalance));
```

### Withdraw a specific ERC-20 amount

```bash
cast send $FEE_COLLECTOR "withdraw(address,address,uint256)" \
  $TOKEN $TREASURY $(cast to-unit 500 ether) \
  --rpc-url $RPC_URL --private-key $WITHDRAWER_KEY
```

```ts
await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: [
    {
      name: "withdraw",
      type: "function",
      stateMutability: "nonpayable",
      inputs: [
        { name: "token", type: "address" },
        { name: "to", type: "address" },
        { name: "amount", type: "uint256" },
      ],
      outputs: [],
    },
  ],
  functionName: "withdraw",
  args: [USDT_ADDRESS, TREASURY_ADDRESS, parseUnits("500", 6)],
  account,
});
```

### Withdraw all accumulated ERC-20 fees

```bash
cast send $FEE_COLLECTOR "withdrawAll(address,address)" \
  $TOKEN $TREASURY \
  --rpc-url $RPC_URL --private-key $WITHDRAWER_KEY
```

```ts
await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: [
    {
      name: "withdrawAll",
      type: "function",
      stateMutability: "nonpayable",
      inputs: [
        { name: "token", type: "address" },
        { name: "to", type: "address" },
      ],
      outputs: [],
    },
  ],
  functionName: "withdrawAll",
  args: [USDT_ADDRESS, TREASURY_ADDRESS],
  account,
});
```

### Withdraw native KAS fees

```bash
cast send $FEE_COLLECTOR "withdrawNative(address,uint256)" \
  $TREASURY $(cast to-wei 5) \
  --rpc-url $RPC_URL --private-key $WITHDRAWER_KEY
```

```ts
await walletClient.writeContract({
  address: FEE_COLLECTOR_ADDRESS,
  abi: [
    {
      name: "withdrawNative",
      type: "function",
      stateMutability: "nonpayable",
      inputs: [
        { name: "to", type: "address" },
        { name: "amount", type: "uint256" },
      ],
      outputs: [],
    },
  ],
  functionName: "withdrawNative",
  args: [TREASURY_ADDRESS, parseEther("5")],
  account,
});
```

---

## Common Errors

| Error | Cause | Fix |
|-------|-------|-----|
| `NotOwner` | Caller is not the owner | Use the owner wallet |
| `NotWithdrawer` | Caller is neither owner nor withdrawer | Use the owner or withdrawer wallet |
| `InsufficientBalance` | Withdraw amount exceeds contract balance | Check balance first, lower the amount |
| `FeeRateTooHigh` | `feeRate > 1000` (10%) | Use a value between 0 and 1000 |
| `ZeroAddress` | Passed `address(0)` to a setter | Provide a valid address |
