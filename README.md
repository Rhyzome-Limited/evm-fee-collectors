# evm-fee-collectors

Mono-repo for EVM fee collector contracts, one per DEX integration.

## Projects

| Directory | DEX | Description |
|-----------|-----|-------------|
| [`zealous-swap/`](./zealous-swap/) | Zealous Swap | Wraps the Zealous Swap Router and charges a configurable fee on every swap |

## Structure

```
evm-fee-collectors/
└── zealous-swap/        # Zealous Swap fee collector (Foundry project)
    ├── src/             # Contracts
    ├── test/            # Forge tests
    ├── script/          # Deploy scripts
    └── docs/            # Integration & deployment guides
```

## Getting Started

Clone with submodules:

```bash
git clone --recurse-submodules <repo-url>
# or after cloning:
git submodule update --init --recursive
```

Run tests for a specific project:

```bash
cd zealous-swap
forge test
```

## Adding a New Project

1. Create a new directory: `mkdir <dex-name>`
2. Init a Foundry project: `cd <dex-name> && forge init --no-git`
3. Register any submodules from the **root** directory
4. Add an entry to this README
