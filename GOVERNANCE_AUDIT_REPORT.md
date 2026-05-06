# Analisis Governance Smart Contract

## Bagian 1: Privilege Matrix (Tabel Utama)

Berikut matrix untuk **semua fungsi external/public yang memiliki access modifier** di kontrak inti. Referensi nomor baris merujuk ke file di folder `contracts/` dan `script/`.

| Kontrak | Fungsi | Modifier | Pemanggil yang Diizinkan (Sekarang) | Lewat Governance? (Ya/Tidak) | Idealnya Lewat Governance? |
|---|---|---|---|---|---|
| **KYCRegistry** | `initialize()` (L52) | `initializer` | Deployer (msg.sender) saat deploy proxy → sudah renounce | Tidak (sekali) | Tidak |
| **KYCRegistry** | `addUser()` (L60) | `onlyRole(KYC_ADMIN_ROLE)` | **Timelock** (Deploy.s.sol L148) | **Ya** (MultiSig → Timelock) | **Tidak** (operasional) |
| **KYCRegistry** | `removeUser()` (L83) | `onlyRole(KYC_ADMIN_ROLE)` | **Timelock** | **Ya** | **Tidak** (operasional) |
| **KYCRegistry** | `batchAddUsers()` (L111) | `onlyRole(KYC_ADMIN_ROLE)` | **Timelock** | **Ya** | **Tidak** (operasional) |
| **KYCRegistry** | `updateKYCLevel()` (L148) | `onlyRole(KYC_ADMIN_ROLE)` | **Timelock** | **Ya** | **Tidak** (operasional) |
| **KYCRegistry** | `addApprovedContract()` (L193) | `onlyRole(KYC_ADMIN_ROLE)` | **Timelock** | **Ya** | **Tidak** (operasional) |
| **KYCRegistry** | `removeApprovedContract()` (L210) | `onlyRole(KYC_ADMIN_ROLE)` | **Timelock** | **Ya** | **Tidak** (operasional) |
| **KYCRegistry** | `upgradeToAndCall()` (via `_authorizeUpgrade` L228) | `onlyRole(DEFAULT_ADMIN_ROLE)` | **Timelock** (Deploy.s.sol L147) | **Ya** | **Ya** |
| **PropertyRegistry** | `initialize()` (L38) | `initializer` | Deployer → sudah renounce | Tidak (sekali) | Tidak |
| **PropertyRegistry** | `registerProperty()` (L55) | `onlyRole(REGISTRY_ADMIN_ROLE)` | **Timelock** + **Factory** (Deploy.s.sol L92, L154) | Factory: **Tidak**; Timelock: **Ya** | Factory: **Tidak** (by design) |
| **PropertyRegistry** | `updateIPFSDocument()` (L103) | `onlyRole(REGISTRY_ADMIN_ROLE)` | **Timelock** + Factory* | **Ya** (Timelock) | **Tidak** (operasional) |
| **PropertyRegistry** | `updatePropertyName()` (L118) | `onlyRole(REGISTRY_ADMIN_ROLE)` | **Timelock** + Factory* | **Ya** | **Tidak** (operasional) |
| **PropertyRegistry** | `updatePropertyValue()` (L132) | `onlyRole(REGISTRY_ADMIN_ROLE)` | **Timelock** + Factory* | **Ya** | **Tidak** (operasional) |
| **PropertyRegistry** | `deactivateProperty()` (L146) | `onlyRole(REGISTRY_ADMIN_ROLE)` | **Timelock** + Factory* | **Ya** | **Tidak** (operasional) |
| **PropertyRegistry** | `reactivateProperty()` (L157) | `onlyRole(REGISTRY_ADMIN_ROLE)` | **Timelock** + Factory* | **Ya** | **Tidak** (operasional) |
| **PropertyRegistry** | `upgradeToAndCall()` (via `_authorizeUpgrade` L214) | `onlyRole(DEFAULT_ADMIN_ROLE)` | **Timelock** (Deploy.s.sol L153) | **Ya** | **Ya** |
| **PropertyTokenFactory** | `initialize()` (L53) | `initializer` | Deployer → sudah renounce | Tidak (sekali) | Tidak |
| **PropertyTokenFactory** | `createPropertyToken()` (L75) | `onlyOwner`, `nonReentrant` | **Timelock** (Deploy.s.sol L158) | **Ya** | Debatable (bisa operator) |
| **PropertyTokenFactory** | `upgradeToAndCall()` (via `_authorizeUpgrade` L159) | `onlyOwner` | **Timelock** | **Ya** | **Ya** |
| **PropertyToken** | `initialize()` (L59) | `initializer` | BeaconProxy (sekali) | Tidak | Tidak |
| **PropertyToken** | `mint()` (L153) | `onlyOwner` | **Timelock** (karena owner = msg.sender Factory = Timelock) | **Ya** | Debatable |
| **PropertyToken** | `pause()` (L159) | `onlyOwner` | **Timelock** | **Ya** | **Tidak** (emergency harus cepat!) |
| **PropertyToken** | `unpause()` (L164) | `onlyOwner` | **Timelock** | **Ya** | **Tidak** (emergency harus cepat!) |
| **MultiSigWallet** | `submitTransaction()` (L103) | `onlyOwner` | MultiSig Owners (Deploy.s.sol L105) | Tidak (ini governance layer) | — |
| **MultiSigWallet** | `confirmTransaction()` (L124) | `onlyOwner` | MultiSig Owners | Tidak | — |
| **MultiSigWallet** | `executeTransaction()` (L137) | `onlyOwner` | MultiSig Owners | Tidak | — |
| **MultiSigWallet** | `addOwner()` (L167) | `onlySelf` | MultiSigWallet itu sendiri (via tx) | **Ya** (via MultiSig internal) | **Ya** |
| **MultiSigWallet** | `removeOwner()` (L178) | `onlySelf` | MultiSigWallet itu sendiri (via tx) | **Ya** | **Ya** |
| **MultiSigWallet** | `changeThreshold()` (L207) | `onlySelf` | MultiSigWallet itu sendiri (via tx) | **Ya** | **Ya** |
| **UpgradeableBeacon** | `upgradeTo()` | `onlyOwner` (OZ) | **Timelock** (Deploy.s.sol L159) | **Ya** | **Ya** |
| **TimelockController** | `schedule()` / `scheduleBatch()` | `onlyRole(PROPOSER_ROLE)` | **MultiSig** (Deploy.s.sol L111) | Tidak (ini governance layer) | — |
| **TimelockController** | `execute()` / `executeBatch()` | `onlyRoleOrOpenRole(EXECUTOR_ROLE)` | **MultiSig** (Deploy.s.sol L113) | Tidak | — |
| **TimelockController** | `cancel()` | `onlyRole(CANCELLER_ROLE)` | **MultiSig** (diberi otomatis saat deploy karena proposer=canceller) | Tidak | — |

> **Catatan teknis `PropertyToken` owner:** Di `PropertyTokenFactory.createPropertyToken()` (L97), parameter `_owner` yang dipass ke `PropertyToken.initialize` adalah `msg.sender`. Karena `createPropertyToken` hanya bisa dipanggil oleh owner Factory (Timelock), maka **semua PropertyToken yang dideploy akan memiliki owner = Timelock**. Ini berarti `mint`, `pause`, dan `unpause` pada setiap token property juga harus melalui Timelock (delay 48 jam).

---

## Bagian 2: Role Ownership Mapping

Berikut mapping kepemilikan role & ownership berdasarkan **deploy script** (`script/Deploy.s.sol`) bukan test setup.

| Kontrak | Role / Ownership | Pemegang Sekarang | Sumber (Baris Kode) |
|---|---|---|---|
| **KYCRegistry** | `DEFAULT_ADMIN_ROLE` | **TimelockController** | Deploy.s.sol L147 |
| **KYCRegistry** | `KYC_ADMIN_ROLE` | **TimelockController** | Deploy.s.sol L148 |
| **PropertyRegistry** | `DEFAULT_ADMIN_ROLE` | **TimelockController** | Deploy.s.sol L153 |
| **PropertyRegistry** | `REGISTRY_ADMIN_ROLE` | **TimelockController** + **PropertyTokenFactory** | Deploy.s.sol L92 (Factory), L154 (Timelock) |
| **PropertyTokenFactory** | `owner()` (Ownable) | **TimelockController** | Deploy.s.sol L158 |
| **PropertyToken** (setiap instance) | `owner()` (Ownable) | **TimelockController** (via Factory L97) | Deploy.s.sol L158 → Factory L97 |
| **UpgradeableBeacon** | `owner()` (OZ Ownable) | **TimelockController** | Deploy.s.sol L159 |
| **MultiSigWallet** | Owners | `[deployer]` (1 orang) | Deploy.s.sol L105 |
| **MultiSigWallet** | Threshold | `1` (1-of-1) | Deploy.s.sol L107 |
| **TimelockController** | `PROPOSER_ROLE` | **MultiSigWallet** | Deploy.s.sol L111 |
| **TimelockController** | `EXECUTOR_ROLE` | **MultiSigWallet** | Deploy.s.sol L113 |
| **TimelockController** | `CANCELLER_ROLE` | **MultiSigWallet** | Otomatis diberikan ke proposer oleh OZ (TimelockController.sol L127) |
| **TimelockController** | `DEFAULT_ADMIN_ROLE` | **TimelockController itu sendiri** (self-admin) | OZ TimelockController.sol L117 |
| **TimelockController** | `minDelay` | `172800` detik (48 jam) | Deploy.s.sol L115 |

> **Catatan kritis:** Deployer telah **renounce** semua role di KYCRegistry dan PropertyRegistry (Deploy.s.sol L149-L156). Setelah deploy, **tidak ada satu pun akunan manusia yang bisa memanggil fungsi admin tanpa melewati MultiSig → Timelock**.

---

## Bagian 3: Alur Governance yang Terdeteksi di Kode

### Alur 1: MultiSig → Timelock → KYCRegistry
- **Contoh operasi:** `addUser`, `removeUser`, `batchAddUsers`, `updateKYCLevel`, `addApprovedContract`, `removeApprovedContract`
- **Teknis:** MultiSig `submitTransaction()` ke `TimelockController.schedule(target=KYCRegistry, ...)` → konfirmasi threshold → execute schedule → tunggu 48 jam → MultiSig `submitTransaction()` ke `TimelockController.execute(...)` → konfirmasi → execute → KYCRegistry terpanggil.
- **Status:** Semua operasional KYC harus lewat Timelock (overkill).

### Alur 2: MultiSig → Timelock → PropertyRegistry
- **Contoh operasi:** `updateIPFSDocument`, `updatePropertyName`, `updatePropertyValue`, `deactivateProperty`, `reactivateProperty`
- **Teknis:** Sama seperti Alur 1, targetnya PropertyRegistry.
- **Status:** Semua update metadata property harus lewat Timelock.

### Alur 3: MultiSig → Timelock → PropertyTokenFactory
- **Contoh operasi:** `createPropertyToken` (deploy token baru)
- **Teknis:** MultiSig → schedule → execute → Factory.createPropertyToken() dipanggil. Factory kemudian otomatis memanggil `PropertyRegistry.registerProperty()` (karena Factory punya `REGISTRY_ADMIN_ROLE`).
- **Status:** Deploy token baru harus lewat Timelock (debatable, tapi acceptable untuk high-value asset).

### Alur 4: MultiSig → Timelock → UpgradeableBeacon
- **Contoh operasi:** `upgradeTo()` (upgrade implementasi PropertyToken untuk SEMUA token)
- **Teknis:** MultiSig → schedule → execute → `beacon.upgradeTo(newImpl)`.
- **Status:** Ini adalah operasi kritis dan **wajib** lewat Timelock. ✅ Benar.

### Alur 5: Langsung → PropertyToken (mint/pause) — tanpa governance?
- **Status:** **Tidak ada jalan langsung.** Semua PropertyToken instance memiliki `owner = Timelock`. Jika ingin `mint` atau `pause`, harus melalui Alur 1-3 di atas (schedule 48 jam).
- **Implikasi:** Emergency pause butuh waktu **minimal 48 jam** + waktu konfirmasi MultiSig. Ini berbahaya.

### Alur 6: Langsung → KYCRegistry (addUser) — tanpa governance?
- **Status:** **Tidak ada jalan langsung.** Setelah deploy, hanya Timelock yang punya `KYC_ADMIN_ROLE`. Operator tidak bisa menambahkan KYC user tanpa proposal 48 jam.

---

## Bagian 4: Best Practice Gap Analysis

### ✅ Apa yang SUDAH BENAR di kode?

1. **UUPS Upgradeable Pattern:** Kontrak inti (`KYCRegistry`, `PropertyRegistry`, `PropertyTokenFactory`) menggunakan UUPS proxy dengan `_authorizeUpgrade` terproteksi. Ini best practice OZ.
2. **Beacon Pattern untuk Token:** PropertyToken menggunakan `UpgradeableBeacon` + `BeaconProxy`. Upgrade 1 kali berlaku untuk semua token instance. Ini efisien dan best practice.
3. **MultiSig + Timelock Architecture:** Ada layer governance yang jelas (MultiSig → Timelock → Contract). Ini best practice untuk critical operation.
4. **ReentrancyGuard di Factory:** `createPropertyToken` memakai `nonReentrant`. Bagus.
5. **Self-admin Timelock:** `admin = address(0)` di constructor, sehingga Timelock tidak punya admin eksternal yang bisa bypass. Ini best practice OZ.

### ❌ Apa yang KURANG BENAR / Overkill?

1. **Operasional KYC melalui Timelock (48 jam delay):**
   - `addUser`, `removeUser`, `batchAddUsers`, `updateKYCLevel` adalah operasi harian yang frekuensinya tinggi.
   - Best practice industri: KYC operasional dihandle oleh **operator address** (EOA atau hot wallet) dengan `KYC_ADMIN_ROLE`. Timelock hanya perlu pegang `DEFAULT_ADMIN_ROLE` untuk emergency (grant/revoke role).
   - **Risiko:** Jika ada user yang urgent perlu di-whitelist atau di-blacklist, harus tunggu 48 jam.

2. **Property Registry Operasional melalui Timelock:**
   - `updateIPFSDocument`, `updatePropertyName`, `deactivateProperty`, `reactivateProperty` adalah operasi harian.
   - Best practice: `REGISTRY_ADMIN_ROLE` dipegang operator. Timelock hanya pegang `DEFAULT_ADMIN_ROLE`.

3. **Emergency Pause melalui Timelock (BERBAHAYA):**
   - `PropertyToken.pause()` dan `unpause()` hanya bisa oleh Timelock.
   - Best practice OpenZeppelin / industri: Pause harus cepat. Gunakan **`PAUSER_ROLE`** terpisah yang dipegang oleh **EOA terpercaya** atau multisig tanpa delay. Unpause bisa lebih lambat (lewat Timelock).
   - **Risiko:** Jika ada exploit aktif di token, tidak bisa di-pause dalam waktu cepat.

4. **PropertyToken mint melalui Timelock:**
   - Jika ada kebutuhan staged fundraising / additional minting, harus lewat 48 jam delay.
   - Best practice: Bisa di-debate. Untuk flexibility, mint bisa dihandle oleh `MINTER_ROLE` terpisah. Tapi jika token supply fixed, Timelock acceptable.

5. **MultiSig Threshold = 1 di Deploy Script:**
   - `MultiSigWallet` dideploy dengan `owners = [deployer]` dan `threshold = 1` (Deploy.s.sol L105-L107).
   - Ini berarti 1-of-1, yang sama saja dengan EOA biasa. Tidak ada manfaat multisig jika hanya 1 owner.
   - Best practice: Minimal 2-of-3 atau 3-of-5 untuk production.

6. **PropertyTokenFactory pakai Ownable (bukan AccessControl):**
   - Factory hanya punya konsep `owner()`, tidak bisa memisahkan antara `OPERATOR_ROLE` (untuk createPropertyToken) dan `ADMIN_ROLE` (untuk upgrade).
   - Best practice: Gunakan AccessControl agar bisa delegate `createPropertyToken` ke operator tanpa memberi hak upgrade.

### 🔧 Apa yang HARUSNYA DIPISAH tapi sekarang digabung?

| Yang Sekarang | Idealnya |
|---|---|
| Timelock memegang **semua role** (`KYC_ADMIN`, `REGISTRY_ADMIN`, ownership) | Timelock hanya pegang `DEFAULT_ADMIN_ROLE` + ownership (untuk upgrade governance). Operator pegang `KYC_ADMIN_ROLE` dan `REGISTRY_ADMIN_ROLE`. |
| `PropertyToken` hanya punya `owner()` (Timelock) untuk pause/mint | `PropertyToken` punya `PAUSER_ROLE` terpisah (hot wallet / fast multisig) untuk emergency pause. |
| `PropertyTokenFactory` pakai `Ownable` | `PropertyTokenFactory` pakai `AccessControl` dengan `OPERATOR_ROLE` untuk create dan `DEFAULT_ADMIN_ROLE` untuk upgrade. |

---

## Bagian 5: Rekomendasi Perubahan Kode (Minimal Invasive)

Diurutkan dari yang paling mudah ke paling kompleks:

### 1. Deploy Script: Pisahkan Role Operasional dari Timelock (GAMPANG)
**File:** `script/Deploy.s.sol`

**Perubahan:** Jangan grant `KYC_ADMIN_ROLE` dan `REGISTRY_ADMIN_ROLE` ke Timelock. Grant ke operator address terpisah.

```solidity
// SEBELUMNYA (Deploy.s.sol L147-156):
kycRegistry.grantRole(KYC_ADMIN_ROLE, timelock);
propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, timelock);

// MENJADI:
address kycOperator = vm.envAddress("KYC_OPERATOR_ADDRESS"); // atau parameter
address registryOperator = vm.envAddress("REGISTRY_OPERATOR_ADDRESS");

kycRegistry.grantRole(KYC_ADMIN_ROLE, kycOperator);      // operator langsung
propertyRegistry.grantRole(REGISTRY_ADMIN_ROLE, registryOperator); // operator langsung

// Timelock tetap pegang DEFAULT_ADMIN_ROLE (untuk emergency governance)
// Timelock juga tetap owner Factory & Beacon (untuk upgrade governance)
```

**Dampak:** Tidak perlu ubah kontrak sama sekali. Hanya ubah alokasi role di deploy script. Test `Governance.t.sol` perlu diupdate untuk mencerminkan operator address.

---

### 2. PropertyToken: Tambah Mekanisme Pause Cepat (SEDANG)
**File:** `contracts/core/PropertyToken.sol`

**Perubahan:** Tambahkan `pauser` address + modifier khusus agar pause bisa oleh EOA terpercaya (bukan hanya owner/Timelock). Unpause tetap owner.

```solidity
// Tambahkan di state variable
address public pauser;

// Tambahkan modifier
modifier onlyPauserOrOwner() {
    require(msg.sender == pauser || msg.sender == owner(), "Not pauser or owner");
    _;
}

// Ubah fungsi pause
function pause() external onlyPauserOrOwner {
    _pause();
}

// unpause tetap onlyOwner (lewat Timelock OK, karena unpause tidak urgent)
function unpause() external onlyOwner {
    _unpause();
}
```

**Dampak:** Kontrak berubah sedikit. Test `PropertyTokenization.t.sol` dan `Security.t.sol` perlu update untuk test pauser.

---

### 3. PropertyTokenFactory: Ganti Ownable ke AccessControl (SULIT)
**File:** `contracts/core/PropertyTokenFactory.sol`

**Perubahan:** Ganti `OwnableUpgradeable` jadi `AccessControlUpgradeable`. Buat role:

```solidity
bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");
```

- `createPropertyToken()` pakai `onlyRole(OPERATOR_ROLE)` (bisa dipegang operator EOA).
- `_authorizeUpgrade()` pakai `onlyRole(DEFAULT_ADMIN_ROLE)` (dipegang Timelock).

**Dampak:** Banyak test di `PropertyTokenization.t.sol` dan `Security.t.sol` yang menggunakan `onlyOwner` assumption perlu direfactor. Interface juga perlu update jika ada perubahan signifikan.

---

### 4. MultiSigWallet: Threshold Production (GAMPANG)
**File:** `script/Deploy.s.sol` L105-L107

**Perubahan:** Jangan hardcode 1 owner dengan threshold 1. Gunakan environment variables atau parameter untuk multiple owners dan threshold ≥ 2.

```solidity
// SEBELUMNYA:
address[] memory multisigOwners = new address[](1);
multisigOwners[0] = deployer;
MultiSigWallet multiSig = new MultiSigWallet(multisigOwners, 1);

// MENJADI:
address[] memory multisigOwners = vm.envAddress("MULTISIG_OWNERS", ","); // contoh
uint256 threshold = vm.envUint("MULTISIG_THRESHOLD");
MultiSigWallet multiSig = new MultiSigWallet(multisigOwners, threshold);
```

---

### 5. TimelockController: Pertimbangkan Canceler Terpisah (OPTIONAL)
Saat ini proposer = executor = canceller (MultiSig). Best practice OZ: bisa memisahkan canceller ke entity lain (misalnya board member terpisah) untuk checks-and-balances. Tapi ini opsional.

---

## Bagian 6: Rangkuman Executive Summary

Kode saat ini meletakkan **SEMUA operasi administratif melalui Timelock (48 jam delay)**, yang merupakan overkill governance. Operasional harian seperti KYC whitelist (`addUser`, `batchAddUsers`), update metadata property (`updateIPFSDocument`, `deactivateProperty`), dan bahkan **emergency pause token** harus menunggu minimal 48 jam + konfirmasi MultiSig — ini berbahaya untuk operasional dan keamanan. Best practice industri adalah: **Timelock hanya mengontrol `DEFAULT_ADMIN_ROLE` dan ownership (untuk upgrade kontrak)**, sementara **operator terpisah** (EOA terpercaya atau multisig tanpa delay) menangani `KYC_ADMIN_ROLE`, `REGISTRY_ADMIN_ROLE`, dan `PAUSER_ROLE`. Beacon upgrade dan factory upgrade memang **wajib** tetap lewat Timelock (sudah benar). Deploy script juga perlu diperbaiki agar MultiSig tidak hanya 1-of-1. Rekomendasi prioritas: (1) pisahkan role di deploy script, (2) tambahkan fast-pause mechanism di PropertyToken, (3) refactor Factory ke AccessControl untuk memisahkan operator create dari admin upgrade.
