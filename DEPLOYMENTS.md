# Fee Collector — Deployed Contracts

All contracts are deployed from the same deployer account, owner and withdrawer are set to `0xC9b501CDA88EE0f72f8b53430114729CcfA07eA1`.

---

## Kasplex zkEVM Mainnet (chainId: 202555)

| Contract | Address | Explorer |
|---|---|---|
| **Kasplex Bridge FeeCollector** | `0x2f15c748a51438d02347878a2a0f26bc35b5e938` | [View](https://explorer.kasplex.org/address/0x2f15c748a51438d02347878a2a0f26bc35b5e938) |
| **Zealous Swap FeeCollector** | `0xdfa17269221ce9fdba5bbd28f209a3a23b738978` | [View](https://explorer.kasplex.org/address/0xdfa17269221ce9fdba5bbd28f209a3a23b738978) |
| **KAT KRC-20 FeeCollector** | `0x642638cF9D656378b679DE02FAbCc5e4E7F1F915` | [View](https://explorer.kasplex.org/address/0x642638cF9D656378b679DE02FAbCc5e4E7F1F915) |

| Parameter | Value |
|---|---|
| RPC | `https://evmrpc.kasplex.org` |
| Explorer | `https://explorer.kasplex.org` |
| Native token | KAS (18 decimals) |
| Kasplex Bridge (upstream) | `0x34606e6d01280f49791628b311cf33a808d1f7c6` |
| Zealous Router (upstream) | `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607` |
| KAT KRC-20 Bridge (upstream) | `0x699e7f4a64f6A5a1d7E26B05806d948338E7aDC2` |
| WKAS | `0x2c2Ae87Ba178F48637acAe54B87c3924F544a83e` |

---

## IGRA Mainnet (chainId: 38833)

| Contract | Address | Explorer |
|---|---|---|
| **Zealous Swap FeeCollector** | `0x2f15c748a51438d02347878a2a0f26bc35b5e938` | [View](https://explorer.igralabs.com/address/0x2f15c748a51438d02347878a2a0f26bc35b5e938) |
| **KAT Igra Bridge FeeCollector** | `0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8` | [View](https://explorer.igralabs.com/address/0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8) |
| **KAT Igra KRC-20 FeeCollector** | `0x642638cF9D656378b679DE02FAbCc5e4E7F1F915` | [View](https://explorer.igralabs.com/address/0x642638cF9D656378b679DE02FAbCc5e4E7F1F915) |

| Parameter | Value |
|---|---|
| RPC | `https://rpc.igralabs.com:8545` |
| Explorer | `https://explorer.igralabs.com` |
| Native token | iKAS (18 decimals) |
| Zealous Router (upstream) | `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607` |
| WiKAS | `0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242` |
| KAT KasBridge (upstream) | `0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d` |
| KAT KRC-20 Bridge (upstream) | `0x295ad12c9F62594523Aa460F10a871aA8F1469cd` |

---

## Usage Notes for Mobile

### Kasplex zkEVM (chainId: 202555)

**Bridge — `kasplex-bridge`**

Call `bridgeToL1(kaspaAddress)` with native KAS as `msg.value`.

- `feeRate` in basis points — current: **75 bps (0.75%)**
- Kaspa address max length: **90 chars**, must start with `kaspa:`
- No minimum enforced; upstream bridge may impose its own limit

**KRC-20 Bridge — `kat-igra-krc20`**

Call `bridgeToL1(token, amount, kaspaAddress)` — ERC-20 → KRC-20 on Kaspa L1.

- **Step 1:** `token.approve(feeCollector, grossAmount)`
- **Step 2:** `feeCollector.bridgeToL1{value: feeCollector.getBurnFee()}(token, grossAmount, kaspaAddress)`
- Our fee: **75 bps (0.75%)** of `amount` — deducted in ERC-20 token
- Burn fee: flat KAS, read from `getBurnFee()` immediately before signing — must be exact
- `amount` must be a multiple of `1e10` (18→8 decimal scaling)
- Kaspa address max length: **100 chars**, must start with `kaspa:`

**Swap — `zealous-swap`**

Drop-in replacement for Zealous Router — same function signatures, same `path[]` convention.

- `swapExactKASForTokens` — send KAS, receive token (`path[0]` must be WKAS)
- `swapExactTokensForKAS` — send token, receive KAS
- `swapExactTokensForTokens` — token to token
- Our fee (**75 bps**) deducted from input; Zealous pool fee applied separately by AMM

---

### IGRA Mainnet (chainId: 38833)

**Bridge — `kat-igra-bridge`**

Call `bridgeToL1(kaspaAddress)` with native iKAS as `msg.value`.

- Same function signature as Kasplex bridge — `bridgeToL1(string kaspaAddress)`
- `feeRate` in basis points — current: **75 bps (0.75%)**
- Kaspa address max length: **100 chars**, must start with `kaspa:`
- Fee deducted from `msg.value`; net forwarded to KasBridge `lockForExit`
- Address only validated for prefix — L1 validity enforced by upstream KasBridge
- No minimum enforced; upstream KasBridge imposes its own `MIN_EXIT_AMOUNT`

**KRC-20 Bridge — `kat-igra-krc20`**

Call `bridgeToL1(token, amount, kaspaAddress)` — ERC-20 → KRC-20 on Kaspa L1.

- **Step 1:** `token.approve(feeCollector, grossAmount)`
- **Step 2:** `feeCollector.bridgeToL1{value: feeCollector.getBurnFee()}(token, grossAmount, kaspaAddress)`
- Our fee: **75 bps (0.75%)** of `amount` — deducted in ERC-20 token
- Burn fee: flat iKAS, read from `getBurnFee()` immediately before signing — must be exact
- `amount` must be a multiple of `1e10` (18→8 decimal scaling)
- Kaspa address max length: **100 chars**, must start with `kaspa:`

**Swap — `zealous-swap`**

Drop-in replacement for Zealous Router — same function signatures, same `path[]` convention.

- `swapExactKASForTokens` — send iKAS, receive token (`path[0]` must be WiKAS)
- `swapExactTokensForKAS` — send token, receive iKAS
- `swapExactTokensForTokens` — token to token
- Our fee (**75 bps**) deducted from input; Zealous pool fee applied separately by AMM

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
