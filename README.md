# Real Estate Tokenization

Smart contracts for tokenizing real estate properties on Base. Each property gets its own ERC-20 token representing fractional ownership, following the [RealT](https://realt.co/) model.

## Project Structure

```
contracts/
├── core/           → Core infrastructure (KYC, tokens, registry, factory)
├── interfaces/     → Shared interfaces for cross-module integration
├── dividend/       → Dividend distribution & voting (Person 2)
└── market/         → AMM / DEX (Person 3)
```

Each folder has its own README with details specific to that module.

## Quick Start

```bash
npm install
npx hardhat compile
npx hardhat test         # 64 tests
```

## Tech Stack

- Solidity 0.8.24 · Hardhat · OpenZeppelin v5.6.1 · Base (Sepolia/Mainnet)
