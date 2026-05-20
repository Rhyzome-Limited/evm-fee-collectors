# Fee Collector — Deployed Contracts

All contracts are deployed from the same deployer account, owner and withdrawer are set to `0xC9b501CDA88EE0f72f8b53430114729CcfA07eA1`.

---

## Kasplex zkEVM Mainnet (chainId: 202555)

| Contract | Address | Explorer |
|---|---|---|
| **Kasplex Bridge FeeCollector** | `0xaD5c913a6CDbFbEF88f9f7b4e15cA5FCF75cB295` | [View](https://explorer.kasplex.org/address/0xaD5c913a6CDbFbEF88f9f7b4e15cA5FCF75cB295) |
| **Zealous Swap FeeCollector** | `0x1E7dbA18ca3c7C5fa7C7104a5E5CFe50fD73cc42` | [View](https://explorer.kasplex.org/address/0x1E7dbA18ca3c7C5fa7C7104a5E5CFe50fD73cc42) |

| Parameter | Value |
|---|---|
| RPC | `https://evmrpc.kasplex.org` |
| Explorer | `https://explorer.kasplex.org` |
| Native token | KAS (18 decimals) |
| Kasplex Bridge (upstream) | `0x34606e6d01280f49791628b311cf33a808d1f7c6` |
| Zealous Router (upstream) | `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607` |

---

## IGRA Mainnet (chainId: 38833)

| Contract | Address | Explorer |
|---|---|---|
| **Igra Bridge FeeCollector** | `0xaD5c913a6CDbFbEF88f9f7b4e15cA5FCF75cB295` | [View](https://explorer.igralabs.com/address/0xaD5c913a6CDbFbEF88f9f7b4e15cA5FCF75cB295) |
| **Zealous Swap FeeCollector** | `0x1E7dbA18ca3c7C5fa7C7104a5E5CFe50fD73cc42` | [View](https://explorer.igralabs.com/address/0x1E7dbA18ca3c7C5fa7C7104a5E5CFe50fD73cc42) |

| Parameter | Value |
|---|---|
| RPC | `https://rpc.igralabs.com:8545` |
| Explorer | `https://explorer.igralabs.com` |
| Native token | iKAS (18 decimals) |
| Igra Bridge (upstream) | `0x4bb88C213d3eD9dc4bae694f1bc1bF745903b2d0` |
| Zealous Router (upstream) | `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607` |

---

## Fee Collector ABI (relevant functions)

```json
[
  { "name": "bridgeToL1",        "type": "function", "stateMutability": "payable",    "inputs": [{ "name": "kaspaAddress", "type": "string" }], "outputs": [] },
  { "name": "swapExactKASForTokens", "type": "function", "stateMutability": "payable", "inputs": [{ "name": "amountOutMin", "type": "uint256" }, { "name": "path", "type": "address[]" }, { "name": "to", "type": "address" }, { "name": "deadline", "type": "uint256" }], "outputs": [{ "name": "amounts", "type": "uint256[]" }] },
  { "name": "swapExactTokensForKAS", "type": "function", "stateMutability": "nonpayable", "inputs": [{ "name": "amountIn", "type": "uint256" }, { "name": "amountOutMin", "type": "uint256" }, { "name": "path", "type": "address[]" }, { "name": "to", "type": "address" }, { "name": "deadline", "type": "uint256" }], "outputs": [{ "name": "amounts", "type": "uint256[]" }] },
  { "name": "swapExactTokensForTokens", "type": "function", "stateMutability": "nonpayable", "inputs": [{ "name": "amountIn", "type": "uint256" }, { "name": "amountOutMin", "type": "uint256" }, { "name": "path", "type": "address[]" }, { "name": "to", "type": "address" }, { "name": "deadline", "type": "uint256" }], "outputs": [{ "name": "amounts", "type": "uint256[]" }] },
  { "name": "quoteBridgeFee",    "type": "function", "stateMutability": "view",       "inputs": [{ "name": "amountWei", "type": "uint256" }], "outputs": [{ "name": "bridgeFee", "type": "uint256" }, { "name": "collectorFee", "type": "uint256" }, { "name": "netUnlock", "type": "uint256" }] },
  { "name": "feeRate",           "type": "function", "stateMutability": "view",       "inputs": [], "outputs": [{ "name": "", "type": "uint256" }] },
  { "name": "owner",             "type": "function", "stateMutability": "view",       "inputs": [], "outputs": [{ "name": "", "type": "address" }] }
]
```

---

## Usage Notes for Mobile

### Bridge (Kasplex / IGRA)

Call `bridgeToL1(kaspaAddress)` with native KAS as `msg.value`.

- Use `quoteBridgeFee(amountWei)` first to get the expected `netUnlock` (what user receives on L1)
- `feeRate` is in basis points — current value: **75 bps (0.75%)**
- Minimum send: **1000 KAS** (enforced on-chain)
- Kaspa address max length: **90 chars**

### Swap (Zealous)

Drop-in replacement for Zealous Router — same function signatures, same `path[]` convention.

- `swapExactKASForTokens` — send KAS, receive token (`path[0]` must be WKAS)
- `swapExactTokensForKAS` — send token, receive KAS
- `swapExactTokensForTokens` — token to token
- WKAS on Kasplex: `0x2c2Ae87Ba178F48637acAe54B87c3924F544a83e`
- WiKAS on IGRA: `0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242`
