# evm-fee-collectors — Copilot Instructions

## Project Overview

Mono-repo of EVM **FeeCollector** smart contracts, one per DEX/bridge integration. Each sub-project is an independent Foundry project.

| Directory | Protocol | Chain(s) |
|---|---|---|
| `zealous-swap/` | Zealous Swap Router | Kasplex zkEVM (202555), IGRA (38833) |
| `kasplex-bridge/` | Kasplex L2→L1 Bridge | Kasplex zkEVM (202555) |
| `igra-bridge/` | Igra KasExitBridge | IGRA (38833) |
| `kat-igra-bridge/` | KAT Igra Bridge (KasBridge) | IGRA (38833) |
| `kat-igra-krc20/` | KAT Igra KRC-20 Bridge | IGRA (38833) |
| `admin-ui/` | React admin dashboard | — |

## Stack

- **Contracts**: Solidity ^0.8.20, Foundry (forge test / forge script)
- **Admin UI**: React 18, TypeScript, Viem, Wagmi, RainbowKit, Tailwind CSS, Vite

## Contract Architecture

All `FeeCollector` contracts share the same pattern:
- `owner` — sets `feeRate` / `withdrawer`; 2-step transfer via `transferOwnership` + `acceptOwnership`
- `withdrawer` — can call `withdraw` / `withdrawNative` to pull fees
- `feeRate` — basis points (e.g. 75 = 0.75%); max 1000 (10%); denominator 10_000
- Fee deducted from input before forwarding to upstream protocol
- Custom errors (no `require` strings)

## Deployed Contracts

### Kasplex zkEVM Mainnet (chainId: 202555)
- Kasplex Bridge FeeCollector: `0x2f15c748a51438d02347878a2a0f26bc35b5e938`
- Zealous Swap FeeCollector: `0xdfa17269221ce9fdba5bbd28f209a3a23b738978`
- KAT KRC-20 FeeCollector: `0x642638cF9D656378b679DE02FAbCc5e4E7F1F915`
- Upstream bridge: `0x34606e6d01280f49791628b311cf33a808d1f7c6`
- Upstream router: `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607`
- KAT KRC-20 Bridge (upstream): `0x699e7f4a64f6A5a1d7E26B05806d948338E7aDC2`
- WKAS: `0x2c2Ae87Ba178F48637acAe54B87c3924F544a83e`
- RPC: `https://evmrpc.kasplex.org`

### IGRA Mainnet (chainId: 38833)
- Zealous Swap FeeCollector: `0x2f15c748a51438d02347878a2a0f26bc35b5e938`
- KAT Igra Bridge FeeCollector: `0x9d01E8a2f3DD0B1Fc739d32ca8d79509b501eAb8`
- KAT Igra KRC-20 FeeCollector: `0x642638cF9D656378b679DE02FAbCc5e4E7F1F915`
- Upstream router: `0xA5B0946D31aD2d251e0fe2dfEA8808BFd475e607`
- KAT KasBridge (upstream): `0xb82c5524c5b5c055efb2F8f4AbCcE3173c504f2d`
- KAT KRC-20 Bridge (upstream): `0x295ad12c9F62594523Aa460F10a871aA8F1469cd`
- WiKAS: `0x17Ec7E1768c813E2a3a9b0f94A35605CA520C242`
- RPC: `https://rpc.igralabs.com:8545`

**Owner & withdrawer**: `0xC9b501CDA88EE0f72f8b53430114729CcfA07eA1`

## Common Commands

```bash
# Test a project
cd zealous-swap && forge test
cd kasplex-bridge && forge test

# Deploy (example: zealous-swap)
cd zealous-swap
OWNER=0x... WITHDRAWER=0x... FEE_PERCENT=75 ROUTER=0x... \
  forge script script/DeployFeeCollector.s.sol \
  --rpc-url $RPC_URL --private-key $PRIVATE_KEY --broadcast

# Admin UI
cd admin-ui && npm run dev
```

## Coding Conventions

- Solidity: custom errors, NatSpec on public functions, ASCII art section dividers
- Basis points: always use `FEE_DENOMINATOR = 10_000`
- New FeeCollector: follow existing pattern in `zealous-swap/src/FeeCollector.sol`
- Admin UI: add new contract to `admin-ui/src/config/contracts.ts`; add chain to `chains.ts`
- Tests: Foundry fuzz tests preferred; mirror existing `FeeCollector.t.sol` structure

## Adding a New Integration

1. `mkdir <name> && cd <name> && forge init --no-git`
2. Copy and adapt `src/FeeCollector.sol` + `script/DeployFeeCollector.s.sol` + `test/FeeCollector.t.sol`
3. Register git submodules from repo root
4. Update `README.md` and `DEPLOYMENTS.md`
5. Add entry to `admin-ui/src/config/contracts.ts`

---

## RTK — Token-Optimized CLI

**rtk** is a CLI proxy that filters and compresses command outputs, saving 60-90% tokens.

## Rule

Always prefix shell commands with `rtk`:

```bash
# Instead of:              Use:
git status                 rtk git status
git log -10                rtk git log -10
cargo test                 rtk cargo test
docker ps                  rtk docker ps
kubectl get pods           rtk kubectl pods
```

## Meta commands (use directly)

```bash
rtk gain              # Token savings dashboard
rtk gain --history    # Per-command savings history
rtk discover          # Find missed rtk opportunities
rtk proxy <cmd>       # Run raw (no filtering) but track usage
```

## Caveman

Respond terse like smart caveman. All technical substance stay. Only fluff die.

Rules:
- Drop: articles (a/an/the), filler (just/really/basically), pleasantries, hedging
- Fragments OK. Short synonyms. Technical terms exact. Code unchanged.
- Pattern: [thing] [action] [reason]. [next step].
- Not: "Sure! I'd be happy to help you with that."
- Yes: "Bug in auth middleware. Fix:"

Switch level: /caveman lite|full|ultra|wenyan
Stop: "stop caveman" or "normal mode"

Auto-Clarity: drop caveman for security warnings, irreversible actions, user confused. Resume after.

Boundaries: code/commits/PRs written normal.
