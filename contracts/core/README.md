# Real Estate Tokenization — Smart Contracts

Smart contract layer untuk platform tokenisasi properti real estate. Bagian ini menangani **tokenisasi**, **KYC on-chain**, dan **governance** — dipakai sebagai fondasi oleh tim lain (dividen, marketplace).

## Quick Start

```bash
npm install
npx hardhat compile
npx hardhat test
npx hardhat run scripts/deploy.ts --network baseSepolia
```

## Arsitektur

```
contracts/
├── core/
│   ├── KYCRegistry.sol          # Manajemen status KYC user
│   ├── PropertyRegistry.sol     # Registry metadata properti + IPFS
│   ├── PropertyToken.sol        # ERC-20 per properti (BeaconProxy)
│   └── PropertyTokenFactory.sol # Deploy token baru + register otomatis
├── governance/
│   ├── MultiSigWallet.sol       # Multi-signature wallet (2-of-3)
│   └── GovernanceImports.sol    # Import TimelockController dari OZ
└── interfaces/
    ├── IKYCRegistry.sol
    ├── IPropertyRegistry.sol
    └── IPropertyTokenFactory.sol
```

## Kontrak dan Cara Pakainya

### KYCRegistry

Menyimpan status KYC user. Proses KYC sendiri di luar chain (SumSub/Synaps), kontrak ini cuma simpan hasilnya.

```solidity
// Tambah user yang sudah lulus KYC
kycRegistry.addUser(userAddress, 1);   // 1 = Basic
kycRegistry.addUser(userAddress, 2);   // 2 = Enhanced

// Batch (max 100 per call)
kycRegistry.batchAddUsers([addr1, addr2], [1, 2]);

// Cabut KYC
kycRegistry.removeUser(userAddress);

// Cek status
kycRegistry.isVerified(userAddress);   // true/false
kycRegistry.getKYCLevel(userAddress);  // 0, 1, atau 2
```

**Siapa yang bisa panggil:** hanya address dengan `KYC_ADMIN_ROLE`.

### PropertyTokenFactory

Deploy token ERC-20 baru untuk setiap properti. Otomatis register di PropertyRegistry.

```solidity
(address tokenAddr, uint256 propId) = factory.createPropertyToken({
    name: "RealToken - Apartemen Sudirman",
    symbol: "RTAPS",
    totalSupply: 1000 ether,       // 1000 token
    propertyName: "Apartemen Sudirman Park",
    propertyAddress: "Jl. Sudirman No. 1, Jakarta",
    totalValue: 1_000_000 ether,   // nilai properti dalam wei
    ipfsDocumentURI: "ipfs://QmXxx...",
    requiredKYCLevel: 1            // Basic KYC cukup
});
```

**Siapa yang bisa panggil:** hanya owner (setelah deploy = TimelockController).

### PropertyToken

ERC-20 biasa, tapi setiap transfer dicek KYC. Mint dan burn skip KYC check.

```solidity
// Transfer (kedua pihak harus KYC)
token.transfer(to, amount);

// Mint tambahan (staged fundraising)
token.mint(to, amount);

// Pause emergency
token.pause();
token.unpause();
```

**Penting untuk tim dividen:** gunakan `ERC20Votes` yang sudah built-in untuk snapshot balance pada block tertentu — pakai `getPastVotes(account, blockNumber)` untuk hitung porsi dividen.

### PropertyRegistry

Source of truth untuk data properti. Query langsung:

```solidity
// By property ID
PropertyRegistry.Property memory prop = registry.getProperty(1);
// prop.propertyName   -> "Apartemen Sudirman Park"
// prop.tokenAddress   -> 0x1234...
// prop.totalValue     -> 1000000 ether
// prop.ipfsDocumentURI -> "ipfs://QmXxx..."
// prop.isActive       -> true

// By token address (reverse lookup)
registry.getPropertyByToken(tokenAddress);

// Semua property IDs
registry.getAllPropertyIds();
```

## Alamat Kontrak (setelah deploy)

Setelah `npx hardhat run scripts/deploy.ts --network baseSepolia`, semua alamat disimpan di `deployments-baseSepolia.json`:

```json
{
  "contracts": {
    "KYCRegistry": "0x...",
    "PropertyRegistry": "0x...",
    "PropertyTokenBeacon": "0x...",
    "PropertyTokenFactory": "0x...",
    "MultiSigWallet": "0x...",
    "TimelockController": "0x..."
  }
}
```

Frontend/backend tinggal baca file ini.

## Untuk Tim Dividen (Orang 2)

Yang perlu kamu tahu:
1. **PropertyToken** sudah punya `ERC20VotesUpgradeable` — balance di-checkpoint otomatis tiap transfer
2. Pakai `token.getPastVotes(account, blockNumber)` untuk snapshot porsi kepemilikan
3. Semua token ada di `factory.getDeployedTokens()` — loop untuk distribusi
4. Token bisa di-pause via `token.pause()` — pastikan dividen kontrakmu handle ini

Interface yang perlu kamu import:
```solidity
import "../interfaces/IPropertyTokenFactory.sol";
import "../interfaces/IKYCRegistry.sol";
```

## Untuk Tim Marketplace (Orang 3)

Yang perlu kamu tahu:
1. **Transfer dicek KYC** — buyer dan seller harus verified di KYCRegistry
2. `token.requiredKYCLevel()` → cek minimum KYC level per token
3. `kycRegistry.isVerified(addr)` → cek sebelum listing/bidding
4. Token ERC-20 standar — kompatibel dengan approve/transferFrom flow biasa
5. `ERC20Permit` sudah ada — bisa gasless approval via `token.permit()`

## Governance Flow

Setelah deployment, semua operasi admin harus lewat:
```
MultiSigWallet (2-of-3 confirm) → TimelockController (48h delay) → Target Contract
```

Deployer tidak punya akses apapun setelah deploy selesai.

## Testing

```bash
npx hardhat test                          # 127 tests
npx hardhat test test/Security.test.ts    # attack simulation only
npx hardhat test test/Governance.test.ts  # governance flow only
```

## Network

| Network | Chain ID | RPC |
|---|---|---|
| Base Sepolia (testnet) | 84532 | https://sepolia.base.org |
| Base Mainnet | 8453 | https://mainnet.base.org |

Environment variables:
```
BASE_SEPOLIA_RPC_URL=...
PRIVATE_KEY=...
BASESCAN_API_KEY=...
```
