# MySQL Docker Manager

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Bash script untuk setup MySQL 8.4 LTS menggunakan Docker Compose dari nol,
kemudian mengelola database melalui menu interaktif.

Script mengelola satu instance MySQL dalam container Docker. Database dan
user baru dibuat di dalam instance yang sama.

## Fitur

-   Setup MySQL Docker dari nol (image resmi `mysql:8.4`).
-   SSL/TLS aktif dan **wajib** untuk semua koneksi TCP
    (`require_secure_transport=ON`), memakai sertifikat yang dibuat otomatis
    oleh MySQL.
-   `root` hanya bisa login dari dalam container (`root@localhost`).
-   Start, stop, dan restart container.
-   Membuat database baru sekaligus user pemiliknya; user hanya punya hak di
    database miliknya sendiri.
-   Backup database dengan `mysqldump` ke `.sql.gz` (divalidasi), plus backup
    akun user & grant.
-   Restore dengan memilih dari daftar backup yang tersedia, termasuk
    penanganan `DEFINER` dan opsi mengosongkan database tujuan.
-   Melihat daftar database, user, status container, pengaturan SSL, dan log.
-   Ganti password root maupun user lain; `.env` ikut diperbarui untuk akun
    yang tersimpan di sana.
-   Auto backup terjadwal (systemd timer, atau cron) dengan retensi.
-   Tujuan backup: lokal saja, Cloudflare R2 saja, atau lokal + R2.

## Prasyarat

Server Linux dengan:

-   Bash, `gzip`, OpenSSL, `flock` (paket `util-linux`, default ada).
-   `python3` (untuk pemeriksaan kolom generated saat restore; default ada di
    Ubuntu/Debian).
-   (Opsional, untuk R2) tidak perlu instal apa pun: rclone dijalankan sebagai
    container `rclone/rclone`.
-   Docker Engine + Docker Compose plugin (`docker compose`).
-   Hak akses `root` / `sudo`.

``` bash
docker --version
docker compose version
openssl version
```

> Script tidak memasang Docker Engine atau Docker Compose.

## Instalasi dan menjalankan

Semua file yang dibuat script (`.env`, `compose.yaml`, `data/`, `backups/`)
disimpan di **folder tempat `mysql-manager.sh` berada**. Pilih folder khusus
untuk satu instance, misalnya `/opt/mysql`:

``` bash
sudo mkdir -p /opt/mysql
sudo cp mysql-manager.sh /opt/mysql/
sudo chmod +x /opt/mysql/mysql-manager.sh
sudo /opt/mysql/mysql-manager.sh
```

Catatan:

-   Satu folder = satu instance. Dua folder = dua instance terpisah (bedakan
    nama container dan port).
-   Nama folder hanya boleh berisi huruf, angka, `.`, `_`, `-`, `/`. Folder
    sistem (`/`, `/usr`, `/etc`, `/var`, `/tmp`, `/root`, `/home`) ditolak.
-   Owner/permission folder proyek sendiri tidak diubah.
-   `.gitignore` mengecualikan semua file runtime (password, data, backup).
-   Contoh path di dokumentasi ini memakai `/opt/mysql`.

## Menu interaktif

``` text
 1. Setup MySQL dari nol
 2. Start MySQL
 3. Stop MySQL
 4. Restart MySQL
 5. Buat database + user baru
 6. Backup database
 7. Restore database (pilih dari backup)
 8. List database
 9. List user
10. Cek status container & SSL
11. Lihat MySQL logs
12. Ganti password user/root
13. Auto backup & Cloudflare R2
14. Hapus database + user
15. Rotasi sertifikat SSL
16. Uninstall instance (hapus container, opsional data)
 0. Keluar
```

Error pada satu aksi tidak menutup script; pesan error ditampilkan lalu
kembali ke menu. `Ctrl+C` membatalkan aksi yang sedang berjalan.

## Setup pertama kali

Menu **1. Setup MySQL dari nol**:

  Parameter        Default            Keterangan
  ---------------- ------------------ ------------------------------------------
  Image            `mysql:8.4`        Image Docker (minimal MySQL 8.0)
  Database awal    `qolcore`          Dibuat saat inisialisasi
  User aplikasi    `qolcore_user`     Semua hak hanya di database awal
  Port host        `3307`             Port yang dipublikasikan di host
  Bind address     `127.0.0.1`        `0.0.0.0` hanya jika perlu akses dari luar
  Container        `qolcore-mysql`    Nama container
  Password root    otomatis           Atau input sendiri (min. 16 karakter)
  Password user    otomatis           Atau input sendiri (min. 16 karakter)

Password input sendiri hanya boleh berisi huruf, angka, dan `@ # % + = . _ -`
agar aman disimpan di `.env`.

Script kemudian:

1.  `docker pull`, membaca versi MySQL dan UID user `mysql` di image.
2.  Membuat `data/` (milik user `mysql` di container, `700`) dan `backups/`
    (root, `700`).
3.  Menulis `.env` dan `compose.yaml` (`600`).
4.  Menjalankan `docker compose up -d` dan menunggu MySQL siap via TCP
    (server sementara saat inisialisasi tidak dihitung siap).

Opsi server yang dipakai:

  Opsi                                     Fungsi
  ---------------------------------------- ---------------------------------------
  `--require-secure-transport=ON`          Tolak koneksi TCP tanpa TLS
  `--character-set-server=utf8mb4`         Charset default (emoji aman)
  `--collation-server=utf8mb4_0900_ai_ci`  Collation default MySQL 8
  `--skip-name-resolve`                    Tidak ada lookup DNS saat login
  `--local-infile=OFF`                     Matikan `LOAD DATA LOCAL`
  `MYSQL_ROOT_HOST=localhost`              Root hanya dari dalam container

**Perlindungan data:** setup dibatalkan jika `.env`/`compose.yaml` sudah ada,
`data/` tidak kosong, atau nama container sudah dipakai.

## Struktur folder

``` text
/opt/mysql/
├── mysql-manager.sh
├── .env            # konfigurasi + password (600)
├── compose.yaml    # Docker Compose (600)
├── backup.conf     # pengaturan auto backup (600, jika diaktifkan)
├── r2.conf         # kredensial R2 (600, jika dikonfigurasi)
├── data/           # data MySQL + sertifikat TLS auto (milik user mysql, 700)
└── backups/        # backup manual & pengaman (root, 700)
    ├── auto/       # hasil auto backup (kena retensi)
    └── downloaded/ # file yang diunduh dari R2
```

## Membuat database dan user baru

Menu **5**. Nama database: huruf/angka/underscore, maks. 64 karakter.
Username: maks. 32 karakter. Password dikosongkan = dibuat otomatis; password
input sendiri minimal 12 karakter (karakter apa pun, di-escape dengan benar).

Setara dengan:

``` sql
CREATE DATABASE nama_db CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER 'nama_user'@'%' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON nama_db.* TO 'nama_user'@'%';
```

User hanya bisa mengakses database miliknya. Jika salah satu langkah gagal,
user/database yang terlanjur dibuat dihapus kembali. Password ditampilkan sekali
dan tidak disimpan ke file.

## Backup database

Menu **6**: masukkan nama database, atau kosongkan untuk semua database
aplikasi.

``` text
/opt/mysql/backups/NAMA_DATABASE-YYYYMMDD-HHMMSS.sql.gz
/opt/mysql/backups/users-YYYYMMDD-HHMMSS.sql
```

-   `mysqldump --single-transaction` (snapshot konsisten InnoDB tanpa
    mengunci tabel), termasuk routine, trigger, dan event.
-   Cek ruang disk dulu (minimal ukuran database + 1 GiB).
-   Ditulis sebagai `*.partial`, divalidasi (`gzip -t` + penanda
    `-- Dump completed`), baru di-rename. Gagal = file parsial dihapus.
-   `users-*.sql` berisi `CREATE USER` (hash password) + `GRANT` semua user
    selain root. Perlakukan sama rahasianya dengan `.env`.

Jika R2 sudah dikonfigurasi, menu 6 menawarkan upload ke `<prefix>/manual/`.
Backup manual tidak pernah dihapus otomatis.

## Auto backup terjadwal

Menu **13. Auto backup & Cloudflare R2**:

``` text
  1. Aktifkan / ubah jadwal & tujuan (lokal / R2 / lokal + R2)
  2. Nonaktifkan jadwal
  3. Jalankan auto backup sekarang (tes)
  4. Lihat log auto backup
  5. Atur kredensial Cloudflare R2
  6. Tes koneksi R2
  7. Lihat & download backup dari R2
  8. Atur notifikasi Telegram
  9. Tes notifikasi Telegram
 10. Matikan notifikasi Telegram
```

  Parameter       Default   Keterangan
  --------------- --------- ---------------------------------------------------
  Jam             `02:30`   Jam harian (zona waktu server)
  Database        `all`     `all` = semua database aplikasi (termasuk yang dibuat nanti), atau `db1,db2`
  Tujuan          Lokal     1 = lokal, 2 = R2 saja, 3 = lokal + R2
  Retensi lokal   `14`      Hari; 0 = tidak pernah hapus

### Tujuan backup

  Tujuan        Lokal (`backups/auto/`)                       R2 (`<prefix>/auto/`)
  ------------- --------------------------------------------- --------------------------
  Lokal saja    Disimpan, dihapus sesuai retensi lokal        -
  R2 saja       Sementara; dihapus **setelah** upload sukses   Sesuai retensi R2
  Lokal + R2    Disimpan, dihapus sesuai retensi lokal        Sesuai retensi R2

Jika upload ke R2 gagal, file **tetap disimpan lokal** dan ikut di-upload pada
run berikutnya; status run dicatat gagal.

### Retensi

-   Retensi lokal (menu 13 → 1) dan R2 (menu 13 → 5) diatur terpisah. File
    lebih tua dari N × 24 jam dihapus **saat auto backup berjalan**, setelah
    backup baru berhasil.
-   Backup **terbaru tiap database selalu disisakan**, walau sudah lewat batas.
-   Hanya berlaku untuk backup otomatis. Backup manual, backup pengaman
    sebelum restore, folder `manual/` di R2, dan `backups/downloaded/` tidak
    dihapus otomatis.

### Cara kerja scheduler

1.  Pengaturan disimpan di `backup.conf` (root, `600`).
2.  Salinan script dipasang ke `/usr/local/sbin/mysql-manager` (root, `755`);
    scheduler menjalankan salinan ini dengan `MYM_BASE_DIR=<folder proyek>`,
    sehingga file di folder user tidak pernah dieksekusi sebagai root.
3.  systemd: `mym-backup-<id>.service` + `.timer` (`<id>` dari path folder,
    mis. `/opt/mysql` → `mym-backup-opt-mysql`), `Persistent=true` (backup
    terlewat dijalankan saat server hidup lagi). Tanpa systemd:
    `/etc/cron.d/mym-backup-<id>`.
4.  Memakai `flock` sehingga dua backup tidak berjalan bersamaan.

``` bash
systemctl list-timers mym-backup-opt-mysql.timer
journalctl -u mym-backup-opt-mysql.service -n 50
sudo MYM_BASE_DIR=/opt/mysql /usr/local/sbin/mysql-manager backup-auto
```

> Setelah memperbarui `mysql-manager.sh`, buka menu 13 → 1 lagi agar salinan
> di `/usr/local/sbin` ikut diperbarui.

## Cloudflare R2

1.  Dashboard Cloudflare → **R2 → Create bucket** (private, tanpa public access).
2.  **R2 → Manage API Tokens → Create API token**: permission **Object Read &
    Write**, khusus bucket tersebut. Simpan Access Key ID & Secret.
3.  Menu **13 → 5**: isi Account ID, Access Key ID, Secret, bucket, prefix
    (default `mysql/<hostname>`), endpoint (default
    `https://<ACCOUNT_ID>.r2.cloudflarestorage.com`; bucket EU:
    `https://<ACCOUNT_ID>.eu.r2.cloudflarestorage.com`), dan retensi R2
    (default 30 hari). Langsung dites tulis → baca → hapus.

``` text
<bucket>/
└── mysql/<hostname>/
    ├── auto/      # auto backup (kena retensi R2)
    └── manual/    # upload dari menu 6 (tidak dihapus otomatis)
```

-   rclone dijalankan sebagai container `rclone/rclone:1.68.2` (atau rclone di
    host jika dipilih). Kredensial lewat env-file sementara (`600`, langsung
    dihapus), tidak pernah muncul di `ps`.
-   File backup berisi seluruh data, dan `users-*.sql` berisi hash password.
    Pastikan bucket tidak publik dan token hanya untuk bucket itu.

## Restore database

Menu **7**:

1.  Isi filter nama database (atau kosongkan), lalu pilih nomor backup dari
    daftar (40 terbaru). Daftar menggabungkan backup lokal (`backups/`,
    `backups/auto/`, `backups/downloaded/`) dan R2 (`auto/`, `manual/`); file
    yang ada di keduanya ditampilkan sekali (lokal diutamakan). Backup dari R2
    di-download dulu ke `backups/downloaded/`. Ketik `m` untuk path file
    sendiri (`.sql`/`.sql.gz`).
2.  File divalidasi: gzip utuh, header mysqldump, dan **bukan** dump
    `--databases`/`--all-databases` (dump seperti itu berisi `USE db` sehingga
    data akan masuk ke database aslinya, bukan ke database pilihan).
    Kolom generated (`VIRTUAL`/`STORED`) juga diperiksa, lihat bagian
    [Kolom generated](#kolom-generated-virtualstored).
3.  Database tujuan disarankan sesuai nama di file backup. Harus sudah ada
    (buat lewat menu 5).
4.  **DEFINER:** jika dump berisi view/trigger/routine/event dengan `DEFINER`,
    script menampilkan daftarnya dan apakah user tersebut ada di server ini,
    lalu menawarkan menggantinya ke user lain (default: user pemilik database
    tujuan). Ketik `-` untuk membiarkan apa adanya.
5.  Opsi **kosongkan database dulu** (`DROP` + `CREATE` dengan charset yang
    sama; grant tetap berlaku). Tanpa opsi ini, tabel yang tidak ada di backup
    tetap dibiarkan.
6.  Backup pengaman database tujuan (default: ya), lalu ketik `RESTORE`.

**Penting:** restore MySQL tidak atomik. Jika gagal di tengah, database bisa
ter-restore sebagian; kembalikan dari backup pengaman.

### Kolom generated (VIRTUAL/STORED)

Contoh kolom:

``` sql
total_bayar DECIMAL(20,2) GENERATED ALWAYS AS
  ((total_diskon * order_qty) - (total_harga * (diskon_regular / 100))) VIRTUAL
```

MySQL menolak `INSERT` yang mengisi nilai kolom generated
(`ERROR 3105: The value specified for generated column ... is not allowed`).

-   **Backup dari script ini (menu 6) aman.** `mysqldump` menyimpan definisi
    `GENERATED ALWAYS AS (...)` di `CREATE TABLE` dan otomatis **tidak**
    menyertakan nilai kolom generated di `INSERT`. Nilainya dihitung ulang
    oleh MySQL saat restore.
-   **Dump dari tool lain** (export Navicat, HeidiSQL, phpMyAdmin, dll.)
    sering menyertakan nilai kolom generated sehingga restore gagal di tengah.
    Script memeriksa ini **sebelum** ada perubahan apa pun:
    -   Menampilkan daftar `tabel.kolom` yang bermasalah.
    -   Menawarkan perbaikan otomatis: nilai kolom generated dibuang dari
        setiap `INSERT` (kolom ditulis eksplisit), MySQL menghitung ulang.
        Isi kolom lain tidak diubah (diproses byte per byte).
    -   `INSERT` yang tidak bisa diperbaiki otomatis (mis.
        `ON DUPLICATE KEY UPDATE`, atau jumlah nilai tidak cocok) ditolak
        sebelum restore dimulai, dengan saran membuat ulang dump pakai
        `mysqldump`.
-   Pemeriksaan ini butuh `python3` di host (tersedia default di Ubuntu/Debian
    dan sebagian besar distro server). Tanpa `python3`, script hanya memberi
    peringatan.

## Ganti password

Menu **12**: pilih akun (`user` atau `user@host`, default `root@localhost`),
password baru (kosong = otomatis), lalu ketik `GANTI`.

1.  `ALTER USER ... IDENTIFIED BY` langsung di MySQL yang sedang berjalan.
2.  Untuk `root@localhost` → `MYSQL_ROOT_PASSWORD` di `.env` ikut diperbarui.
    Untuk user aplikasi awal (`MYSQL_USER`@`%`) → `MYSQL_PASSWORD` di `.env`.
    Password akun yang disimpan di `.env` harus minimal 16 karakter dengan
    `A-Z a-z 0-9 @ # % + = . _ -`; akun lain minimal 12 karakter bebas.
3.  Login dengan password baru diuji otomatis (root via socket, user lain via
    TCP + TLS dari dalam container).
4.  Jika `.env` berubah, ada opsi recreate container agar password lama tidak
    tersisa di environment container.

> Jangan mengganti password hanya dengan mengedit `.env`: nilainya hanya dipakai
> saat inisialisasi pertama. Selalu gunakan menu 12.

## Hapus database + user

Menu **14**. Langkah:

1.  Pilih database dari daftar.
2.  Script menampilkan jumlah koneksi aktif dan user/role terkait. Jika ada
    koneksi aktif, Anda diminta setuju memutusnya (jika tidak, dibatalkan).
3.  Pilih apakah user/role yang **hanya** dipakai untuk database ini ikut
    dihapus (default: ya).
4.  Backup database dulu (default: ya) ke `backups/`.
5.  Ketik ulang **nama database** untuk konfirmasi.

Detail MySQL:

-   Database sistem (`mysql`, `information_schema`, `performance_schema`,
    `sys`) tidak bisa dihapus.
-   User **khusus** = selain `USAGE`, haknya hanya ke database ini → ditawarkan
    untuk dihapus. User yang juga punya akses ke database lain tidak dihapus;
    hanya hak ke database ini yang dicabut.
-   MySQL tidak mencabut grant saat database dihapus. Script mencabutnya
    (`REVOKE`) supaya database baru dengan nama sama tidak otomatis bisa
    diakses user lama.
-   Koneksi aktif diputus dengan `KILL`.

## Rotasi sertifikat SSL

Menu **15** menampilkan sertifikat yang sedang dipakai (subject, issuer,
tanggal berakhir, sisa hari), lalu:

  Pilihan   Fungsi
  --------- ----------------------------------------------------------------------
  1         Buat sertifikat self-signed baru (berlaku 10 tahun)
  2         Pakai sertifikat sendiri (mis. dari CA / Let's Encrypt): fullchain + key

Untuk pilihan 2, script memastikan file berformat PEM, key tidak ber-passphrase,
key **cocok** dengan sertifikat, dan sertifikat belum kedaluwarsa.

-   Sertifikat lama disimpan di `backups/ssl-YYYYMMDD-HHMMSS/`.
-   Sertifikat baru dimuat **tanpa restart**.
-   Jika server menolak sertifikat baru, file lama otomatis dikembalikan dan
    server tetap memakai sertifikat sebelumnya.
-   Bagian atas menu menampilkan **peringatan** jika sertifikat berakhir dalam
    kurang dari 30 hari (atau sudah kedaluwarsa); peringatan yang sama ikut
    dikirim di notifikasi Telegram.

Lokasi sertifikat: `data/ca.pem`, `data/server-cert.pem`, `data/server-key.pem` (dibuat otomatis oleh MySQL saat setup). Pilihan 1 membuat CA baru + sertifikat server yang ditandatangani CA tersebut; klien yang memakai `VERIFY_CA` perlu `ca.pem` yang baru. Pilihan 2 boleh menyertakan file CA/chain, atau mempertahankan `ca.pem` lama. Dimuat dengan `ALTER INSTANCE RELOAD TLS`.

## Notifikasi Telegram

Menu **13 → 8** (auto backup & R2):

1.  Buat bot lewat **@BotFather** → dapatkan token (`123456:ABC...`).
2.  Kirim pesan ke bot (atau tambahkan bot ke grup), lalu ambil chat ID dari
    `https://api.telegram.org/bot<TOKEN>/getUpdates` (field `chat.id`; grup
    biasanya diawali `-100`).
3.  Isi token, chat ID, dan kapan dikirim: **hanya jika gagal** (default) atau
    **setiap auto backup**. Pesan tes langsung dikirim.

Isi pesan: status (✅/❌), host, folder, container, ringkasan per database,
status upload R2, baris error, dan peringatan sertifikat jika ada.

-   Disimpan di `telegram.conf` (root, `600`). Token dikirim ke `curl` lewat
    stdin sehingga tidak muncul di `ps`. Butuh `curl` di host.
-   Gagal mengirim notifikasi **tidak** mengubah status backup (backup sukses
    tetap tercatat sukses).
-   Menu 13 → 9 mengirim pesan tes, 13 → 10 mematikan notifikasi.

## Uninstall instance

Menu **16**. Yang selalu dilakukan:

-   Jadwal auto backup instance ini dimatikan.
-   Container dihentikan dan dihapus (`docker compose down`).
-   Salinan script di `/usr/local/sbin` dihapus **hanya jika** tidak dipakai
    instance lain.

Yang ditanyakan:

  Pertanyaan                                   Default   Catatan
  -------------------------------------------- --------- -------------------------------
  Backup terakhir semua database               Ya        Ke `backups/`
  Hapus data (`data/`) + konfigurasi            Tidak     Butuh ketik `HAPUS DATA`
  Hapus folder `backups/`                       Tidak     Hanya ditanya jika data dihapus

Konfirmasi akhir: ketik **nama container**. Script itu sendiri, backup di R2,
dan image Docker tidak dihapus.

-   Data disimpan → instance bisa dinyalakan lagi dengan menu 2.
-   Data dihapus → folder kembali ke kondisi "Belum setup" dan siap untuk
    setup baru (menu 1).

## Koneksi dan SSL

``` text
mysql://USER:PASSWORD@HOST:3307/NAMA_DB?ssl-mode=REQUIRED
jdbc:mysql://HOST:3307/NAMA_DB?sslMode=REQUIRED
```

Koneksi TCP tanpa TLS ditolak. Sertifikat dibuat otomatis oleh MySQL
(self-signed, berlaku 10 tahun) dan tersimpan di `data/`. `REQUIRED`
mengenkripsi koneksi tetapi tidak memverifikasi identitas server; untuk
verifikasi gunakan `VERIFY_CA`/`VERIFY_IDENTITY` dengan sertifikat CA
tepercaya.

Menu **10** menampilkan status container serta `require_secure_transport`,
versi TLS, dan masa berlaku sertifikat.

## Keamanan jaringan

Default bind `127.0.0.1`. Jika memakai `0.0.0.0`:

-   Port yang dipublikasikan Docker **tidak** tunduk pada UFW / chain `INPUT`.
    Batasi lewat Security List/NSG cloud dan/atau chain `DOCKER-USER`:

    ``` bash
    sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 3307 --ctdir ORIGINAL -j DROP
    sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport 3307 --ctdir ORIGINAL -s 10.0.0.0/24 -j ACCEPT
    ```

-   Gunakan password kuat dan unik untuk setiap user.

## Operasi Docker manual

``` bash
cd /opt/mysql
docker compose ps
docker compose up -d
docker compose stop
docker compose restart
docker logs --tail 100 qolcore-mysql
```

## Batasan

-   Restore hanya ke database yang sudah ada.
-   Dump dari server dengan GTID yang memuat `SET @@GLOBAL.GTID_PURGED` bisa
    gagal di-restore; buat dump dengan `--set-gtid-purged=OFF`.
-   `.env` dibaca sebagai data (tidak di-`source`).

## Troubleshooting

### `Tidak bisa login sebagai root ke MySQL`

Periksa `MYSQL_ROOT_PASSWORD` di `.env`. Nilai ini hanya dipakai saat
inisialisasi pertama; mengubah `.env` tidak mengubah password di database.
Saat pertama kali start, MySQL butuh 1-3 menit untuk inisialisasi; lihat menu 11.

### Permission denied pada `/var/lib/mysql`

Jalankan menu **2. Start**: owner folder `data/` otomatis diperbaiki ke user
`mysql` di container dan container dibuat ulang. Manual:

``` bash
sudo chown 999:999 /opt/mysql/data && sudo chmod 700 /opt/mysql/data
cd /opt/mysql && sudo docker compose up -d --force-recreate
```

### Client gagal konek: `Connections using insecure transport are prohibited`

Client harus memakai TLS (`ssl-mode=REQUIRED` / `sslMode=REQUIRED`).

------------------------------------------------------------------------

## Lisensi

Dirilis di bawah [MIT License](LICENSE). Copyright (c) 2026 Raqolbi.

Script ini disediakan "apa adanya" tanpa jaminan apa pun. Uji terlebih dahulu
di lingkungan non-produksi dan selalu simpan backup off-server sebelum restore.
