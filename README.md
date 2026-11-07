# iCloud IPA

Aplikasi native iOS/iPadOS (Swift, SwiftUI, SwiftData) untuk **penyimpanan cloud dan backup pribadi** yang memakai **Google Drive** dan **TeraBox** sebagai penyimpanan, dengan banyak akun sekaligus, file manager universal, backup otomatis, restore, Face ID, dan enkripsi di perangkat.

> Nama "iCloud" adalah merek Apple. Untuk distribusi di App Store, nama aplikasi kemungkinan besar harus diganti (App Review menolak nama yang memakai merek Apple). Untuk pemakaian pribadi/sideload tidak masalah.

## Status integrasi (jujur)

| Bagian | Status | Catatan |
|---|---|---|
| Google Drive | **API resmi** (Drive API v3 + OAuth 2.0 PKCE) | Butuh *iOS OAuth Client ID* milikmu — lihat [Setup Google Drive](#setup-google-drive). Diuji otomatis dengan respons tiruan; uji langsung berjalan bila secret tersedia. |
| TeraBox | **Eksperimental** | TeraBox tidak menyediakan API publik (Open Platform hanya untuk mitra). Adapter memakai endpoint web TeraBox dengan sesi hasil login kamu sendiri di situs resmi (WebView). Belum diverifikasi dengan akun nyata dari lingkungan build. Lihat [docs/TERABOX.md](docs/TERABOX.md). |
| Backup data iPhone | Sebatas izin iOS | Foto, Video, Kontak, Kalender, Pengingat, file dari folder yang kamu pilih (Dokumen/Audio/File), data aplikasi ini. **Bukan** backup sistem penuh dan **bukan** data privat aplikasi lain — tidak ada aplikasi App Store yang bisa. |
| Backup otomatis | BackgroundTasks | iOS yang menentukan kapan tugas latar belakang jalan. Jika terlambat, backup dimulai saat aplikasi dibuka. |
| File Provider (muncul sebagai lokasi di app Files) | Tidak dibuat di v1 | Butuh App Group + target ekstensi yang wajib ditandatangani akun developer; build tanpa tanda tangan tidak bisa memuatnya. File unduhan/restore tetap terlihat di *Files ▸ Di iPhone Saya ▸ iCloud IPA*. |
| RAR | Tidak didukung | Tidak ada library ekstraksi RAR dengan lisensi yang kompatibel. ZIP dan IPA (zip) didukung penuh. |

## Fitur

- **Multi-account**: banyak akun Google Drive dan TeraBox; akun aktif, akun **Utama** dan **Cadangan (fallback)**, status koneksi, kapasitas per akun, aktivitas terakhir, hapus akun (token dicabut + data lokal dibersihkan).
- **Pemilihan penyimpanan otomatis**: unggahan/backup ke akun Utama selama muat, lalu akun Cadangan, lalu akun dengan ruang kosong terbanyak. Kapasitas tidak pernah dijumlah sebagai satu penyimpanan fisik.
- **File manager**: grid/list, folder & subfolder, pratinjau (QuickLook), cari, urut, filter jenis, ganti nama, salin, pindah (termasuk **antar-akun**), hapus ke sampah, unggah, unduh, Share Sheet, ZIP & ekstrak, info file (ukuran, tanggal, lokasi, MD5), riwayat versi (Google Drive), folder terkunci Face ID.
- **Transfer engine**: antrean upload/download persisten, paralel sesuai batas provider, progres, retry eksponensial, pause/resume, resumable upload Google Drive (dilanjutkan setelah aplikasi ditutup), unduhan besar lewat *background URLSession*, verifikasi integritas (MD5 Drive / ukuran TeraBox), riwayat.
- **Backup**: penuh & inkremental, manual & terjadwal (harian/mingguan, jam pilihan, Wi-Fi saja, saat mengisi daya), deteksi file baru/berubah/terhapus, verifikasi, riwayat, manifest di cloud untuk restore di perangkat baru.
- **Restore**: semua/kategori/item tertentu, pratinjau sebelum restore, deteksi konflik & duplikat, pemeriksaan integritas, konfirmasi.
- **Penyimpanan**: dashboard kapasitas, penggunaan per jenis (Swift Charts), detektor duplikat, file besar, baru ditambahkan/diunggah, sampah (pulihkan/kosongkan), saran optimasi, sinkron folder satu arah antar-akun.
- **Keamanan**: Face ID dengan fallback kode sandi, Keychain untuk semua token/sesi, tidak menyimpan kata sandi, enkripsi AES-256-GCM (CryptoKit) sebelum unggah, kunci pemulihan, database lokal dilindungi Data Protection iOS.
- **Bahasa**: Bahasa Indonesia & English (bisa diganti di dalam aplikasi).
- **iPad**: sidebar (NavigationSplitView); iPhone: tab bar.

## Arsitektur

```
iCloudIPA/
├── App/          composition root (AppEnvironment), App + AppDelegate
├── Config/       AppConfig — konfigurasi developer dari xcconfig (terpisah dari pengaturan pengguna)
├── Core/         lokalisasi, AppSettings (pengaturan pengguna), utilitas, hashing, retry
├── Database/     model SwiftData + DataStore
├── Security/     Keychain, AppLock (Face ID), FileEncryptor (CryptoKit), KeyManager
├── Auth/         Google OAuth (ASWebAuthenticationSession + PKCE), login web TeraBox (WKWebView)
├── Providers/    CloudProvider (kontrak adapter), GoogleDriveProvider, TeraBoxProvider, AccountManager, HTTP
├── Transfer/     TransferManager (antrean), BackgroundTransferService (background URLSession)
├── Backup/       sumber data, BackupEngine, BackupScheduler (BGTaskScheduler), RestoreEngine, ICSWriter
├── Storage/      indexer, analyzer, ZIP, sync antar-akun
├── UI/           Home, Files, Backup, Accounts, Settings, Components
└── Resources/    Info.plist, aset, id/en Localizable.strings, PrivacyInfo.xcprivacy
iCloudIPATests/   unit test, integration test (provider tiruan), live test (dilewati tanpa kredensial)
```

Detail teknis: [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Build

Persyaratan: macOS dengan Xcode 16 atau lebih baru, [XcodeGen](https://github.com/yonaskolb/XcodeGen). Target: iOS/iPadOS 17.0+, arm64.

```bash
brew install xcodegen
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig   # isi Google client ID (opsional)
xcodegen generate
open iCloudIPA.xcodeproj
```

### CI (GitHub Actions)

`.github/workflows/ios.yml` berjalan di setiap push ke `main`:

1. generate proyek (XcodeGen) dan resolve Swift Package (ZIPFoundation),
2. unit + integration test di simulator iPhone,
3. build untuk simulator iPad,
4. build **Release arm64 untuk perangkat** (tanpa tanda tangan) → `iCloud IPA.app` → paket **`iCloud IPA.ipa`**,
5. `xcodebuild archive` → **`iCloud IPA.xcarchive`**,
6. unggah artefak: `iCloud-IPA-unsigned-ipa`, `iCloud-IPA-build-products` (app, xcarchive, proyek Xcode hasil generate, screenshot), `test-results`.

Log ringkas setiap run juga ditulis ke branch `ci-logs`.

### Tentang IPA

IPA dari CI **tidak ditandatangani**, karena penandatanganan memerlukan sertifikat dan provisioning profile dari akun Apple milikmu. Cara memasangnya di iPhone/iPad:

- **Sideload** dengan Apple ID-mu sendiri (mis. Sideloadly, AltStore) — mereka menandatangani ulang IPA saat memasang. Batas akun gratis: berlaku 7 hari.
- **Distribusi resmi** (TestFlight/App Store): buka `iCloud IPA.xcarchive` di Xcode Organizer atau jalankan
  `xcodebuild -exportArchive -archivePath "iCloud IPA.xcarchive" -exportOptionsPlist Config/ExportOptions-AppStore.plist -exportPath out`
  dengan `DEVELOPMENT_TEAM` diisi dan sertifikat distribusi terpasang.

## Setup Google Drive

1. Buka [Google Cloud Console](https://console.cloud.google.com/), buat proyek, aktifkan **Google Drive API**.
2. *OAuth consent screen*: tipe External, tambahkan scope `.../auth/drive`, tambahkan akunmu sebagai **Test user** (mode Testing cukup untuk pemakaian pribadi; scope `drive` adalah *restricted* sehingga publikasi umum memerlukan verifikasi Google).
3. *Credentials ▸ Create credentials ▸ OAuth client ID ▸ iOS*, Bundle ID: `com.aldiianshr.icloudipa`.
4. Salin Client ID ke `Config/Secrets.xcconfig` (lokal) **atau** simpan sebagai secret repo `GOOGLE_IOS_CLIENT_ID` agar CI memasukkannya ke IPA.

Tanpa langkah ini aplikasi tetap berjalan; tombol "Tambah akun Google Drive" dinonaktifkan dengan penjelasan.

### Live test opsional (secret GitHub)

| Secret | Untuk |
|---|---|
| `GOOGLE_IOS_CLIENT_ID` | Client ID ke dalam build + live test |
| `GOOGLE_TEST_REFRESH_TOKEN` | Refresh token akun uji → `LiveGoogleDriveTests` (buat folder, unggah 9 MB resumable, verifikasi MD5, unduh, hapus) |
| `TERABOX_TEST_NDUS` | Cookie sesi akun uji TeraBox → `LiveTeraBoxTests` |

Tanpa secret, test live ditandai **skipped**, tidak dianggap lulus.

## Privasi

- Token Google dan sesi TeraBox hanya di **Keychain** (`AfterFirstUnlockThisDeviceOnly`). Kata sandi tidak pernah dilihat atau disimpan.
- Menghapus akun: token Google dicabut di server Google, sesi TeraBox di-logout, data WebKit akun itu, entri Keychain, indeks dan status lokal dihapus.
- Enkripsi opsional: AES-256-GCM per potongan 1 MiB; kunci ada di Keychain dan bisa diekspor sebagai **kunci pemulihan** (dibutuhkan untuk restore di perangkat lain).
