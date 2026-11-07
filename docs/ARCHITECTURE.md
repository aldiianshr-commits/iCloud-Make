# Arsitektur teknis

## Lapisan

| Lapisan | Folder | Tanggung jawab |
|---|---|---|
| UI | `UI/` | SwiftUI. Tidak memanggil HTTP langsung; hanya lewat service. iPhone = `TabView`, iPad = `NavigationSplitView` (dipilih dari `horizontalSizeClass`). |
| Business logic | `Transfer/`, `Backup/`, `Storage/`, `Providers/AccountManager.swift` | Antrean transfer, backup/restore, indeks, analisis, sinkron. `@MainActor` service yang diinjeksi lewat `AppEnvironment`. |
| Cloud provider adapter | `Providers/` | Protokol `CloudProvider`; `GoogleDriveProvider` (API resmi) dan `TeraBoxProvider` (eksperimental). Provider baru cukup mengimplementasikan protokol ini. |
| Authentication | `Auth/` | Google: OAuth 2.0 *installed app* dengan PKCE di `ASWebAuthenticationSession` (sesi ephemeral agar tiap akun bisa dipilih). TeraBox: `WKWebView` dengan `WKWebsiteDataStore(forIdentifier:)` per akun. |
| Security | `Security/` | Keychain, Face ID/kode sandi (`LAPolicy.deviceOwnerAuthentication`), enkripsi file CryptoKit, kunci pemulihan. |
| Storage/Database | `Database/` | SwiftData (SQLite + WAL) dengan Data Protection; semua mutasi memanggil `save()` eksplisit. |
| Konfigurasi | `Config/` (+ `/Config/*.xcconfig`) | Konfigurasi developer dari xcconfig → Info.plist → `AppConfig`. Pengaturan pengguna ada di `Core/AppSettings.swift` (UserDefaults) dan tidak tercampur. |

## Model data (SwiftData)

- `CloudAccount` — provider, nama, email, peran (utama/cadangan/normal), aktif, status, kuota (total/terpakai/sampah), aktivitas terakhir.
- `RemoteFileRecord` — indeks metadata file/folder per akun (kunci unik `akun|id`).
- `TransferRecord` — antrean & riwayat upload/download/copy/move, termasuk URL sesi resumable Google.
- `BackupRun` — riwayat pencadangan (jumlah item, terverifikasi, gagal, terhapus terdeteksi, manifest).
- `BackupEntry` — satu item yang pernah dicadangkan: sidik jari, ID remote, MD5, terenkripsi, `deletedAt`. Dasar backup inkremental dan restore.
- `ActivityItem`, `ProtectedFolder`, `SyncPair`, `BackupFolderSource` (bookmark security-scoped), `BackgroundJobRecord`.

Konsistensi saat aplikasi ditutup paksa: SQLite WAL + simpan eksplisit; saat diluncurkan ulang transfer berstatus *running* dikembalikan ke antrean dan run backup yang terputus ditutup sebagai *cancelled* (run berikutnya inkremental).

## Google Drive

- Endpoint: `drive/v3/about`, `files` (list/get/create/update/copy/delete, `q` untuk pencarian), `files/{id}/export` (Google Docs → docx/xlsx/pptx/pdf), `files/trash`, `revisions`, `changes` (sinkron indeks inkremental), `upload/drive/v3/files?uploadType=resumable`.
- Upload: sesi resumable, potongan 8 MiB (kelipatan 256 KiB), URL sesi disimpan di `TransferRecord` sehingga upload berlanjut setelah gangguan/relaunch; status offset ditanyakan dengan `Content-Range: bytes */N`.
- Verifikasi: `md5Checksum` dari server dibandingkan dengan MD5 lokal setelah upload dan setelah download.
- Token: access token disegarkan otomatis (serialisasi per akun di `GoogleTokenStore` actor), `invalid_grant` → status "login kedaluwarsa". Hapus akun → `oauth2.googleapis.com/revoke`.

## TeraBox

Lihat [TERABOX.md](TERABOX.md).

## Transfer engine

`TransferManager` memakai dua semaphore (global sesuai pengaturan + per akun sesuai `maxConcurrentTransfers` provider). Semua file sumber disalin dulu ke *Outbox* di Application Support supaya antrean bertahan setelah relaunch. Retry eksponensial untuk error sementara (jaringan, 429, 5xx). Pause membatalkan task; resume memakai sesi resumable (Drive) atau mengulang blok yang dibutuhkan (TeraBox). Unduhan Google Drive ≥ 20 MB memakai background `URLSession` sehingga tetap berjalan saat aplikasi di latar belakang.

## Backup engine

1. Pilih akun tujuan (`AccountManager.pickAccount`).
2. Untuk tiap kategori: minta izin, enumerasi item (`BackupSource`), hitung rencana (`BackupEngine.plan`, fungsi murni yang diuji): lewati item yang sidik jarinya sama di akun yang sama, tandai item yang hilang dari perangkat (tidak menghapus salinan cloud).
3. Ekspor → (enkripsi opsional) → upload → verifikasi → simpan `BackupEntry`.
4. Tulis manifest JSON ke `iCloud IPA Backup/<perangkat>/Manifests/` untuk restore di perangkat baru.

Struktur di cloud:

```
iCloud IPA Backup/
└── <nama perangkat>/
    ├── Photos/<tahun>/<bulan>/<yyyyMMdd-HHmmss>_<nama asli>
    ├── Videos/…
    ├── Contacts/contacts_<tanggal>.vcf
    ├── Calendar/calendar_<tanggal>.json + .ics
    ├── Reminders/reminders_<tanggal>.json + .ics
    ├── Documents|Audio|Files/<folder yang dipilih>/<struktur asli>
    ├── AppData/appdata_<tanggal>.json
    └── Manifests/manifest_<tanggal>.json
```

Penjadwalan: `BGProcessingTaskRequest` (butuh jaringan, opsional saat mengisi daya) + `BGAppRefreshTaskRequest`, dengan `earliestBeginDate` dari jadwal. Status tiap tugas disimpan di `BackgroundJobRecord` dan ditampilkan di layar Backup. Jika iOS belum menjalankannya, backup yang terlambat dimulai saat aplikasi aktif.

## Restore

Unduh → verifikasi MD5/ukuran → dekripsi bila perlu → terapkan:
foto/video ke perpustakaan Foto (`PHAssetCreationRequest`), kontak (`CNSaveRequest`, dedup berdasarkan nama+telepon+email), kalender/pengingat (EventKit, dedup judul+waktu), file ke `Documents/Restored/<kategori>/…` (dedup SHA-256). Kebijakan konflik: lewati duplikat atau simpan keduanya.

## Enkripsi

Format `ICIPAENC` v1: header (magic, versi, ukuran potongan) lalu potongan AES-256-GCM 1 MiB. AAD tiap potongan = header + indeks + bendera potongan terakhir, sehingga penukaran urutan, penghapusan potongan, atau pemotongan file terdeteksi. File terenkripsi diberi akhiran `.icipaenc` di cloud dan didekripsi otomatis saat diunduh/dipulihkan.

## Pengujian

- Unit: enkripsi (round-trip, kunci salah, manipulasi, pemotongan), kunci pemulihan, hashing (vektor uji), PKCE (vektor RFC 7636), parsing respons Drive/TeraBox, pemetaan error, retry, perencanaan backup, jadwal, ICS, analyzer, ZIP (termasuk *zip slip*), state machine kunci aplikasi, lokalisasi.
- Integrasi: SwiftData in-memory + `MockProvider` — upload terverifikasi & deteksi korupsi, antrean + retry, salin/pindah antar-akun, pemilihan akun otomatis, backup inkremental + manifest + impor di "perangkat baru" + verifikasi, restore, hapus akun.
- Live (opsional, butuh secret): Google Drive round-trip 9 MB resumable; TeraBox kuota + list.
- Layout: build untuk simulator iPhone dan iPad + screenshot di CI.
