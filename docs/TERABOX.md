# Integrasi TeraBox — status dan batasan

**Status: eksperimental.**

## Mengapa tidak memakai API resmi?

TeraBox memiliki "Open Platform" (`terabox.com/integrations`), tetapi akses API-nya diberikan kepada mitra yang mendaftar dan disetujui; tidak ada pendaftaran aplikasi mandiri dengan dokumentasi publik yang bisa diverifikasi saat proyek ini dibuat. Karena itu tidak ada `appkey`/`secret` resmi yang bisa dipakai di build ini.

Jika kamu mendapatkan akses Open Platform, buat adapter baru yang mengimplementasikan `CloudProvider` — seluruh UI, transfer, backup, dan restore akan langsung memakainya tanpa perubahan lain.

## Cara kerja adapter saat ini

1. **Login**: layar "Tambah akun TeraBox" membuka situs resmi `https://www.terabox.com` di `WKWebView`. Kamu login sendiri (email/kata sandi, Google, Apple, dll.). Aplikasi **tidak pernah** membaca kata sandi atau mengisi formulir.
2. Setiap akun memakai penyimpanan WebKit terpisah (`WKWebsiteDataStore(forIdentifier:)`), jadi beberapa akun TeraBox tidak berbagi cookie.
3. Setelah TeraBox membuat cookie sesi (`ndus`), aplikasi menyimpan cookie domain TeraBox, User-Agent, dan token halaman (`jsToken`, `bdstoken`) di **Keychain**.
4. Panggilan memakai endpoint yang sama dengan klien web TeraBox:

| Fungsi | Endpoint |
|---|---|
| Info akun | `GET /passport/get_info`, `GET /api/gettemplatevariable` |
| Kapasitas | `GET /api/quota` |
| Daftar folder | `GET /api/list` |
| Cari | `GET /api/search` |
| Buat folder | `POST /api/create` (`isdir=1`) |
| Ganti nama / pindah / salin / hapus | `POST /api/filemanager?opera=rename|move|copy|delete` |
| Unggah | `POST /api/precreate` → `POST https://<host>/rest/2.0/pcs/superfile2?method=upload` (blok 4 MiB, MD5 per blok dicocokkan) → `POST /api/create` |
| Unduh | `GET /api/filemetas?dlink=1` → unduh `dlink` |
| Sampah | `GET /api/recycle/list`, `POST /api/recycle/restore`, `POST /api/recycle/clear` |
| Logout | `GET /passport/logout` |

Setiap respons diperiksa (`errno`); error dipetakan ke pesan yang jelas (sesi kedaluwarsa, file tidak ada, ruang penuh). Bila token halaman berganti, adapter mengambil ulang dari `/main` satu kali sebelum menganggap sesi habis.

## Batasan yang perlu kamu ketahui

- Endpoint web bukan kontrak publik; TeraBox bisa mengubahnya kapan saja. Jika itu terjadi, status akun berubah menjadi *Error*/*Login kedaluwarsa* dan pesan error asli ditampilkan — tidak ada keberhasilan palsu.
- Penggunaan endpoint web oleh aplikasi pihak ketiga mungkin tidak sesuai Ketentuan Layanan TeraBox. Gunakan dengan akunmu sendiri dan risikomu sendiri.
- Verifikasi upload memakai ukuran file (field `md5` TeraBox tidak selalu berupa MD5 biasa) + MD5 per blok yang dikembalikan server saat unggah.
- Tidak ada riwayat versi file dan tidak ada feed perubahan; indeks TeraBox dipindai ulang penuh.
- Belum diuji dengan akun TeraBox nyata dari lingkungan pembuatan. Untuk menguji otomatis, isi secret `TERABOX_TEST_NDUS` (cookie `ndus` akun uji) → `LiveTeraBoxTests`.
