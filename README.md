# PropT-Blockchain — Real Estate Tokenization Platform

Smart contracts for tokenizing real estate properties on Base. Each property gets its own ERC-20 token representing fractional ownership, following the [RealT](https://realt.co/) model with on-chain dividend distribution and DAO governance.

## Architecture

```
contracts/
├── core/            → Core Infrastructure (Person 1)
│   ├── KYCRegistry.sol          - On-chain KYC verification (UUPS Proxy)
│   ├── PropertyRegistry.sol     - Property metadata registry (UUPS Proxy)
│   ├── PropertyToken.sol        - ERC-20 fractional ownership token (Beacon Proxy)
│   └── PropertyTokenFactory.sol - Factory for creating PropertyTokens (UUPS Proxy)
│
├── governance/      → Governance (Person 1)
│   └── MultiSigWallet.sol       - Multi-signature wallet for admin operations
│
├── dividend/        → Dividend & Governance (Person 2)
│   ├── DividendDistribution.sol - Pull-based dividend distribution (Stablecoin)
│   └── PropertyGovernor.sol     - DAO governance with OZ Governor framework
│
├── interfaces/      → Shared interfaces
│   ├── IKYCRegistry.sol
│   ├── IPropertyRegistry.sol
│   └── IPropertyTokenFactory.sol
│
└── market/          → AMM / DEX (Person 3) [Planned]
```

## Features

### Core Infrastructure (Modul 1)
- **KYC-Gated Transfers**: All token transfers require verified KYC status
- **UUPS Proxy Pattern**: Upgradeable contracts with storage safety
- **Beacon Proxy**: Multiple property tokens share same implementation
- **Multi-Sig + Timelock**: Administrative actions require multi-party approval

### Dividend Distribution (Modul 2)
- **Pull-based Model**: O(1) deposit complexity, investors claim individually (anti-DoS)
- **Snapshot-based Epochs**: Uses `ERC20Votes.getPastVotes()` for historical balance verification (anti-flash loan)
- **KYC-Gated Claims**: Only KYC-verified investors can claim dividends
- **Multi-epoch Support**: Investors can batch-claim from multiple unclaimed epochs
- **Stablecoin Payments**: Dividends paid in USDC/stablecoin

### On-Chain Governance (Modul 2)
- **OpenZeppelin Governor**: Battle-tested governance framework
- **Admin-Only Propose**: Hanya MultiSig yang bisa mengajukan proposal (kepatuhan OJK + jaminan verifikasi dana)
- **10% Quorum**: Cukup realistis untuk investor ritel yang pasif, cukup tinggi untuk mencegah manipulasi
- **IPFS Document Storage**: Proposals can attach supporting documents (legal reports, appraisals)
- **Timelock-Controlled Execution**: 48-hour delay for minority investor protection
- **Property Liquidation Flow**: Full lifecycle for selling property (vote → distribute proceeds → deactivate → burn tokens)

## Quick Start

### Prerequisites
- [Foundry](https://book.getfoundry.sh/) (forge, anvil, cast)
- Node.js 18+ (for npm dependencies)

### Install & Build
```bash
npm install
forge build
```

### Run Tests
```bash
# All tests (173 tests)
forge test -vv

# Dividend & Governance only (49 tests)
forge test --match-path 'test/dividend/*' -vv

# Specific test
forge test --match-test test_liquidationFullLifecycle -vvvv
```

### Deploy to Local Anvil
```bash
# Terminal 1: Start Anvil
anvil

# Terminal 2: Deploy
PRIVATE_KEY=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
forge script script/DeployDividend.s.sol \
  --tc DeployDividend \
  --rpc-url http://127.0.0.1:8545 \
  --broadcast -vv
```

## Test Results

| Test Suite | Tests | Status |
|-----------|-------|--------|
| PropertyTokenization | 70 | ✅ Pass |
| Security | 30 | ✅ Pass |
| DividendDistribution | 25 | ✅ Pass |
| PropertyGovernor | 24 | ✅ Pass |
| Others | 24 | ✅ Pass |
| **Total** | **173** | **✅ All Pass** |

## Key Design Decisions

### Dividend: Pull vs Push
Pull model chosen over push to prevent DoS via array iteration. Investors call `claimDividends()` to receive their share.

### Governance: Admin-Propose, Investor-Vote
- **Hanya Admin (MultiSig) yang bisa propose** — menjamin dana sudah terverifikasi sebelum proposal dibuat
- **Investor vote** untuk menyetujui/menolak proposal (10% quorum, >50% majority)
- **Keputusan desain**: Trade-off antara desentralisasi penuh dan kepatuhan regulasi OJK Sandbox

### Property Liquidation (Burn Flow)
```
1. Admin verifikasi dana penjualan sudah diterima off-chain
2. Admin propose likuidasi via Governor
3. Token holders vote (10% quorum, >50% majority)
4. If approved → execute via Timelock:
   a. Deposit sale proceeds as final dividends
   b. Deactivate property in PropertyRegistry
5. Investors claim final dividends
6. Investors burn their own tokens (ERC20Burnable)
```

## Tech Stack

- **Solidity** 0.8.24
- **Foundry** (Forge, Anvil, Cast)
- **OpenZeppelin** Contracts v5.1.0 (Governor, AccessControl, ERC20Votes, UUPS, Beacon)
- **Target Chain**: Base (Sepolia Testnet → Mainnet)

## Environment Variables

Copy `.env.example` to `.env` and configure:
```bash
PRIVATE_KEY=                          # Deployer private key
ANVIL_RPC_URL=http://127.0.0.1:8545 # Local testnet
BASE_SEPOLIA_RPC_URL=                # Base Sepolia RPC
BASESCAN_API_KEY=                    # For contract verification

# Contract addresses (populated after deployment)
KYC_REGISTRY_ADDRESS=
PROPERTY_TOKEN_ADDRESS=
DIVIDEND_DISTRIBUTION_ADDRESS=
PROPERTY_GOVERNOR_ADDRESS=
TIMELOCK_ADDRESS=
STABLECOIN_ADDRESS=
```

## License

MIT
