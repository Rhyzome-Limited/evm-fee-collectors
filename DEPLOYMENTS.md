# Fee Collector — Deployed Contracts

All contracts are deployed from the same deployer account, owner and withdrawer are set to `0xC9b501CDA88EE0f72f8b53430114729CcfA07eA1`.

---

## Kasplex zkEVM Mainnet (chainId: 202555)

| Contract | Address | Explorer |
|---|---|---|
| **Kasplex Bridge FeeCollector** | `0x2f15c748a51438d02347878a2a0f26bc35b5e938` | [View](https://explorer.kasplex.org/address/0x2f15c748a51438d02347878a2a0f26bc35b5e938) |
| **Zealous Swap FeeCollector** | `0xdfa17269221ce9fdba5bbd28f209a3a23b738978` | [View](https://explorer.kasplex.org/address/0xdfa17269221ce9fdba5bbd28f209a3a23b738978) |

| Parameter | Value |
|---|---|
| RPC | `https://evmrpc.kasplex.org` |
| Explorer | `https://explorer.kasplex.org` |
| Native token | KAS (18 decimals) |
| Kasplex Bridge (upstream) | `0x34606e6d01280f49791628b311cf33a808d1f7c6` |
| Zealous Router (upstream) | `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607` |
| WKAS | `0x2c2Ae87Ba178F48637acAe54B87c3924F544a83e` |

---

## IGRA Mainnet (chainId: 38833)

| Contract | Address | Explorer |
|---|---|---|
| **Zealous Swap FeeCollector** | `0x2f15c748a51438d02347878a2a0f26bc35b5e938` | [View](https://explorer.igralabs.com/address/0x2f15c748a51438d02347878a2a0f26bc35b5e938) |

| Parameter | Value |
|---|---|
| RPC | `https://rpc.igralabs.com:8545` |
| Explorer | `https://explorer.igralabs.com` |
| Native token | iKAS (18 decimals) |
| Zealous Router (upstream) | `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607` |
| WiKAS | `0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242` |

---

## Usage Notes for Mobile

### Bridge (Kasplex only)

Call `bridgeToL1(kaspaAddress)` with native KAS as `msg.value`.

- `feeRate` is in basis points — current value: **75 bps (0.75%)**
- Kaspa address max length: **90 chars**, must start with `kaspa:`
- No minimum enforced by this contract; upstream bridge may impose its own limit

### Swap (Zealous — both chains)

Drop-in replacement for Zealous Router — same function signatures, same `path[]` convention.

- `swapExactKASForTokens` — send KAS, receive token (`path[0]` must be WKAS/WiKAS)
- `swapExactTokensForKAS` — send token, receive KAS
- `swapExactTokensForTokens` — token to token
- Our collector fee (**75 bps**) is deducted from the input amount before forwarding to the router; Zealous pool fee is applied separately by the AMM

---

## ABI (relevant functions)

### Bridge

```json
[
  { "name": "bridgeToL1", "type": "function", "stateMutability": "payable", "inputs": [{ "name": "kaspaAddress", "type": "string" }], "outputs": [] },
  { "name": "feeRate", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{ "name": "", "type": "uint256" }] },
  { "name": "owner", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{ "name": "", "type": "address" }] }
]
```

### Swap

```json
[
  { "name": "swapExactKASForTokens", "type": "function", "stateMutability": "payable", "inputs": [{ "name": "amountOutMin", "type": "uint256" }, { "name": "path", "type": "address[]" }, { "name": "to", "type": "address" }, { "name": "deadline", "type": "uint256" }], "outputs": [{ "name": "amounts", "type": "uint256[]" }] },
  { "name": "swapExactTokensForKAS", "type": "function", "stateMutability": "nonpayable", "inputs": [{ "name": "amountIn", "type": "uint256" }, { "name": "amountOutMin", "type": "uint256" }, { "name": "path", "type": "address[]" }, { "name": "to", "type": "address" }, { "name": "deadline", "type": "uint256" }], "outputs": [{ "name": "amounts", "type": "uint256[]" }] },
  { "name": "swapExactTokensForTokens", "type": "function", "stateMutability": "nonpayable", "inputs": [{ "name": "amountIn", "type": "uint256" }, { "name": "amountOutMin", "type": "uint256" }, { "name": "path", "type": "address[]" }, { "name": "to", "type": "address" }, { "name": "deadline", "type": "uint256" }], "outputs": [{ "name": "amounts", "type": "uint256[]" }] },
  { "name": "feeRate", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{ "name": "", "type": "uint256" }] },
  { "name": "owner", "type": "function", "stateMutability": "view", "inputs": [], "outputs": [{ "name": "", "type": "address" }] }
]
