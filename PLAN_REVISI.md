# Rencana Revisi Kode dan Bab 4

Dokumen ini merangkum dua kategori revisi yang akan dikerjakan besok.

## Tujuan utama

1. Sinkronkan kode dengan keputusan desain baru yaitu pemisahan operator harian dari jalur multisig untuk upgrade. Sumber rekomendasi: `GOVERNANCE_AUDIT_REPORT.md`.
2. Perbarui Bab 4 agar konsisten dengan Bab 2 yang sudah selesai. Semua justifikasi pilihan desain ada di Bab 4. Cross reference ke Bab 2 boleh.
3. Diagram kontrak dan sequence diagram ditunda dulu.
4. Saat menulis justifikasi upgradeability di Bab 4, sertakan contoh perubahan regulasi yang konkret.

---

## Bagian A. Revisi Kode Smart Contract

Urutan dari paling mudah ke paling kompleks. Ikuti `GOVERNANCE_AUDIT_REPORT.md` Bagian 5.

### A1. Deploy script: pisahkan operator dari Timelock

**File**: `script/Deploy.s.sol`

**Perubahan**:
- `KYC_ADMIN_ROLE` di KYCRegistry tidak lagi dipegang Timelock. Berikan ke address operator KYC (EOA atau hot wallet).
- `REGISTRY_ADMIN_ROLE` di PropertyRegistry tidak lagi dipegang Timelock. Berikan ke address operator registry.
- Timelock tetap pegang `DEFAULT_ADMIN_ROLE` di kedua kontrak (untuk grant atau revoke role di masa depan).
- Timelock tetap owner Factory dan UpgradeableBeacon (untuk upgrade governance).

**Cara mendapat alamat operator**: pakai `vm.envAddress("KYC_OPERATOR_ADDRESS")` dan `vm.envAddress("REGISTRY_OPERATOR_ADDRESS")`. Tambahkan ke `.env.example`.

**Test yang terpengaruh**: `test/Governance.t.sol`. Pastikan operator EOA bisa langsung memanggil `addUser`, `batchAddUsers`, `updateIPFSDocument`, dll tanpa lewat Timelock.

### A2. Deploy script: MultiSig threshold production

**File**: `script/Deploy.s.sol` line 105 sampai 107

**Perubahan**:
- Hapus hardcoded `[deployer]` dengan threshold 1.
- Ambil `MULTISIG_OWNERS` (comma-separated) dan `MULTISIG_THRESHOLD` dari env.
- Untuk testnet boleh threshold 2 of 3 atau 3 of 5. Untuk mainnet minimal 3 of 5.

**Test yang terpengaruh**: `test/Governance.t.sol` setup pasti perlu update.

### A3. PropertyToken: tambah mekanisme pause cepat

**File**: `contracts/core/PropertyToken.sol`

**Perubahan**:
- Tambah state variable `address public pauser`.
- Tambah modifier `onlyPauserOrOwner` yang mengizinkan `msg.sender == pauser` atau `msg.sender == owner()`.
- Ubah `pause()` jadi `onlyPauserOrOwner`.
- `unpause()` tetap `onlyOwner` (lewat Timelock, tidak urgent).
- Set `pauser` saat `initialize()` (parameter baru) atau lewat fungsi `setPauser` yang `onlyOwner`.

**Test yang terpengaruh**: `test/PropertyTokenization.t.sol` dan `test/Security.t.sol`. Tambah test:
- Pauser bisa pause, owner bisa pause.
- Address random tidak bisa pause.
- Hanya owner yang bisa unpause.
- Hanya owner yang bisa setPauser.

### A4. PropertyTokenFactory: Ownable jadi AccessControl

**File**: `contracts/core/PropertyTokenFactory.sol`

**Perubahan**:
- Ganti `OwnableUpgradeable` jadi `AccessControlUpgradeable`.
- Buat role `OPERATOR_ROLE = keccak256("OPERATOR_ROLE")`.
- `createPropertyToken()` pakai `onlyRole(OPERATOR_ROLE)`. Ini bisa dipegang operator EOA tanpa delay.
- `_authorizeUpgrade()` pakai `onlyRole(DEFAULT_ADMIN_ROLE)` (Timelock).
- Update `initialize` untuk grant kedua role ke initialOwner saat bootstrap, lalu deploy script yang transfer.

**Catatan**: Parameter `_owner` yang dipass ke `PropertyToken.initialize` saat ini = `msg.sender` di `createPropertyToken`. Setelah perubahan, `msg.sender` = operator EOA. Berarti owner setiap PropertyToken jadi operator EOA, bukan Timelock. Pikirkan apakah ini yang diinginkan. Alternatif: tetap pass Timelock address sebagai _owner ke PropertyToken, dengan parameter eksplisit di createPropertyToken.

**Test yang terpengaruh**: banyak. `PropertyTokenization.t.sol` dan `Security.t.sol` punya banyak `onlyOwner` assumption.

### A5. (Opsional) TimelockController canceller terpisah

**Status**: skip dulu kecuali waktu ada. Sekarang proposer = executor = canceller (MultiSig). Pemisahan canceller ke entity lain adalah opsional.

### A6. Tambahkan lapisan Fuzzing dan Invariant Testing

**Konteks**: Bab 1, 2, 3 sudah diubah. Lapisan ke-5 metodologi pengujian sekarang adalah Fuzzing dan Invariant Testing (sebelumnya Attack Simulation). Kode test layer ini perlu dibuat dari nol.

**File baru `test/Fuzz.t.sol`** (target 5-7 fuzz tests):

Properti kandidat untuk difuzz:
- KYC level enforcement: `testFuzz_KYCLevel_AcceptsAtOrAbove(uint8 userLevel, uint8 reqLevel)` dan negatifnya
- Transfer bound: `testFuzz_Transfer_RespectsBalance(uint256 amount)` (amount > balance harus revert)
- Batch size: `testFuzz_BatchAddUsers_BoundedByMax(uint8 count)` (bound 1-100)
- Property value: `testFuzz_RegisterProperty_AcceptsAnyNonZero(uint256 value)`
- Access control random caller: `testFuzz_AddUser_RejectsAnyNonAdmin(address caller)` dengan `vm.assume(caller != admin)`
- Approved contract toggle: `testFuzz_ApprovedContract_TransferAllowed(address contractAddr, uint256 amount)`

Setiap fuzz test pakai `vm.assume()` untuk membatasi input space yang valid. Foundry default 256 runs, naikkan ke 1000 lewat config.

**File baru `test/Invariant.t.sol` + `test/handlers/Handler.sol`** (target 2-3 invariants):

Invariant kandidat:
- `invariant_TotalSupplyEqualsBalanceSum()`: untuk setiap PropertyToken, jumlah balanceOf seluruh holder = totalSupply (no value created/destroyed)
- `invariant_VerifiedCountConsistent()`: `getVerifiedUserCount()` selalu sama dengan jumlah entry aktif di mapping
- `invariant_PropertyIdMonotonic()`: `nextPropertyId` hanya naik, tidak pernah collide atau turun
- `invariant_OwnershipNeverEscapesGovernance()`: `factory.owner() == timelock` dan `beacon.owner() == timelock` selalu

Handler contract membatasi action space yang dipanggil fuzzer (transfer ke address yang sudah KYC, add/remove user via admin, dll) supaya invariant testing tidak revert pada setup yang invalid.

**Update `foundry.toml`**:
```toml
[fuzz]
runs = 1000
seed = "0x1"

[invariant]
runs = 256
depth = 50
fail_on_revert = false
```

**Verifikasi**:
- `forge test --match-path test/Fuzz.t.sol -vvv` semua passing
- `forge test --match-path test/Invariant.t.sol -vvv` tidak ada invariant violation
- `forge coverage` menunjukkan delta coverage dari fuzz layer

### Checklist verifikasi setelah A1 sampai A4 dan A6

- [ ] `forge build` sukses tanpa warning baru
- [ ] `forge test` semua passing (termasuk fuzz dan invariant)
- [ ] `forge coverage` tidak turun signifikan dan menunjukkan delta dari fuzz layer
- [ ] Slither pada kode baru tidak menambah temuan high atau medium
- [ ] Deploy script bisa dijalankan di anvil lokal dengan threshold ≥ 2
- [ ] Fuzz tests jalan dengan minimum 1000 runs tanpa shrunken counterexample
- [ ] Invariant tests jalan dengan depth 50, 256 runs tanpa pelanggaran

---

## Bagian B. Revisi Bab 4 (Perancangan)

Tujuan: semua justifikasi pilihan desain ada di Bab 4. Bab 2 cuma menyediakan teori (netral), referensi balik dengan `\ref{bab:2}` boleh.

### B1. §4.4.1 Modul KYCRegistry

**Status sekarang**: justifikasi pemilihan shared registry sudah ada. Justifikasi mekanisme approved contracts juga ada.

**Yang perlu ditambah atau diubah**:
- Justifikasi mengapa **KYC dilakukan off-chain oleh provider seperti SumSub atau Synaps, bukan on-chain**. Alasan: privasi data pribadi (PII tidak boleh on-chain), kepatuhan PDP/POJK, biaya gas, kemampuan provider untuk verifikasi dokumen secara legal.
- Justifikasi **pemisahan KYC_ADMIN_ROLE (operator harian) dari DEFAULT_ADMIN_ROLE (untuk grant atau revoke role lewat governance)**. Ini sekarang harus eksplisit karena kode akan diubah ke arsitektur ini.
- Justifikasi **dua level KYC (Basic dan Enhanced)** sebagai implementasi risk-based approach FATF (sumber `fatf2021` sudah di bib).
- Justifikasi **batch size maksimum 100 alamat per transaksi**. Alasan: pertimbangan block gas limit jaringan target (Base L2). Sebut angka konkret kalau ada.
- Justifikasi **swap-and-pop pattern** untuk penghapusan dari array. Alasan: O(1) deletion, hindari shift yang O(n).

### B2. §4.4.2 Modul PropertyToken

**Status sekarang**: justifikasi ERC-20 sudah ada (sumber multi-issuer ERC-3643 sudah dirinci).

**Yang perlu ditambah atau diubah**:
- Justifikasi **mekanisme pause cepat dengan pauser address terpisah** (perubahan kode A3). Argumen: emergency pause harus cepat (orde menit), tidak boleh tunggu 48 jam Timelock. Sumber: pola Aave Protocol Guardian (sudah di bib `aave2023guardian`).
- Justifikasi **kombinasi ERC20Votes dan ERC20Permit sebagai extension point** untuk modul dividen dan marketplace yang dikembangkan anggota lain.
- Justifikasi **per-token requiredKYCLevel**. Alasan: properti bernilai tinggi mewajibkan Enhanced, properti murah cukup Basic.
- Justifikasi **mengecualikan mint dan burn dari KYC check**. Alasan: bukan transfer antar investor, sudah dikontrol owner.

### B3. §4.4.3 Modul PropertyTokenFactory

**Status sekarang**: justifikasi atomicity sudah ada. Justifikasi transient storage reentrancy guard sudah ada.

**Yang perlu ditambah atau diubah**:
- Justifikasi **AccessControl dengan OPERATOR_ROLE terpisah dari DEFAULT_ADMIN_ROLE** (perubahan kode A4). Operator bisa createPropertyToken tanpa delay, upgrade tetap lewat governance.
- Justifikasi **createPropertyToken sebagai operator harian, bukan operasi yang lewat governance**. Argumen: penerbitan token baru terjadi cukup sering dan tidak ada risiko irreversible (kalau salah, properti bisa dideaktivasi).

### B4. §4.4.4 Modul PropertyRegistry

**Status sekarang**: justifikasi hybrid storage on-chain + IPFS sudah ada dengan tabel perbandingan. Justifikasi soft delete dan reverse lookup sudah ada.

**Yang perlu ditambah atau diubah**:
- Justifikasi **pilihan IPFS** vs alternatif (Arweave, Filecoin, S3). Alasan: content-addressed (immutability terdeteksi via CID change), terdesentralisasi, ada gateway publik, biaya rendah.
- Justifikasi **sentinel value penomoran mulai dari 1**. Alasan: nilai default 0 di Solidity berfungsi sebagai penanda "belum terdaftar".
- Justifikasi **REGISTRY_ADMIN_ROLE dipegang operator EOA + Factory, bukan Timelock** (perubahan kode A1). Argumen: update dokumen IPFS dan metadata properti adalah operasi rutin yang tidak boleh tunggu 48 jam.

### B5. §4.4.5 Modul Governance — INI YANG PALING BERUBAH

**Status sekarang**: paragraf bilang "Operasi administratif kritis, yaitu upgrade kontrak, perubahan konfigurasi, dan pause darurat, harus melalui jalur governance berlapis". Tapi kode sekarang menjalankan SEMUA operasi (termasuk operasional harian) lewat jalur ini.

**Yang perlu diubah** (rewrite signifikan):
- Pisahkan dengan jelas: operasi mana yang **Tier 1 (operator harian, langsung lewat RBAC)**, operasi mana yang **Tier 2 (kritis, lewat MultiSig + Timelock)**, dan operasi mana yang **Tier 3 (emergency pause, lewat pauser address tanpa delay)**.
- Tabel rangkuman operasi per tier (mirip Privilege Matrix di GOVERNANCE_AUDIT_REPORT.md tapi disederhanakan).
- Justifikasi mengapa pemisahan tier ini diperlukan. Alasan: persetujuan M-of-N + delay 48 jam untuk operasi rutin tidak praktis (memperlambat operasional, biaya gas multi-step transaction tidak proporsional). Sumber: pola Aave (`aave2023guardian`, `aave2023governance`, `aave2023pool`) yang memisahkan Protocol Guardian dari Governance.
- Justifikasi MultiSig $M$-of-$N$ self-governing (ini sudah ada).
- Justifikasi Timelock self-admin tanpa admin eksternal (ini sudah ada).

### B6. §4.4 (umum) — justifikasi upgradeability dengan contoh regulasi konkret

**Status sekarang**: §4.4.4 dan tempat lain menyebut upgradeability tanpa detail kenapa. Bab 1 menyebut regulasi yang berkembang sebagai motivasi.

**Yang perlu ditambah** di section yang relevan (mungkin di intro §4.4 atau di section governance):
- Contoh konkret skenario yang memerlukan upgrade tanpa migrasi token holder:
  - **Penambahan KYC level baru**: bila OJK di masa depan mensyaratkan level KYC tambahan (misal level 3 untuk transaksi di atas nominal tertentu sesuai ambang APU PPT), kontrak KYCRegistry perlu menambah konstanta dan validasi tanpa migrasi data investor yang sudah terdaftar.
  - **Perubahan schema metadata properti**: bila regulasi mensyaratkan field baru (misal hash sertifikat HGB, NIB pemilik, atau metadata pajak), PropertyRegistry perlu di-upgrade tanpa kehilangan data properti yang sudah teregistrasi.
  - **Penyesuaian batas batch**: bila operasional skala lebih besar dari estimasi awal, MAX_BATCH_SIZE bisa diperbarui tanpa migrasi.
  - **Patch keamanan**: bila ada kerentanan baru ditemukan setelah deploy (misal kategori baru di SWC Registry), implementasi bisa diganti tanpa mengubah alamat kontrak yang sudah tercatat di regulator.
- Tegaskan bahwa ketiadaan upgradeability akan memaksa migrasi seluruh holder ke kontrak baru, biayanya tinggi dan berisiko (kehilangan data, perubahan alamat kontrak yang tercatat).

### B7. Cross-reference cleanup

- Pastikan semua `\ref{bab:2}` di Bab 4 menunjuk ke konten yang masih ada di Bab 2 (tidak putus karena edit kemarin).
- Konsistensi terminologi: pakai "custom KYC registry" (bukan "shared registry" + "centralized registry" bergantian). Tabel 4.2 sudah pakai "Shared Registry"; pertimbangkan ganti jadi "Custom KYC Registry" untuk konsistensi dengan Bab 1 dan Bab 2.

### Checklist verifikasi setelah B1 sampai B7

- [ ] Tidak ada residu klaim "kompatibilitas DEX" sebagai kontribusi
- [ ] Tidak ada em dash (cek dengan `rg -F -- '---' bab4.tex` ; ada beberapa pre-existing di KNF list, biarkan kecuali user mau diubah)
- [ ] Setiap pilihan desain non-trivial punya justifikasi eksplisit
- [ ] Setiap justifikasi pilihan KYC/identity provider tetap di Bab 4 (Bab 2 cuma teori)
- [ ] Cross-reference ke Bab 2 valid
- [ ] Compile PDF sukses, tidak ada warning citation undefined

---

## Bagian C. Daftar Justifikasi yang Wajib Ada di Bab 4

Daftar ini adalah CONTOH (bukan exhaustive). Pakai sebagai checklist saat menulis. Setiap justifikasi sebaiknya:
- Menyatakan pilihan secara eksplisit
- Menyebut alternatif yang dipertimbangkan
- Memberi alasan teknis dan/atau kontekstual
- Sebut sumber bila ada (sitasi yang sudah di bib lebih baik daripada sumber baru)

### Justifikasi pilihan standar dan arsitektur

1. **ERC-20 sebagai standar token** (sudah, di §4.4.2)
2. **Custom KYC Registry sebagai identity provider, bukan ONCHAINID** (sudah, di §4.4.1)
3. **Upgradeable proxy, bukan immutable contract** (perlu diperkuat dengan contoh regulasi konkret di B6)
4. **UUPS untuk kontrak singleton, Beacon untuk PropertyToken multi-instance** (sudah, di §4.4.2)
5. **Storage gap (`uint256[44]` di KYCRegistry, `uint256[47]` di PropertyToken)** sebagai antisipasi penambahan variabel di masa depan tanpa storage collision

### Justifikasi mekanisme KYC

6. **KYC dilakukan off-chain oleh provider, hasilnya saja yang dicatat on-chain**. Alasan: privasi data pribadi (PDP), biaya gas, kemampuan verifikasi dokumen legal yang hanya bisa dilakukan provider tersertifikasi
7. **Dua level KYC (Basic dan Enhanced)** sebagai risk-based approach FATF (sumber `fatf2021`)
8. **Per-token requiredKYCLevel** sehingga setiap properti punya level minimum sendiri
9. **Mekanisme approved contracts** sebagai jalur otorisasi alternatif untuk kontrak otonom yang tidak punya personhood hukum (sumber `fatf2021`). Ini juga jadi extensibility hook untuk modul market mechanism kelompok
10. **Batch size maksimum 100** sebagai trade-off antara efisiensi gas dan block gas limit jaringan L2
11. **Swap-and-pop pattern** untuk pencabutan KYC dari array, O(1) deletion

### Justifikasi mekanisme penyimpanan data

12. **Hybrid storage on-chain + IPFS** untuk metadata properti (sudah, di §4.4.4 dengan tabel perbandingan)
13. **IPFS dipilih dibanding alternatif (Arweave, S3, Filecoin)** karena content-addressing yang membuat manipulasi terdeteksi
14. **Soft delete untuk properti** (status nonaktif, data tetap) untuk audit trail dan kemungkinan reaktivasi
15. **Sentinel value penomoran mulai dari 1** memanfaatkan default zero di Solidity sebagai marker

### Justifikasi mekanisme transfer dan token

16. **Mengecualikan mint dan burn dari KYC check** (bukan transfer antar investor)
17. **ERC20Votes untuk snapshot saldo per blok** sebagai extension point untuk modul dividen
18. **ERC20Permit untuk gasless approve** sebagai extension point untuk modul marketplace
19. **One property = one token (bukan ERC-1155 multi-token)** mengikuti pola RealT, tiap properti adalah entitas legal terpisah

### Justifikasi mekanisme governance dan akses

20. **Pemisahan tier governance**: operator harian (RBAC) vs MultiSig+Timelock (kritis) vs pauser cepat (emergency). Sumber: pola Aave Guardian (`aave2023guardian`, `aave2023governance`, `aave2023pool`)
21. **MultiSig M-of-N self-governing** (penambahan, penghapusan, perubahan threshold lewat MultiSig sendiri, bukan satu owner)
22. **TimelockController self-admin tanpa admin eksternal** sehingga tidak ada bypass dari luar jalur governance
23. **Pauser address terpisah untuk emergency pause** (perubahan kode A3) sehingga pause bisa dilakukan dalam orde menit
24. **createPropertyToken sebagai operator harian (bukan governance)** karena penerbitan token baru bukan operasi irreversible (properti bisa dideaktivasi)
25. **Upgrade kontrak harus lewat MultiSig + Timelock** karena dampaknya tidak dapat dipulihkan (storage layout permanen)

### Justifikasi mekanisme keamanan

26. **ReentrancyGuardTransient (EIP-1153) bukan ReentrancyGuard biasa** untuk efisiensi gas (sudah, di §4.4.3)
27. **Atomicity deploy + register** menggunakan satu transaksi factory untuk menghindari inkonsistensi token-tanpa-metadata atau metadata-tanpa-token (sudah, di §4.4.3)
28. **`_disableInitializers()` pada constructor implementasi** untuk mencegah uninitialized implementation attack
29. **AccessControl dengan role terpisah** sehingga kompromi satu role tidak menyebabkan pengambilalihan total

### Justifikasi yang sudah ada di Bab 4 dengan cukup detail

- Pemisahan KYCRegistry sebagai shared registry vs per-token whitelist (sudah, dengan tabel perbandingan)
- Beacon Proxy untuk multi-instance upgrade efficiency (sudah)
- Pendekatan modular per kontrak dengan clear ownership boundary (sudah)

---

## Bagian C. Rewrite Bab 6 sesuai struktur 5 lapisan baru

**Konteks**: Bab 1, 2, 3 sudah diubah dari "Attack Simulation" jadi "Fuzzing dan Invariant Testing" sebagai lapisan ke-5. Bab 6 sekarang inkonsisten karena masih pakai terminologi lama. Rewrite Bab 6 perlu dilakukan setelah kode A6 selesai supaya angka dan tabel akurat.

### C1. Tabel 6.1 lapisan pengujian (line 33-44)

Hapus baris ke-5 "Attack Simulation". Ganti jadi "Fuzzing dan Invariant Testing" dengan tools "Foundry (Forge fuzz dan invariant runner)".

### C2. Paragraf overview lapisan (line 49)

Rewrite kalimat tentang lapisan kelima. Sebelumnya: "Lapisan kelima (Attack Simulation) menguji ketahanan kontrak dalam kondisi adversarial dengan mensimulasikan vektor serangan yang telah diklasifikasikan". Ganti jadi paragraf yang menjelaskan fuzzing dan invariant testing sebagai eksplorasi properti pada ruang masukan kontinu/kombinatorial. Sitasi `grieco2020echidna` dan `foundry2024`.

### C3. Kriteria keberhasilan (line 64)

Hapus item "Attack Simulation: Seluruh simulasi serangan gagal dengan revert atau error yang sesuai". Ganti jadi item baru: "Fuzzing dan Invariant Testing: Seluruh fuzz tests passing pada minimum X runs, dan tidak ditemukan pelanggaran invariant pada Y depth selama Z runs."

### C4. Distribusi test case (line 73)

Sekarang berbunyi "Total 127 test case dirancang untuk mencakup kelima lapisan pengujian: 92 unit test, integration test untuk alur end-to-end, dan 33 attack simulation test". Hitung ulang dengan struktur baru:
- Unit testing: hitung total dari `PropertyTokenization.t.sol` + tests di `Security.t.sol` yang sebenarnya unit-level (ACL, KYCBypass, UpgradeHijack, ReInit, EmergencyPause)
- Integration testing: hitung dari `Governance.t.sol` integration tests + StorageCollision + MultiSig flow
- Fuzzing: jumlah `testFuzz_*` × runs per test
- Invariant: jumlah `invariant_*` × runs × depth

Format yang lebih akurat: pakai jumlah test functions dan total executions terpisah untuk fuzz/invariant.

### C5. Tabel mapping kebutuhan (line 89-99)

Ganti label kolom "Lapisan Pengujian" yang sekarang menyebut "Attack Sim." jadi "Unit + Integration" atau spesifik per kebutuhan. Kebutuhan keamanan (KYC enforcement, emergency pause, upgrade) bisa tambah cross-reference ke fuzz/invariant tests yang relevan.

### C6. Section 5 (line 138-139)

Rename `\section{Attack Simulation}` jadi `\section{Fuzzing dan Invariant Testing}`. Rename label `\label{sec:attackSimulation}` jadi `\label{sec:fuzzInvariant}`. Update referensi label di tempat lain kalau ada.

### C7. Isi konten Section 5 (line 141-142, sekarang TODO)

Konten yang diisi:
- Daftar fuzz tests dengan properti yang dicover, jumlah runs, hasil
- Daftar invariant tests dengan properti, depth, runs, hasil
- Coverage delta yang dicapai oleh fuzzing dibandingkan unit testing saja
- Mapping fuzz/invariant tests ke risiko upgradeable contracts dari Wang et al. (2025) untuk academic backing tambahan

### C8. Konsistensi referensi internal

Cek seluruh Bab 6 untuk:
- Term "attack simulation" yang masih tertinggal
- Cross-reference `\ref{sec:attackSimulation}` yang perlu di-update
- Term "simulasi serangan" di prosa biasa

### Checklist verifikasi setelah C1 sampai C8

- [ ] Tidak ada lagi kata "attack simulation" di seluruh Bab 6
- [ ] Tabel 6.1 menampilkan 5 lapisan dengan lapisan ke-5 = Fuzzing dan Invariant Testing
- [ ] Distribusi test case akurat berdasarkan jumlah dari `forge test --list`
- [ ] Cross-reference label valid (tidak ada `??` saat compile PDF)
- [ ] Compile PDF sukses tanpa warning citation undefined

---

## Bagian D. Estimasi waktu

| Tugas | Estimasi |
|---|---|
| A1 Deploy script role separation | 1 jam |
| A2 MultiSig threshold via env | 30 menit |
| A3 PropertyToken pauser mechanism | 2 jam (kode + test) |
| A4 Factory Ownable to AccessControl | 3 jam (kode + test refactor) |
| A5 (skip) | - |
| A6 Fuzz dan Invariant test layer (kode) | 4 jam |
| Verifikasi A1 sampai A4 dan A6 | 1 jam |
| B1 §4.4.1 KYCRegistry update | 1 jam |
| B2 §4.4.2 PropertyToken update | 1 jam |
| B3 §4.4.3 Factory update | 30 menit |
| B4 §4.4.4 PropertyRegistry update | 30 menit |
| B5 §4.4.5 Governance rewrite signifikan | 2 jam |
| B6 Justifikasi upgradeability dengan contoh regulasi | 30 menit |
| B7 Cross-reference cleanup | 30 menit |
| C1-C6 Bab 6 rewrite (terminologi + tabel + section) | 1.5 jam |
| C7 Bab 6 isi konten section Fuzzing | 1 jam (setelah hasil fuzz tersedia) |
| C8 Konsistensi referensi internal | 30 menit |
| Compile PDF dan verifikasi | 30 menit |
| **Total** | **20 jam** (2.5 hari kerja) |

Saran urutan eksekusi:
1. **Pagi**: kode A1 sampai A4 (refactor governance) — pondasi pasti
2. **Siang**: kode A6 (fuzz/invariant) — supaya angka untuk Bab 6 tersedia
3. **Sore**: tulisan B (Bab 4) — paralel dengan kode kalau ada partner
4. **Hari berikutnya**: rewrite Bab 6 (C1 sampai C8) — terakhir karena bergantung pada hasil A6

Kalau waktu mepet, prioritas:
- Kritis: A1, A3 (governance refactor), B5 (governance rewrite)
- Penting: A6 (fuzz layer), C1-C6 (terminologi Bab 6 minimal supaya konsisten dengan Bab 1-3)
- Tunda: B6 contoh regulasi (bisa belakangan), C7 isi konten Bab 6 fuzz (bisa setelah hasil terkumpul)

---

## Bagian E. Hal yang TIDAK dikerjakan besok

- Diagram kontrak (Contract Diagram per modul)
- Sequence diagram (Inisialisasi, Deploy Token, Transfer, Governance Upgrade)
- Bab 5 (Implementasi) yang masih TODO semua
- Bab 6 isi konten unit testing dan integration testing (yang masih TODO `% TODO: 92 test case, distribusi per kontrak` dll)
- Justifikasi pilihan ERC-20 di Bab 1 atau Bab 2 (sudah selesai sebelumnya)
- Penambahan referensi baru di luar `grieco2020echidna` (sudah ditambah)

---

## Catatan referensi

Sitasi yang sudah ada dan relevan untuk Bab 4 update:
- `eip3643`, `tokeny2023`, `onchainid2024`, `quicknode2024erc3643`, `globaltokenize2026` (untuk identity provider)
- `fatf2021` (untuk KYC off-chain dan approved contracts)
- `aave2023guardian`, `aave2023governance`, `aave2023pool` (untuk multi-tier governance)
- `eip1822`, `eip1967`, `eip7201` (untuk proxy patterns)
- `openzeppelin2024` (untuk best practices)
- `wang2025uncovering` (untuk risiko upgradeable contracts)
- `eip1153` (untuk transient storage)
- `chen2017under`, `brandstatter2020characterizing`, `albert2020gasol` (untuk gas analysis)
- `ojk2024pojk27`, `pp2025perizinan` (untuk regulasi Indonesia)

Sitasi yang sudah ada dan relevan untuk Bab 2/3/6 fuzzing layer:
- `grieco2020echidna` (Echidna fuzzer, sudah ditambah ke bib)
- `foundry2024` (Foundry tooling, sudah ada)
- `ren2021empirical` (empirical study testing methods, sudah ada)
- `wang2025uncovering` (untuk mapping fuzz/invariant ke risiko upgradeable)
- `myers2011art` (untuk konsep testing umum)

Jangan tambah referensi baru kecuali benar-benar perlu dan ada sumber primernya.
