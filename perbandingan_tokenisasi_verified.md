**Perbandingan Platform Tokenisasi Real Estate**

RealT  ·  Lofty.ai  ·  Brickken  ·  Fraction  ·  ADDX

**Tabel 1.4 — Ringkas: Dimensi Utama per Platform**

| Dimensi | RealT (AS) | Lofty.ai (AS) | Brickken (EU) | Fraction (Thailand) | ADDX (Singapura) |
| ----- | ----- | ----- | ----- | ----- | ----- |
| **Pemegang Aset** | Series LLC (Delaware) — tiap properti \= seri terpisah | Wyoming DAO LLC — tiap properti \= entitas tersendiri | SPV / Trust — struktur fleksibel per penerbit | Trustee pihak ketiga berlisensi (wali amanat independen) | Kustodian institusional berlisensi (segregasi dana absolut) |
| **Token Mewakili** | Fraksi ekuitas / keanggotaan langsung dalam LLC | Saham fraksional ekuitas LLC \+ hak voting governance DAO | Hak hukum atas ekuitas, arus kas hutang, atau pendapatan SPV | Hak klaim dividen & nilai ekonomi properti proporsional | Sekuritas digital / unit dana investasi (Capital Markets Product) |
| **Standar Token** | ERC-20 termodifikasi (Ethereum \+ Gnosis Chain) | Algorand Standard Asset (ASA) | ERC-3643 (T-REX) \+ ERC-7943 | NFT/Token berbasis permissioned blockchain (modifikasi Ethereum) | Smart contract EVM pada private permissioned blockchain |
| **Blockchain** | Publik: Ethereum & Gnosis Chain | Publik: Algorand | Publik-Privat: EVM / Ethereum | Terkendali: Ethereum (Permissioned) | Blockchain Permissioned Privat (EVM-compatible) |
| **Secondary Market** | YAM (P2P internal) \+ Levinswap (DEX Gnosis) \+ Swapcat; whitelist wajib | P2P Order Book Internal — limit orders, penyelesaian instan via smart contract | CEX/DEX berbasis izin untuk investor whitelist | Pialang aset digital berlisensi lokal atau bursa internal platform | Bursa institusional internal (RMO ADDX) — order book berlisensi |
| **Min. Investasi** | \~$50/token di primary; bebas di secondary | $50 per token | Variabel per penerbit; historis \~€100 | \~$1–$150 tergantung struktur aset | USD 10.000 (per press release resmi); beberapa produk mulai USD 5.000 |
| **Target Investor** | Global: AS (Reg D Accredited) \+ internasional (Reg S) | Ritel global wajib KYC/AML; AS dan internasional | Ritel menengah & klien institusional global (selaras EU) | Ritel lokal Thailand (dulu ada batas 300.000 THB, kini dicabut 2024\) | Eksklusif Accredited Investors & institusi; non-AS saja |
| **Regulasi** | SEC AS (Reg D / Reg S) | SEC AS (Investment Contracts / Howey Test) | Hukum sekuritas UE & MiCA | SEC Thailand (Lisensi ICO Portal) | MAS Singapura (RMO \+ CMS) |
| **Return Investor** | Sewa mingguan (stablecoin USDC/DAI) \+ capital gain | Payout sewa harian \+ capital gain dari penjualan ekuitas | Dividen periodik, bunga+pokok hutang, atau capital gain | Sewa/bagi hasil komersial bulanan \+ profit penjualan aset | Distribution yield berkala (misal target 7%/thn) \+ gain saat exit event |

*Sumber: RealT FAQ, Lofty YCombinator/Algorand Case Study, Brickken blog, Fraction SEC Thailand, ADDX press release & Growbeansprout review. Diverifikasi Februari 2026\.*

**Tabel 1.5 — Detail per Platform: 5 Dimensi**

| Dimensi | RealT (AS) | Lofty.ai (AS) | Brickken (EU) | Fraction (Thailand) | ADDX (Singapura) |
| ----- | ----- | ----- | ----- | ----- | ----- |
| **A. Kepemilikan Legal** | Aset dipegang SPV Delaware Series LLC; tiap properti \= 1 seri terpisah (isolasi liabilitas penuh). Token \= ekuitas keanggotaan LLC. Penjualan disetujui mayoritas token, hasil distribusi proporsional via smart contract. | Aset dipegang Wyoming DAO LLC. Token \= fraksi ekuitas \+ hak voting governance DAO (1 token \= 1 suara, super-majority 60% untuk keputusan penting). Melville Law LLP sebagai administrator darurat jika platform bangkrut. | Aset ditempatkan di SPV atau Trust (agnostik struktur hukum). Token \= hak legal preskriptif (dividen, tagihan hutang, atau ekuitas SPV) yang diikat kontrak off-chain ke identitas on-chain. | Aset dikelola trustee pihak ketiga berlisensi independen — bukan platform. Token \= hak kepemilikan & finansial proporsional on-chain. Likuidasi dieksekusi oleh wali amanat. | Diklasifikasi sebagai Capital Markets Products (sekuritas digital). Dititipkan ke kustodian independen berlisensi dengan segregasi dana absolut. Distribusi pemulihan langsung ke investor via blockchain tanpa intervensi ADDX. |
| **B. Arsitektur Token** | ERC-20 termodifikasi di Ethereum \+ Gnosis Chain (untuk fee rendah). Whitelist on-chain wajib: transfer hanya valid jika pengirim & penerima terdaftar. KYC/AML wajib sebelum akses. | Algorand Standard Asset (ASA) di Algorand (finalitas instan, fee \~nol). KYC off-chain via platform, diverifikasi sebelum wallet diaktifkan. Transfer direstriksi ke wallet terverifikasi saja. | ERC-3643 (T-REX protocol) \+ pelopor ERC-7943 di ekosistem EVM. KYC terintegrasi on-chain. Minting, burning, blokir transfer, hingga forced transfer (perintah pengadilan) dikendalikan agen kepatuhan. | Permissioned blockchain berbasis Ethereum (dimodifikasi). Transfer dilarang untuk wallet tak teridentifikasi. KYC off-chain via penyedia identitas terakui bank sentral lokal, dipetakan ke whitelist on-chain. | Private permissioned blockchain (EVM-compatible, terpisah dari jaringan publik). KYC/AML dilakukan off-chain sebelum akses. Transfer token hanya antar investor terverifikasi. Berpartisipasi di Project Guardian MAS bersama ANZ & Chainlink. |
| **C. Pasar Sekunder & Likuiditas** | YAM (P2P internal, offer-based) \+ Levinswap DEX (Gnosis Chain, AMM) \+ Swapcat (limit order). Whitelist wajib di semua venue. Harga dipengaruhi supply-demand & nilai properti real. Total volume YAM \>$4,5 juta. | Marketplace P2P internal, sistem order book dengan limit orders, penyelesaian instan via smart contract. Tidak ada market maker institusional \= risiko likuiditas pada skenario jual massal. | Hanya investor tervalidasi (whitelist). Diperdagangkan via platform internal, CEX, atau DEX yang mendukung kepatuhan smart contract ERC-3643. Harga oleh supply-demand, sering ada program market maker institusional. | Difasilitasi melalui pialang aset digital berlisensi lokal atau bursa internal platform. Dalam praktik, likuiditas terbatas dan volume sering lesu setelah penawaran perdana. | Mesin pencocokan order book otomatis berlisensi (private exchange RMO). Investor terverifikasi bisa posting pesanan batas atas/bawah, penyelesaian seketika tanpa perantara. Harga murni supply-demand dalam ekosistem tertutup. |
| **D. Imbal Hasil & Distribusi** | Dua pilar: (1) Sewa rutin dikonversi ke USDC/DAI → distribusi mingguan langsung ke wallet. (2) Apresiasi nilai aset via reappraisal tahunan oleh penilai independen (naikkan NAV token). Yield historis 7–12%. | Payout sewa harian (akrual mikro, disalurkan otomatis ke portofolio setiap hari). Capital appreciation via penjualan token di marketplace atau saat DAO setujui penjualan fisik properti ke pihak ketiga. | Fleksibel: arus kas sewa, bunga+pokok hutang, atau capital gain. Distribusi via smart contract (stablecoin langsung ke wallet) sesuai jadwal: bulanan, kuartalan, atau pasca-penjualan aset. | Dividen kas dari sewa atau bagi hasil operasional komersial. Capital gain proporsional saat aset dilikuidasi. Frekuensi bulanan/triwulanan, dipercepat karena eliminasi perantara manual. | Bergantung instrumen: fund/REIT → distribution yield berkala. Contoh: Mapletree Europe Income Trust target yield 7%/tahun. Capital gain saat exit/likuidasi. Settlement efisien via blockchain. |
| **E. Regulasi & Akses** | Reg D (Accredited Investors AS) \+ Reg S (investor internasional non-AS). Diawasi SEC federal. Min. investasi: \~$50/token. Terbuka global non-AS via Reg S. | SEC AS (Howey Test / Investment Contracts). Min. investasi: $50/token. Terbuka investor AS dan global; wajib KYC. Tidak memerlukan status Accredited Investor. | Selaras regulasi sekuritas EU (MiCA, MiFID II). Min. investasi ditentukan penerbit; historis serendah €100. White-label platform, threshold fleksibel per proyek. | Lisensi ICO Portal SEC Thailand. Batas investasi ritel 300.000 THB di pasar primer sudah dicabut per 2024\. Min. investasi: \~$1–$150 tergantung struktur aset. | Lisensi ganda MAS Singapura: CMS \+ RMO. Eksklusif non-AS Accredited Investors (pendapatan ≥SGD 300.000/thn, atau net financial assets ≥SGD 1 juta, atau net personal assets ≥SGD 2 juta) & investor institusional. Min. investasi: USD 10.000. |

*Catatan: Klaim yang tidak dapat dikonfirmasi dari sumber publik telah dihapus atau diganti deskripsi generik yang akurat secara substansi. Regulasi dan fitur platform dapat berubah sewaktu-waktu.*

**Tabel 1.6 — Daftar Fitur per Platform (Terverifikasi)**

*v \= Ada/terkonfirmasi   x \= Tidak ada/tidak ditemukan   \! \= Terbatas/parsial. Hanya fitur yang dapat dikonfirmasi dari sumber publik yang dicantumkan.*

| Fitur | RealT (AS) | Lofty.ai (AS) | Brickken (EU) | Fraction (Thailand) | ADDX (Singapura) |
| ----- | ----- | ----- | ----- | ----- | ----- |
| **INVESTASI & AKSES** |  |  |  |  |  |
| **Min. investasi** | \~$50/token | $50/token | Variabel; historis \~€100 | \~$1–$150 | USD 10.000 |
| **Fiat on-ramp (kartu/bank)** | v (kartu kredit, Coinbase, ACH) | v (kartu kredit, ACH, wire) | v (fiat via gateway partner) | \! (tergantung pialang lokal) | v (bank transfer, termasuk DBS) |
| **Crypto on-ramp** | v (USDC, xDAI, WETH, dll) | v (ALGO, USDCa, STBL) | v (ETH, USDC, multi-chain) | \! (via pialang berlisensi) | x (fiat only ke rekening) |
| **Mode tanpa wallet (walletless)** | v (fitur walletless, fungsi terbatas) | v (wallet otomatis dibuat platform) | x (perlu wallet sendiri / MetaMask) | \! (wallet dikontrol platform) | v (custody penuh oleh ADDX) |
| **Self-custody wallet** | v (wallet pribadi Ethereum/Gnosis) | \! (wallet Algorand; likuiditas terbatas di luar platform) | v (wallet EVM sendiri) | x (wallet dikontrol platform) | x (non-transferable di luar ADDX) |
| **PENDAPATAN & DISTRIBUSI** |  |  |  |  |  |
| **Distribusi sewa otomatis** | v (mingguan, stablecoin USDC/DAI) | v (harian, akrual mikro otomatis) | v (terjadwal via smart contract, stablecoin) | v (bulanan/triwulanan, otomatis) | v (berkala sesuai instrumen; T+0 settlement) |
| **Frekuensi distribusi sewa** | Mingguan | Harian | Bulanan / Kuartalan / Custom | Bulanan / Triwulanan | Berkala (per fund/instrumen) |
| **Capital gain dari penjualan properti** | v | v (via governance vote DAO) | v | v | v (saat exit/likuidasi fund) |
| **Reappraisal / update valuasi token** | v (tahunan oleh penilai independen) | v (bulanan via HouseCanary AVM) | \! (tergantung penerbit/struktur) | \! (tidak terkonfirmasi frekuensinya) | \! (mengikuti NAV fund/instrumen) |
| **PASAR SEKUNDER & LIKUIDITAS** |  |  |  |  |  |
| **Pasar sekunder tersedia** | v | v | v | \! (ada, tapi likuiditas terbatas) | v |
| **Mekanisme pasar sekunder** | YAM (P2P offer), Levinswap DEX (AMM), Swapcat (limit order) | P2P Order Book internal (limit orders) | Platform internal, CEX/DEX whitelist-compatible | Pialang berlisensi lokal atau bursa internal platform | Order matching engine berlisensi (private exchange RMO) |
| **Trading 24/7** | v (DEX tidak pernah tutup) | v | \! (tergantung venue) | x (mengikuti jam bursa/pialang) | \! (platform ADDX; jam terbatas) |
| **Token bisa digunakan sebagai DeFi collateral** | v (RMM v3 berbasis AAVE, stablecoin loan) | v (Lofty Liquid, lending protokol Algorand) | x (sekuritas permissioned, tidak kompatibel DeFi publik) | x | x |
| **GOVERNANCE & MANAJEMEN** |  |  |  |  |  |
| **Hak voting pemegang token** | v (keputusan penjualan properti) | v (semua keputusan: PM, renovasi, penjualan; 60% supermajority) | \! (tergantung struktur token: equity token punya hak suara) | x (keputusan oleh trustee/platform) | x (dikelola fund manager profesional) |
| **Tata kelola DAO** | \! (vote terbatas pada penjualan aset) | v (Governance 2.0 on-chain; tiap properti \= DAO sendiri) | \! (BKN token untuk governance protokol, bukan properti individual) | x | x |
| **Manajemen properti oleh profesional** | v (property management company pihak ketiga) | v (PM pihak ketiga, dipilih oleh token holders via governance) | \! (tergantung penerbit aset) | v (dikelola trustee/operator) | v (fund manager institusional) |
| **Rent-to-own untuk penyewa** | x | v (penyewa bisa beli token properti yang mereka sewa) | x | x | x |
| **KEPATUHAN & KEAMANAN** |  |  |  |  |  |
| **KYC/AML wajib** | v | v | v | v | v |
| **Whitelist transfer on-chain** | v (smart contract whitelist wallet) | \! (restriksi via platform; tidak sepenuhnya on-chain) | v (ERC-3643, whitelist \+ forced transfer) | v (whitelist on-chain) | v (non-transferable di luar ekosistem ADDX) |
| **Dana investor terpisah (segregasi)** | \! (tiap LLC terpisah, tapi via RealT) | \! (Wyoming LLC per properti) | \! (tergantung struktur SPV penerbit) | v (wali amanat independen) | v (DBS custodian account, fully segregated) |
| **Perlindungan jika platform bangkrut** | \! (LLC tetap hidup, tapi governance jadi masalah) | v (Melville Law LLP otomatis ambil alih administrasi DAO) | \! (tergantung struktur SPV/trust per penerbit) | v (trustee independen tetap eksekusi likuidasi) | v (kustodian DBS independen dari operasi ADDX) |
| **Sertifikasi / audit keamanan** | \! (smart contract open source, belum ada sertifikasi publik) | \! (belum terkonfirmasi dari sumber publik) | \! (belum terkonfirmasi sertifikasi independen) | \! (under SEC Thailand oversight) | v (ISO/IEC 27001:2013 certified) |
| **FITUR PLATFORM & PENGALAMAN PENGGUNA** |  |  |  |  |  |
| **Aplikasi mobile** | \! (tersedia versi mobile web, belum ada app native) | \! (web mobile-friendly; belum ada native app) | \! (web app; tidak ada native mobile app) | \! (tidak terkonfirmasi dari sumber publik) | v (ADDX App tersedia iOS & Android) |
| **Dashboard portofolio investor** | v (detail valuasi & performa tiap properti) | v (track rent, token value, governance) | v (real-time dashboard \+ cap table management) | \! (tersedia melalui platform; detail tidak terkonfirmasi) | v (performance tracking \+ portfolio monitoring) |
| **White-label / API untuk pihak ketiga** | x (platform eksklusif RealT) | x (platform eksklusif Lofty) | v (white-label \+ API modular, core bisnis Brickken) | x | v (layanan wealth manager B2B) |
| **Dedicated account manager** | x | x | x | \! (tidak terkonfirmasi dari sumber publik) | v (terkonfirmasi dari ADDX website) |
| **Aset tersedia selain properti residensial** | \! (mayoritas residensial AS; ada beberapa komersial) | v (single-family, commercial strip mall, Airbnb, HELOC, lahan pertanian) | v (real estate, ekuitas, obligasi, IP, VC, dll.) | \! (properti komersial Thailand, resor/vila) | v (PE, hedge fund, private debt, pre-IPO, REIT) |

*Sumber: RealT (quicknode, alts.co, objectif-renta.com), Lofty (ycombinator.com, lofty.ai/help, moneywise.com), Brickken (brickken.com, brickken whitepaper), Fraction (belaws.com, SEC Thailand), ADDX (addx.co, MAS). Diverifikasi Februari 2026\.*

**Tabel 2.1 — Profil Lengkap GORO.id (Indonesia)**

*Sumber terverifikasi: blockchainmedia.id (Des 2024), kompas.com, wartaekonomi.co.id, topbusiness.id, jurnal.larisma.or.id (Apr 2025), siaran pers resmi GORO. Diverifikasi Februari 2026\.*

| Dimensi / Aspek | GORO.id (Indonesia) |
| ----- | ----- |
| **IDENTITAS PLATFORM** |  |
| **Nama Legal** | PT Teknologi Gotong Royong (platform teknologi) \+ PT Properti Gotong Royong (entitas properti) |
| **Co-founders** | Robert Hoving (Co-founder & CEO) \+ Andryan Gouw (Co-founder & CEO — keduanya tercantum dalam komunikasi resmi) |
| **Domisili & Yurisdiksi** | Indonesia (Jakarta) |
| **Status Regulasi** | Lulus Sandbox OJK (Nov 2025): Surat OJK S-527/IK.01/2025 (PT Teknologi Gotong Royong) & S-528/IK.01/2025 (PT Properti Gotong Royong). POJK No. 3 Tahun 2024 & SEOJK No. 5/SEOJK.07/2024. Pertama di Indonesia untuk kategori tokenisasi properti. |
| **Sertifikasi Keamanan** | ISO/IEC 27001:2013 (dikonfirmasi dari siaran pers resmi) |
| **Target pasar** | Investor ritel Indonesia dan diaspora global; \>100.000 pengguna dari 43 negara (per jurnal ECONOBIS Apr 2025\) |
| **MODEL KEPEMILIKAN LEGAL** |  |
| **Pemegang Aset** | Aset properti dikelola oleh PT Properti Gotong Royong sebagai entitas pemilik. Token tidak mewakili kepemilikan sertifikat tanah langsung, melainkan hak ekonomi proporsional (bagi hasil sewa) berbasis blockchain. |
| **Token Mewakili** | Porsi kepemilikan fraksional \= hak atas pembagian hasil sewa secara proporsional sesuai jumlah token yang dimiliki. |
| **Struktur Kepemilikan** | Seluruh transaksi dicatat on-chain (Polygon) dan dapat diverifikasi publik. Transaksi menggunakan Rupiah — token bukan instrumen kripto yang diperdagangkan, melainkan representasi digital hak ekonomi dalam ekosistem tertutup GORO. |
| **Mekanisme Likuidasi** | Investor dapat menjual kembali token melalui platform GORO. Mekanisme exit dan likuidasi aset fisik jika GORO bangkrut belum terpublikasi secara detail di sumber publik yang tersedia. |
| **ARSITEKTUR BLOCKCHAIN & TOKEN** |  |
| **Blockchain** | Polygon PoS (Ethereum sidechain/L2). Saat artikel Blockchainmedia.id Des 2024: masih di Polygon Amoy Testnet, sedang proses migrasi ke Polygon Mainnet. Sekarang sudah Mainnet |
| **Standar Token** | ERC-1155 (NFT semi-fungible). Setiap unit token \= Rp10.000. Tiap properti memiliki Token ID sendiri (contoh: Villa Bayu Seminyak \= Token ID 23, total 741.286 unit). |
| **Smart Contract** | Dapat dilihat & diverifikasi publik. Contoh kontrak: 0x4EF208Aa309D66444792ae7BF964B9904C7F2bFE |
| **Transferabilitas Token** | Tidak bebas, hanya dalam ekosistem platform GORO. Token bukan kripto yang dapat diperjualbelikan di exchange publik. KYC wajib melalui pendaftaran akun GORO. |
| **Verifikasi Transaksi** | On-chain di Polygon, dapat diverifikasi siapa saja melalui block explorer (OKLink/Polygonscan). Setiap transaksi investasi memiliki tx hash yang dapat dilacak publik. |
| **INVESTASI & IMBAL HASIL** |  |
| **Minimum Investasi** | Rp10.000 (ekuivalen \~$0,60). 1 token \= Rp10.000. |
| **Mata Uang Transaksi** | Rupiah (IDR) — bukan kripto. Token hanya representasi digital, bukan aset kripto yang volatile. |
| **Imbal Hasil** | Expected Rental Yield (ERY) hingga \~10–12%/tahun (bervariasi tiap properti). Simulasi: investasi Rp1.000.000 selama 5 tahun dengan ERY 11,99%/tahun \= return \~Rp599.500 (59 token). |
| **Frekuensi Distribusi** | Bulanan (pembagian hasil sewa setiap bulan) |
| **Jenis Properti** | Vila, apartemen, hotel, properti komersial. Contoh terkonfirmasi: Villa Bayu di Seminyak Bali, properti Jakarta. |
| **Nilai Aset Diuji (Sandbox)** | 7 properti dengan total nilai \~Rp42 miliar selama periode Sandbox OJK |
| **REGULASI & AKSES INVESTOR** |  |
| **Status Regulasi** | Lulus Sandbox OJK (November 2025). Belum memiliki izin usaha penuh (post-sandbox perlu proses lisensi resmi OJK). Tidak terdaftar sebagai efek/sekuritas di Bursa Efek Indonesia (BEI). |
| **Target Investor** | Investor ritel Indonesia; tidak terbatas Accredited Investor. Platform juga diakses dari luar negeri (\>43 negara), meski regulasi lintas batas belum terpublikasi detail. |
| **KYC/AML** | Wajib melalui pendaftaran akun GORO. Detail mekanisme teknis (off-chain/on-chain) tidak terpublikasi secara rinci di sumber publik. |
| **Perlindungan Konsumen** | Diwajibkan OJK selama Sandbox: tata kelola, manajemen risiko, keamanan informasi, perlindungan data pribadi (UU PDP). GORO dinyatakan lulus semua aspek tersebut. |
| **FITUR PLATFORM (TERVERIFIKASI)** |  |
| **Pasar Sekunder** | Ada — investor dapat menjual kembali token melalui platform GORO. Detail mekanisme (P2P/matching) tidak terpublikasi. |
| **Pertukaran Token Antar Properti** | Ada (terkonfirmasi dari jurnal ECONOBIS Apr 2025\) |
| **Dashboard / Monitoring** | Ada di website goro.id; investor dapat memantau kepemilikan token dan nilai portofolio. |
| **Aplikasi Mobile** | Tidak terkonfirmasi dari sumber publik yang tersedia. Website utama dapat diakses mobile. |
| **DeFi / Collateral** | Tidak tersedia — token bukan kripto publik, tidak kompatibel dengan protokol DeFi. |
| **Pengguna & Skala** | \>100.000 pengguna dari 43 negara; \>60% adalah investor pemula (first-time investor). |

*\! Status blockchain (mainnet/testnet per Feb 2026\) dan mekanisme perlindungan investor jika platform bangkrut belum terkonfirmasi dari sumber publik terbaru. Disarankan verifikasi langsung ke platform.*

**Tabel 2.2 — Perbandingan Proof-of-State / Mekanisme Konsensus Blockchain**

*Perbandingan teknis arsitektur blockchain: GORO (Polygon PoS) vs RealT (Ethereum \+ Gnosis) vs Fraction (Permissioned Ethereum) vs Brickken (Multi-chain: ETH \+ Polygon \+ BSC \+ Base). Hanya data yang terkonfirmasi dari dokumentasi teknis resmi yang dicantumkan.*

| Dimensi Konsensus | GORO.id(Polygon PoS) | RealT(Ethereum \+ Gnosis Chain) | Fraction (Thailand)(Permissioned Ethereum) | Brickken (EU)(Multi-Chain: ETH \+ Polygon \+ BSC \+ Base) |
| ----- | ----- | ----- | ----- | ----- |
| **IDENTITAS BLOCKCHAIN** |  |  |  |  |
| **Blockchain yang Digunakan** | Polygon PoS (sidechain Ethereum). Per Des 2024 masih di Polygon Amoy Testnet; sedang migrasi ke Mainnet. | Dua jaringan: (1) Ethereum Mainnet (token asli), (2) Gnosis Chain (distribusi sewa rutin, fee sangat murah). | Permissioned blockchain berbasis kode Ethereum (dimodifikasi/private). Bukan jaringan Ethereum publik. | Multi-chain: Ethereum Mainnet (awal), Polygon PoS (Mar 2025), BNB Smart Chain/BSC (Nov 2024), dan Base. Strategi multi-chain eksplisit untuk fleksibilitas penerbit aset. |
| **Tipe Jaringan** | Public permissionless — siapa saja bisa verifikasi. Token tidak bisa ditransfer bebas di luar ekosistem GORO. | Public permissionless. Ethereum \= fully decentralized; Gnosis Chain \= public PoS sidechain. | Private / Permissioned. Hanya node yang diotorisasi yang dapat berpartisipasi. | Public permissionless (semua chain yang didukung bersifat publik), namun token sekuritas ERC-3643 yang diterbitkan di atasnya bersifat permissioned (whitelist wajib per investor). |
| **Standar Token** | ERC-1155 (NFT semi-fungible). Setiap properti \= 1 Token ID; 1 unit \= Rp10.000. | ERC-20 termodifikasi (fungible; tiap properti \= token ERC-20 tersendiri \+ whitelist on-chain). | NFT/Token berbasis permissioned blockchain. Detail standar tidak terpublikasi. | ERC-3643 (T-REX — permissioned fungible security token) \+ pelopor ERC-7943 (modular compliance standard, co-authored Sep 2025). BKN utility token sendiri \= ERC-20 di Ethereum. |
| **MEKANISME KONSENSUS** |  |  |  |  |
| **Jenis Konsensus** | PoS — arsitektur dual-layer: Heimdall (konsensus berbasis CometBFT, upgrade Jul 2025\) \+ Bor (eksekusi blok berbasis Go-Ethereum/Geth). | Ethereum: Casper FFG \+ LMD-GHOST (PoS sejak The Merge Sep 2022). Gnosis Chain: Ethereum-equivalent PoS (berbasis Lighthouse/Nimbus client post-Merge 2022). | Tidak dipublikasikan. Permissioned blockchain umumnya menggunakan PBFT atau PoA — tidak diverifikasi untuk Fraction. | Bergantung chain yang dipilih penerbit aset:• Ethereum: Casper FFG \+ LMD-GHOST (PoS)• Polygon PoS: Heimdall \+ Bor (PoS dual-layer)• BSC: Proof of Staked Authority (PoSA \= hibrida DPoS \+ PoA)• Base: Optimistic Rollup (PoS Ethereum sebagai settlement layer) |
| **Cara Validator Dipilih** | Proporsional berdasarkan jumlah POL (dahulu MATIC) yang di-stake. Maks 105 validator aktif. Bor memilih block producer dari set validator secara acak tiap epoch. | Ethereum: pseudorandom dari pool via RANDAO; min. 32 ETH/validator. Gnosis: acak dari pool staker GNO; threshold 1 GNO per validator (sangat inklusif). | Tidak diketahui — ditentukan oleh operator platform. | Mengikuti mekanisme chain yang dipilih:• ETH: RANDAO, min. 32 ETH• Polygon: proporsional POL stake, maks 105 validator• BSC: top 45 BNB staker (21 Cabinet aktif \+ 24 Candidate), elected harian• Base: sequencer Optimism, final settlement ke Ethereum PoS |
| **Jumlah Validator Aktif** | Maks 105 validator aktif (cap protokol Polygon PoS). | Ethereum: \>1 juta validator (per 2025). Gnosis Chain: \~100.000+ validator. | Tidak diketahui — jaringan privat. | Per chain:• ETH: \>1 juta validator• Polygon: maks 105 validator• BSC: 45 aktif (21 Cabinet \+ 24 Candidate)• Base: 1 sequencer (Optimism Labs), dispute via fraud proof ke ETH |
| **Token Staking / Gas** | POL (menggantikan MATIC Sep 2024\) untuk staking dan gas. | ETH untuk staking+gas di Ethereum. xDAI (stablecoin) untuk gas di Gnosis; GNO untuk staking di Gnosis. | Tidak berlaku — jaringan privat. | Per chain: ETH (Ethereum), POL (Polygon), BNB (BSC), ETH (Base). Penerbit aset tidak perlu mengelola ini secara langsung — Brickken mengabstraksi infrastruktur gas. |
| **FINALITAS & KEAMANAN** |  |  |  |  |
| **Waktu Finalitas Transaksi** | \~2–5 detik finalitas praktis di Polygon. Checkpoint ke Ethereum setiap \~30 menit untuk finalitas penuh. | Ethereum: \~12 detik per blok; finalitas penuh \~12–15 menit. Gnosis: \~5 detik per blok. | Tidak diketahui. Permissioned blockchain umumnya 1–5 detik. | Per chain:• ETH: \~12–15 menit finalitas penuh• Polygon: \~2–5 detik praktis, \~30 mnt ke ETH• BSC: \~3 detik per blok; finalitas \~6 detik• Base: \~2 detik L2; finalitas ke ETH \~7 hari (optimistic) |
| **Ambang Keamanan Konsensus** | ≥2/3 dari total stake validator harus setuju untuk finalisasi blok dan checkpoint ke Ethereum. | Ethereum: ≥66% supermajority total ETH di-stake (Casper FFG). Gnosis: ≥2/3 stake GNO. | Tidak diketahui. | Per chain:• ETH & Polygon: ≥66% supermajority stake• BSC: ≥1/2 N+1 validator (PoA-style dari validator set terpilih)• Base: keamanan diwarisi dari Ethereum PoS |
| **Risiko Sentralisasi** | Sedang–Tinggi: konsentrasi stake tinggi di Polygon — top 12 validator bisa mengubah ledger (studi arxiv 2504.15449, 2025). Nakamoto coefficient Polygon termasuk rendah. | Ethereum: Risiko rendah (\>1 juta validator). Gnosis: Risiko rendah–sedang (100K+ validator, threshold 1 GNO sangat inklusif). | Sangat Tinggi — jaringan privat, validator ditentukan platform. | Bervariasi per chain:• ETH: Rendah• Polygon: Sedang–Tinggi (105 validator, konsentrasi stake tinggi)• BSC: Tinggi (hanya 45 validator; top holder \= Binance & institusi besar)• Base: Sangat Tinggi untuk L2 (1 sequencer \= Optimism Labs)Fleksibilitas multi-chain adalah nilai jual, tapi penerbit yang memilih BSC/Base menanggung risiko sentralisasi lebih besar. |
| **Verifikasi Publik** | v Publik — semua transaksi dapat dilihat di OKLink/Polygonscan. Smart contract GORO dapat diverifikasi siapa saja. | v Penuh — Ethereum Mainnet dan Gnosis Chain sepenuhnya transparan dan dapat diverifikasi siapa saja. | x Tidak publik — transaksi hanya terlihat di dalam jaringan yang diizinkan. | v Publik di semua chain yang didukung (ETH, Polygon, BSC, Base) — semua on-chain dan dapat diverifikasi. Namun transfer token ERC-3643 dibatasi oleh whitelist, bukan transparansi data. |
| **IMPLIKASI UNTUK INVESTOR PROPERTI** |  |  |  |  |
| **Kepercayaan pada Jaringan** | Bergantung pada Polygon Labs. Keamanan di-anchor ke Ethereum via checkpoint, namun tidak sepunuh rollup. | Tinggi: Ethereum adalah blockchain paling battle-tested. Distribusi sewa via Gnosis lebih murah namun jaminan keamanan lebih rendah dari mainnet. | Bergantung penuh pada operator platform Fraction — bukan trustless. | Bergantung pada pilihan chain penerbit. Penerbit yang memilih Ethereum mendapat keamanan tertinggi; yang memilih BSC menanggung risiko sentralisasi lebih besar. Investor perlu tahu di chain mana aset mereka di-tokenisasi. |
| **Biaya Transaksi (Gas Fee)** | Sangat murah: \~$0.003/transaksi di Polygon PoS. Cocok untuk investasi mikro Rp10.000. | Ethereum: mahal ($1–30+). Gnosis: sangat murah (\<$0.01) — itulah alasan RealT pakai Gnosis untuk distribusi sewa mingguan. | Tidak relevan — jaringan privat, tidak ada gas fee untuk pengguna. | Bervariasi per chain:• ETH: mahal ($1–30+)• Polygon & BSC: murah (\~$0.003–$0.01)• Base: sangat murah (\<$0.001)Brickken mengabstraksi biaya gas dari investor — penerbit yang menanggung. |
| **Transparansi Kepemilikan** | v On-chain publik. Siapa pun bisa verifikasi kepemilikan di Polygon block explorer. | v On-chain publik di Ethereum/Gnosis. Kepemilikan ERC-20 dapat diverifikasi siapa saja. | x Off-chain / permissioned chain. Tidak dapat diverifikasi publik. | v On-chain publik di chain yang dipilih. Cap table dan kepemilikan token dapat diverifikasi di block explorer chain masing-masing. |
| **Kesesuaian DeFi Publik** | x Token GORO tidak kompatibel DeFi publik (tidak diperdagangkan bebas). | v RealT token kompatibel DeFi — dapat digunakan sebagai kolateral di AAVE melalui RealT Market Maker (RMM v3). | x Tidak kompatibel — jaringan privat. | \! Terbatas: token ERC-3643 tidak kompatibel DeFi publik secara langsung (permissioned). Namun Brickken bermitra dengan Credefi (Jul 2025\) untuk memungkinkan DeFi lending terbatas untuk aset ERC-3643 di jaringan berlisensi. |

*Sumber: docs.polygon.technology, docs.bnbchain.org, ethereum.org/pos, brickken.com, ffnews.com (Mar 2025 – Brickken deploys on Polygon), cointelegraph.com (Nov 2024 – Brickken x BNB Chain), arxiv.org/2504.15449 (studi bridge Ethereum-Polygon Apr 2025), Gnosis Chain docs. Diverifikasi Februari 2026\.*

---

---

| Dimensi | Platform Kami (Base \+ ERC-20 \+ AMM) | GORO.id (Polygon \+ ERC-1155) | Keunggulan Kami |
| ----- | ----- | ----- | ----- |
| **ARSITEKTUR FUNDAMENTAL** |  |  |  |
| Peran Blockchain | Pembayaran, distribusi dividen, dan transfer token semua terjadi on-chain | **Hanya alat pencatatan kepemilikan** — semua aliran uang tetap via sistem  konvensional | Blockchain Anda benar-benar digunakan sebagai infrastruktur keuangan, bukan sekadar performatif. |
| Custody Wallet | Self-custody, investor memegang private key sendiri, token benar-benar milik mereka | **Custodial penuh** — wallet dikontrol GORO, investor memiliki akses langsung token di blockchain | Investor memiliki kontrol yang lebih bebeas terhadap asseet. |
| Jalur Pembayaran Beli | Crypto on-chain langsung ke smart contract | Transfer bank / e-wallet via **Xendit** (payment gateway) → GORO transfer token dari GORO ke user secara manual | Tidak ada perantara payment gateway yang bisa gagal atau diblokir |
| **TOKENISASI** |  |  |  |
| Standar Token | ERC-20 — fungible, tiap properti \= token sendiri | ERC-1155 (NFT semi-fungible) | ERC-20 kompatibel penuh DEX, wallet, dan berbagai DeFi. Memudahkan interoperabilitas |
| Blockchain | Base (L2 Ethereum) — Optimistic Rollup, settle ke Ethereum PoS, fee \<$0.001/tx | Polygon PoS Mainnet — 105 validator, checkpoint ke ETH tiap \~30 mnt | Base lebih murah dan keamanan akhirnya lebih kuat dari sidechain Polygon |
| Verifikasi On-chain | Kepemilikan & transfer tercatat di Basescan, dapat diverifikasi publik | Token tercatat di Polygonscan, tapi **wallet dipegang GORO** — investor tidak bisa verifikasi kepemilikan pribadi mereka secara independen | Verifikasi Anda benar-benar bermakna karena investor pegang wallet sendiri |
| **KYC & KEPATUHAN** |  |  |  |
| Mekanisme KYC | Off-chain KYC → whitelist wallet on-chain di smart contract | Off-chain KYC via pendaftaran akun GORO | Whitelist on-chain lebih transparan dan auditabel |
| Enforcement Transfer | Smart contract tolak transfer ke wallet tidak ada di whitelist. | Tidak relevan — token tidak bisa dipindah keluar ekosistem GORO sama sekali | Enforcement Anda berbasis kode, bukan kebijakan platform |
| **BAGI HASIL / DIVIDEN** |  |  |  |
| Mekanisme Distribusi | Smart contract distribusi **stablecoin on-chain** langsung ke wallet investor secara otomatis | GORO akumulasi dividen internal → **transfer manual ke rekening bank** investor setiap bulan paling lambat tanggal 21 | Distribusi Anda tidak bergantung pada proses admin manual, jam kerja bank, atau rekening bank investor |
| Mata Uang | Stablecoin IDR langsung ke crypto wallet | Rupiah ke rekening bank — mengikuti sistem perbankan, jam kerja, biaya admin Rp5.550 per penarikan | Stablecoin tidak memiliki biaya transfer, tidak ada hari libur, bisa diexchange langsung oleh investor global, mempermudah proses investtasi untuk luar indonesia |
| Frekuensi | Fleksibel — mingguan atau bulanan | Bulanan (akrual harian, dibayar akhir bulan) | Lebih fleksibel; distribusi lebih sering meningkatkan daya tarik investasi |
| **SHAREHOLDER VOTING** |  |  |  |
| Governance On-chain | Voting on-chain via smart contract — proporsional sesuai token, hasil permanen di blockchain | Tidak terkonfirmasi ada fitur voting | Fitur yang sama sekali tidak dimiliki GORO — investor punya suara nyata atas aset mereka, memungkinkan proses akuisisi jika ada tawaran yang menarik. |
| **JUAL BELI TOKEN (AMM)** |  |  |  |
| Mekanisme Pasar Sekunder | AMM di DEX ekosistem Base (Aerodrome, Uniswap V3) — swap langsung dari wallet, 24/7 | Jual via **platform GORO**, cair ke rekening bank dalam **3×24 jam**, minimum 6 token (Rp60.000), biaya admin Rp5.550 | DEX: instan, 24/7, tidak ada biaya admin tetap, tidak ada minimum jual, tidak perlu rekening bank |
| Kompatibilitas DEX | ERC-20 \+ whitelist → kompatibel Uniswap V3/Aerodrome di Base |  ERC-1155 custodial → **tidak bisa diperdagangkan di luar ekosistem GORO sama sekali** | Kompatibel dengan DEX lain |
| Price Discovery | Supply-demand organik di pool AMM | Tidak ada price discovery — harga ditentukan GORO berbasis NAV | Penentuan harga yang transparan dan natural. |
| **RISIKO & KETERBATASAN** |  |  |  |
| Sentralisasi Blockchain | Base: 1 sequencer,, ada fraud proof ke ETH | Polygon: 105 validator, konsentrasi stake tinggi | Setara — beda jenis risiko. Base punya jaminan akhir Ethereum PoS lebih kuat |
| Regulasi Indonesia | Belum ada lisensi OJK. Perlu sandbox | Lulus Sandbox OJK Nov 2025\. Distribusi Rupiah sesuai regulasi BI | **GORO unggul signifikan di sini.** Walupun GORO belum punya izin lanjutan. |

**1.5  Narasi Temuan**

**Pola yang Sama di Semua Platform**

Pertama, tidak ada platform yang mentokenisasi aset fisik langsung ke blockchain. Semua platform tanpa kecuali membentuk legal wrapper terlebih dahulu — baik melalui SPV/LLC (RealT dengan Delaware Series LLC, Lofty dengan Wyoming DAO LLC) maupun mekanisme Trustee independen (Fraction, Brickken). Entitas pengantara ini mengisolasi liabilitas properti dari risiko operasional platform dan menjamin kelangsungan klaim investor jika platform bangkrut.

Kedua, tidak ada ruang untuk anonimitas. Semua platform menjadikan KYC/AML sebagai gerbang masuk wajib, diprogram langsung ke arsitektur smart contract: whitelist wallet (RealT, Fraction), restriksi transfer berbasis verifikasi KYC off-chain (Lofty, ADDX), atau standar token permissioned khusus seperti ERC-3643 (Brickken). Tidak satu pun token sekuritas ini bisa dipindahkan bebas ke wallet anonim.

Ketiga, peran blockchain lebih sebagai mesin efisiensi operasional daripada desentralisasi murni. Fungsi utamanya adalah mengotomatiskan pencatatan kepemilikan dan distribusi arus kas — memungkinkan payout sewa harian (Lofty) atau mingguan (RealT) dalam stablecoin, yang mustahil dicapai sistem manajemen properti tradisional. Likuiditas pasar sekunder sangat bervariasi antar platform dan sering terhambat oleh sifat inheren aset fisik.

**Hal yang Berbeda Antar Platform**

Diferensiasi pertama: pilihan blockchain dan standar token. Platform yang mengutamakan transaksi mikro harian memilih Algorand (Lofty) karena finalitas instan dan fee mendekati nol. Platform yang mengutamakan kompatibilitas ekosistem DeFi luas memilih infrastruktur EVM (RealT, Brickken). ADDX memilih private permissioned blockchain demi keamanan tingkat perbankan.

Diferensiasi kedua: segmentasi investor. ADDX membangun model eksklusif untuk Accredited Investors dengan minimum USD 10.000 (dipangkas dari biasanya USD 1 juta). Sebaliknya, Lofty dan Fraction membuka partisipasi dari $1–$50 untuk mendorong inklusi finansial ritel.

Diferensiasi ketiga: mekanisme pembentukan harga sekunder. RealT menggunakan DEX berbasis AMM (Levinswap) yang transparan namun mengekspos harga token ke volatilitas kripto dasar. Lofty dengan P2P order book internal dan ADDX dengan sistem pencocokan tertutup secara sengaja mengisolasi harga dari volatilitas eksternal — memberikan stabilitas lebih besar namun dengan kedalaman likuiditas yang lebih terbatas.

*Semua data berdasarkan sumber publik yang terverifikasi. Diverifikasi Februari 2026\.*

