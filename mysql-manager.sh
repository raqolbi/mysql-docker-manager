#!/usr/bin/env bash
# MySQL Docker Manager
# First-run setup + interactive database administration for MySQL 8.4 LTS.
set -Euo pipefail
umask 077   # semua file baru (.env, backup) default hanya bisa dibaca root

# Semua file runtime (.env, compose.yaml, data/, backups/) dibuat di folder
# tempat script ini berada.
SCRIPT_PATH=$(readlink -f "${BASH_SOURCE[0]}")
INSTALLED_BIN="/usr/local/sbin/mysql-manager"
if [[ -n "${MYM_BASE_DIR:-}" ]]; then
  BASE_DIR=$(readlink -f "$MYM_BASE_DIR")
elif [[ "$SCRIPT_PATH" == "$INSTALLED_BIN" ]]; then
  echo "Ini salinan untuk scheduler. Jalankan script dari folder proyeknya, atau set MYM_BASE_DIR=<folder>." >&2
  exit 1
else
  BASE_DIR=$(dirname "$SCRIPT_PATH")
fi
if [[ ! -d "$BASE_DIR" || ! "$BASE_DIR" =~ ^/[A-Za-z0-9._/-]+$ ]]; then
  echo "Folder kerja tidak valid: '$BASE_DIR' (hanya huruf, angka, . _ - / dan harus sudah ada)." >&2
  exit 1
fi
case "$BASE_DIR" in
  /|/bin|/sbin|/usr|/usr/*bin|/etc|/var|/tmp|/root|/home) echo "Folder kerja '$BASE_DIR' tidak boleh dipakai. Taruh script di folder sendiri, mis. /opt/mysql." >&2; exit 1 ;;
esac
ENV_FILE="$BASE_DIR/.env"
COMPOSE_FILE="$BASE_DIR/compose.yaml"
DATA_DIR="$BASE_DIR/data"
BACKUP_DIR="$BASE_DIR/backups"
AUTO_DIR="$BACKUP_DIR/auto"
DOWNLOAD_DIR="$BACKUP_DIR/downloaded"
BACKUP_CONF="$BASE_DIR/backup.conf"
R2_CONF="$BASE_DIR/r2.conf"
# Nama unit/cron unik per folder proyek, mis. /opt/mysql -> mym-backup-opt-mysql
SCHED_ID=$(printf '%s' "${BASE_DIR#/}" | tr -c 'A-Za-z0-9' '-' | sed -E 's/-+/-/g; s/^-|-$//g')
SYSTEMD_UNIT="mym-backup-${SCHED_ID}"
CRON_FILE="/etc/cron.d/mym-backup-${SCHED_ID}"
RCLONE_IMAGE_DEFAULT="rclone/rclone:1.68.2"
SYSTEM_SCHEMAS="'mysql','information_schema','performance_schema','sys'"
SYSTEM_USERS="'mysql.sys','mysql.session','mysql.infoschema'"

# Harus root agar bisa mengelola Docker dan owner folder data.
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  echo "Jalankan dengan sudo: sudo $0"
  exit 1
fi

err() { echo "ERROR: $*" >&2; }
log() { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1 || { err "Perintah '$1' belum tersedia."; return 1; }; }

pause() { echo; read -r -p "Tekan Enter untuk kembali ke menu..." _ || true; }

# Baca .env tanpa `source`, supaya isi file tidak pernah dieksekusi sebagai kode.
load_config() {
  [[ -f "$ENV_FILE" ]] || { err "File $ENV_FILE tidak ditemukan. Jalankan setup (menu 1) terlebih dahulu."; return 1; }
  MYSQL_IMAGE="" MYSQL_DATABASE="" MYSQL_USER="" MYSQL_PASSWORD="" MYSQL_ROOT_PASSWORD=""
  MYSQL_PORT="" MYSQL_BIND="" MYSQL_CONTAINER="" MYSQL_UID="" MYSQL_GID=""
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//$'\r'/}; value=${value//$'\r'/}
    key=${key#"${key%%[![:space:]]*}"}; key=${key%"${key##*[![:space:]]}"}
    [[ -z "$key" || "$key" == \#* ]] && continue
    key=${key#export }
    value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
    if [[ "$value" =~ ^\"(.*)\"$ || "$value" =~ ^\'(.*)\'$ ]]; then value=${BASH_REMATCH[1]}; fi
    case "$key" in
      MYSQL_IMAGE|MYSQL_DATABASE|MYSQL_USER|MYSQL_PASSWORD|MYSQL_ROOT_PASSWORD|MYSQL_PORT|MYSQL_BIND|MYSQL_CONTAINER)
        printf -v "$key" '%s' "$value" ;;
      MYSQL_UID|MYSQL_GID)
        if [[ "$value" =~ ^[0-9]+$ ]]; then printf -v "$key" '%s' "$value"; fi ;;
    esac
  done < "$ENV_FILE"
  : "${MYSQL_IMAGE:=mysql:8.4}"
  : "${MYSQL_PORT:=3307}"
  : "${MYSQL_BIND:=127.0.0.1}"
  : "${MYSQL_CONTAINER:=qolcore-mysql}"
  if [[ -z "$MYSQL_ROOT_PASSWORD" ]]; then
    err "MYSQL_ROOT_PASSWORD kosong di $ENV_FILE."; return 1
  fi
  if [[ ! "$MYSQL_CONTAINER" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    err "Nilai MYSQL_CONTAINER di $ENV_FILE tidak valid."; return 1
  fi
}

# Folder proyek & backups dipakai proses root (scheduler). Jika bisa diubah user
# non-root, user itu bisa membelokkan file lewat symlink / mengganti konfigurasi.
base_dir_safe() {
  local d owner mode
  for d in "$BASE_DIR" "$BACKUP_DIR"; do
    [[ -e "$d" ]] || continue
    if [[ -L "$d" ]]; then err "$d adalah symlink; ditolak demi keamanan."; return 1; fi
    owner=$(stat -c '%u' "$d"); mode=$(stat -c '%a' "$d")
    if [[ "$owner" != "0" ]] || (( (8#$mode & 8#022) != 0 )); then
      err "$d dimiliki uid $owner (mode $mode). Proses root tidak boleh bekerja di folder yang bisa diubah user lain."
      err "Perbaiki: sudo chown root:root $d && sudo chmod go-w $d"
      return 1
    fi
  done
}

# File yang dipakai perintah root tidak boleh bisa ditulis user lain.
check_ownership() {
  local f owner mode
  owner=$(stat -c '%u' "$BASE_DIR"); mode=$(stat -c '%a' "$BASE_DIR")
  if [[ "$owner" != "0" ]] || (( (8#$mode & 8#022) != 0 )); then
    echo "PERINGATAN: folder $BASE_DIR dimiliki uid $owner (mode $mode); auto backup menolak berjalan di folder"
    echo "           yang bisa diubah user non-root. Perbaiki: sudo chown root:root $BASE_DIR && sudo chmod go-w $BASE_DIR"
  fi
  for f in "$ENV_FILE" "$COMPOSE_FILE"; do
    [[ -e "$f" ]] || continue
    owner=$(stat -c '%u' "$f"); mode=$(stat -c '%a' "$f")
    if [[ "$owner" != "0" ]] || (( (8#$mode & 8#022) != 0 )); then
      echo "PERINGATAN: $f dimiliki uid $owner / mode $mode. Sebaiknya: sudo chown root:root $f && sudo chmod 600 $f"
    fi
  done
  return 0
}

check_docker() {
  need_cmd docker || return 1
  docker compose version >/dev/null 2>&1 || {
    err "Docker Compose plugin tidak ditemukan. Pasang Docker Engine + Docker Compose plugin terlebih dahulu."
    return 1
  }
  docker info >/dev/null 2>&1 || { err "Docker daemon tidak dapat diakses."; return 1; }
}

# Nama database: huruf/angka/underscore, maks 64. Username: maks 32 (batas MySQL).
# Nama database yang SUDAH ADA (bisa dibuat aplikasi lain, mis. "my-app"): lebih longgar
# dari aturan pembuatan, tetap aman untuk nama file dan SQL ber-quote.
valid_dbname() { [[ "$1" =~ ^[A-Za-z0-9_][A-Za-z0-9_\$-]{0,62}$ ]]; }

valid_identifier() { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,63}$ ]]; }
valid_username()   { [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]{0,31}$ ]]; }
valid_host()       { [[ "$1" =~ ^[A-Za-z0-9._%:-]{1,255}$ ]]; }

valid_ipv4() {
  local ip=$1 o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do (( 10#$o <= 255 )) || return 1; done
}

# Identifier sudah divalidasi; bungkus dengan backtick.
sql_ident() { printf '`%s`' "$1"; }

# String literal MySQL: backslash adalah karakter escape (kecuali NO_BACKSLASH_ESCAPES),
# jadi escape backslash dulu, lalu kutip tunggal.
sql_literal() {
  local v=${1//\\/\\\\}
  v=${v//\'/\'\'}
  printf "'%s'" "$v"
}

# Klien mysql sebagai root di dalam container (via socket). Password diteruskan lewat
# environment (MYSQL_PWD), tidak pernah muncul di argumen proses.
mysql_root() {
  MYSQL_PWD="$MYSQL_ROOT_PASSWORD" docker exec -i -e MYSQL_PWD "$MYSQL_CONTAINER" \
    mysql -uroot --default-character-set=utf8mb4 "$@"
}

# Query tanpa header/kolom, satu baris per record.
mysql_q() { mysql_root -N -B -e "$1"; }

container_running() {
  docker inspect -f '{{.State.Running}}' "$MYSQL_CONTAINER" 2>/dev/null | grep -qx true
}

require_running() {
  load_config || return 1
  container_running || { err "Container '$MYSQL_CONTAINER' tidak berjalan. Jalankan menu 2 (Start)."; return 1; }
  if ! mysql_q "SELECT 1" >/dev/null 2>&1; then
    err "Tidak bisa login sebagai root ke MySQL. Periksa MYSQL_ROOT_PASSWORD di $ENV_FILE,"
    err "atau MySQL masih inisialisasi (lihat menu 11)."
    return 1
  fi
}

# Tunggu server final siap via TCP. Saat inisialisasi pertama, entrypoint menjalankan
# server sementara dengan --skip-networking, jadi cek TCP tidak tertipu.
wait_ready() {
  local container=$1 i
  for i in {1..90}; do
    if docker exec "$container" mysqladmin ping -h 127.0.0.1 --silent >/dev/null 2>&1; then
      return 0
    fi
    sleep 2
  done
  return 1
}

expand_path() {
  local p=$1 home=$HOME
  if [[ -n "${SUDO_USER:-}" ]]; then home=$(getent passwd "$SUDO_USER" | cut -d: -f6); fi
  [[ "$p" == "~" ]] && p=$home
  [[ "$p" == "~/"* ]] && p="$home/${p#\~/}"
  printf '%s' "$p"
}

gen_password() { openssl rand -hex 24; }

# Ganti nilai satu key di .env secara atomik, baris lain dipertahankan.
env_set() {
  local key=$1 value=$2 tmp line found=0
  tmp=$(mktemp "$BASE_DIR/.env.XXXXXX")
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*= ]]; then
      (( found )) || printf '%s=%s\n' "$key" "$value" >> "$tmp"
      found=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$ENV_FILE"
  (( found )) || printf '%s=%s\n' "$key" "$value" >> "$tmp"
  chmod 600 "$tmp"; chown root:root "$tmp"
  mv -f "$tmp" "$ENV_FILE"
}

# ---------------------------------------------------------------------------
# SETUP
# ---------------------------------------------------------------------------
read_password() {
  # $1 = label. Hasil di variabel global REPLY_PASSWORD.
  local label=$1 choice p1 p2
  echo "Password $label:"
  echo "  1. Generate otomatis"
  echo "  2. Input sendiri"
  read -r -p "Pilihan [1]: " choice
  choice=${choice:-1}
  if [[ "$choice" == "2" ]]; then
    read -r -s -p "Password $label: " p1; echo
    read -r -s -p "Ulangi password: " p2; echo
    [[ -n "$p1" && "$p1" == "$p2" ]] || { err "Password kosong atau tidak cocok."; return 1; }
    [[ "$p1" =~ ^[A-Za-z0-9@#%+=._-]{16,}$ ]] || { err "Password minimal 16 karakter; hanya huruf, angka, dan @ # % + = . _ - (agar aman disimpan di .env)."; return 1; }
    REPLY_PASSWORD=$p1
  else
    REPLY_PASSWORD=$(gen_password)
  fi
}

setup_stack() {
  echo "=== Setup MySQL Docker ==="
  check_docker || return 1
  need_cmd openssl || return 1
  if [[ -e "$COMPOSE_FILE" || -e "$ENV_FILE" ]]; then
    err "Konfigurasi sudah ada di $BASE_DIR (.env / compose.yaml). Setup dibatalkan agar data tidak tertimpa."
    return 1
  fi
  if [[ -d "$DATA_DIR" ]] && [[ -n "$(ls -A "$DATA_DIR" 2>/dev/null)" ]]; then
    err "$DATA_DIR tidak kosong. Data lama tidak akan diinisialisasi ulang, sehingga user/password"
    err "dari setup ini tidak akan berlaku. Pindahkan/hapus isi folder itu dulu."
    return 1
  fi

  local image db user port bind container root_pw user_pw ver major minor my_uid my_gid
  read -r -p "Image MySQL [mysql:8.4]: " image
  image=${image:-mysql:8.4}
  [[ "$image" =~ ^[A-Za-z0-9._/:@-]+$ ]] || { err "Nama image tidak valid."; return 1; }
  read -r -p "Database awal [qolcore]: " db
  db=${db:-qolcore}
  valid_identifier "$db" || { err "Nama database tidak valid (huruf, angka, underscore; maks 64)."; return 1; }
  read -r -p "User aplikasi untuk database '$db' [qolcore_user]: " user
  user=${user:-qolcore_user}
  valid_username "$user" || { err "Username tidak valid (huruf, angka, underscore; maks 32)."; return 1; }
  [[ "$user" != "root" ]] || { err "User aplikasi tidak boleh 'root'."; return 1; }
  read -r -p "Port host [3307]: " port
  port=${port:-3307}
  [[ "$port" =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 )) || { err "Port tidak valid."; return 1; }
  port=$((10#$port))
  echo "Bind address:"
  echo "  127.0.0.1 = hanya bisa diakses dari server ini (paling aman, default)"
  echo "  0.0.0.0   = semua interface; WAJIB dibatasi firewall (lihat peringatan setelah setup)"
  read -r -p "Bind address [127.0.0.1]: " bind
  bind=${bind:-127.0.0.1}
  valid_ipv4 "$bind" || { err "Bind address harus berupa IPv4 yang valid."; return 1; }
  read -r -p "Nama container [qolcore-mysql]: " container
  container=${container:-qolcore-mysql}
  [[ "$container" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] || { err "Nama container tidak valid."; return 1; }
  if docker inspect "$container" >/dev/null 2>&1; then
    err "Container bernama '$container' sudah ada. Gunakan nama lain atau hapus container tersebut."
    return 1
  fi
  echo
  read_password "root (hanya bisa login dari dalam container)" || return 1; root_pw=$REPLY_PASSWORD
  echo
  read_password "user '$user'" || return 1; user_pw=$REPLY_PASSWORD

  echo "Mengunduh/memeriksa image $image ..."
  docker pull "$image" || { err "Gagal pull image $image."; return 1; }
  ver=$(docker run --rm --entrypoint mysqld "$image" --version 2>/dev/null | grep -oE 'Ver [0-9]+\.[0-9]+' | head -n1 | cut -d' ' -f2 || true)
  [[ "$ver" =~ ^([0-9]+)\.([0-9]+)$ ]] || { err "Tidak bisa membaca versi MySQL dari image $image (pastikan image MySQL resmi)."; return 1; }
  major=${BASH_REMATCH[1]}; minor=${BASH_REMATCH[2]}
  (( major > 8 || (major == 8 && minor >= 0) )) || { err "Butuh MySQL 8.0 atau lebih baru (image: $ver)."; return 1; }
  my_uid=$(docker run --rm --entrypoint id "$image" -u mysql 2>/dev/null || true)
  my_gid=$(docker run --rm --entrypoint id "$image" -g mysql 2>/dev/null || true)
  [[ "$my_uid" =~ ^[0-9]+$ ]] || { err "Tidak bisa membaca UID user mysql di image $image."; return 1; }
  [[ "$my_gid" =~ ^[0-9]+$ ]] || my_gid=$my_uid
  echo "MySQL versi $ver, uid mysql $my_uid"

  mkdir -p "$DATA_DIR" "$BACKUP_DIR"
  # Folder proyek sendiri tidak diubah owner/mode-nya (bisa jadi repo git milik user).
  chown root:root "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
  chown "$my_uid:$my_gid" "$DATA_DIR"; chmod 700 "$DATA_DIR"

  cat > "$ENV_FILE" <<EOF
MYSQL_IMAGE=$image
MYSQL_DATABASE=$db
MYSQL_USER=$user
MYSQL_PASSWORD=$user_pw
MYSQL_ROOT_PASSWORD=$root_pw
MYSQL_PORT=$port
MYSQL_BIND=$bind
MYSQL_CONTAINER=$container
MYSQL_UID=$my_uid
MYSQL_GID=$my_gid
COMPOSE_PROJECT_NAME=mym-${SCHED_ID}
EOF
  chmod 600 "$ENV_FILE"

  # SSL: MySQL 8 membuat sertifikat self-signed sendiri di datadir saat inisialisasi.
  # require_secure_transport menolak semua koneksi TCP tanpa TLS.
  cat > "$COMPOSE_FILE" <<'YAML'
services:
  mysql:
    image: ${MYSQL_IMAGE}
    container_name: ${MYSQL_CONTAINER}
    restart: unless-stopped
    environment:
      MYSQL_ROOT_PASSWORD: ${MYSQL_ROOT_PASSWORD}
      MYSQL_ROOT_HOST: localhost
      MYSQL_DATABASE: ${MYSQL_DATABASE}
      MYSQL_USER: ${MYSQL_USER}
      MYSQL_PASSWORD: ${MYSQL_PASSWORD}
    ports:
      - "${MYSQL_BIND}:${MYSQL_PORT}:3306"
    volumes:
      - ./data:/var/lib/mysql
    command:
      - mysqld
      - --require-secure-transport=ON
      - --character-set-server=utf8mb4
      - --collation-server=utf8mb4_0900_ai_ci
      - --skip-name-resolve
      - --local-infile=OFF
    healthcheck:
      test: ["CMD-SHELL", "mysqladmin ping -h 127.0.0.1 --silent"]
      interval: 10s
      timeout: 5s
      retries: 5
      start_period: 60s
YAML
  chmod 600 "$COMPOSE_FILE"

  echo "Menjalankan MySQL..."
  if ! (cd "$BASE_DIR" && docker compose up -d); then
    err "docker compose up gagal. Konfigurasi tetap di $BASE_DIR; setelah diperbaiki jalankan menu 2 (Start)."
    return 1
  fi
  echo "Menunggu MySQL siap (inisialisasi pertama bisa 1-3 menit)..."
  if ! wait_ready "$container"; then
    err "MySQL belum siap. Periksa menu 11 (Logs)."
    return 1
  fi
  MYSQL_CONTAINER=$container MYSQL_ROOT_PASSWORD=$root_pw
  local rst
  rst=$(mysql_q "SELECT @@require_secure_transport" 2>/dev/null | tr -d '[:space:]' || true)

  echo ""
  echo "Setup selesai."
  echo "Container : $container"
  echo "Database  : $db"
  echo "User      : $user (semua hak hanya di database '$db')"
  echo "Root      : hanya login dari dalam container (root@localhost)"
  echo "Port      : $bind:$port"
  echo "SSL       : $([[ "$rst" == "1" ]] && echo "wajib (koneksi TCP tanpa TLS ditolak)" || echo "PERIKSA menu 10")"
  echo "Password  : tersimpan di $ENV_FILE (permission 600)"
  echo ""
  echo "Connection string (sesuaikan host):"
  echo "mysql://$user:<PASSWORD>@<HOST>:$port/$db?ssl-mode=REQUIRED"
  echo "JDBC: jdbc:mysql://<HOST>:$port/$db?sslMode=REQUIRED"
  firewall_notice "$bind" "$port"
}

firewall_notice() {
  local bind=$1 port=$2
  [[ "$bind" == "127.0.0.1" ]] && return 0
  cat <<EOF

================== PERINGATAN FIREWALL ==================
Port $port dipublikasikan oleh Docker di $bind. Docker menulis aturan iptables
sendiri sehingga aturan UFW / INPUT chain TIDAK berlaku untuk port ini.
Batasi akses dengan:
  1. Security List / NSG cloud: izinkan TCP $port hanya dari IP tertentu.
  2. Chain DOCKER-USER di host, contoh (ganti 10.0.0.0/24 dengan IP/subnet klien):
     sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL -j DROP
     sudo iptables -I DOCKER-USER -p tcp -m conntrack --ctorigdstport $port --ctdir ORIGINAL -s 10.0.0.0/24 -j ACCEPT
     (simpan permanen, mis. dengan paket iptables-persistent)
=========================================================
EOF
}

# ---------------------------------------------------------------------------
# DATABASE & USER
# ---------------------------------------------------------------------------
db_exists() {
  [[ "$(mysql_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name=$(sql_literal "$1")" | tr -d '[:space:]')" == "1" ]]
}

user_exists() {
  [[ "$(mysql_q "SELECT COUNT(*) FROM mysql.user WHERE user=$(sql_literal "$1")" | tr -d '[:space:]')" != "0" ]]
}

create_database() {
  require_running || return 1
  local db user password password2
  read -r -p "Nama database baru: " db
  read -r -p "Username pemilik database: " user
  valid_identifier "$db" || { err "Nama database tidak valid (huruf, angka, underscore; maks 64)."; return 1; }
  valid_username "$user" || { err "Username tidak valid (huruf, angka, underscore; maks 32)."; return 1; }
  [[ "$user" != "root" ]] || { err "Tidak boleh memakai 'root'."; return 1; }
  ! db_exists "$db" || { err "Database '$db' sudah ada."; return 1; }
  ! user_exists "$user" || { err "User '$user' sudah ada. Gunakan username lain atau kelola user tersebut secara manual."; return 1; }
  read -r -s -p "Password user baru (kosong = generate otomatis): " password; echo
  if [[ -z "$password" ]]; then
    password=$(gen_password)
  else
    read -r -s -p "Ulangi password: " password2; echo
    [[ "$password" == "$password2" ]] || { err "Password tidak cocok."; return 1; }
    (( ${#password} >= 12 )) || { err "Password minimal 12 karakter."; return 1; }
  fi

  # Password dikirim lewat stdin (bukan argumen proses).
  if ! mysql_root <<SQL
CREATE DATABASE $(sql_ident "$db") CHARACTER SET utf8mb4 COLLATE utf8mb4_0900_ai_ci;
CREATE USER $(sql_literal "$user")@'%' IDENTIFIED BY $(sql_literal "$password");
GRANT ALL PRIVILEGES ON $(sql_ident "$db").* TO $(sql_literal "$user")@'%';
SQL
  then
    err "Gagal membuat database/user. Membersihkan sisa yang terlanjur dibuat..."
    mysql_root -e "DROP USER IF EXISTS $(sql_literal "$user")@'%'; DROP DATABASE IF EXISTS $(sql_ident "$db");" >/dev/null 2>&1 || true
    return 1
  fi
  echo "Database berhasil dibuat."
  echo "Database : $db (utf8mb4)"
  echo "Username : $user (semua hak hanya di database '$db')"
  echo "Password : $password"
  echo "DSN      : mysql://$user:<PASSWORD>@<HOST>:$MYSQL_PORT/$db?ssl-mode=REQUIRED"
  echo "Simpan password ini sekarang; password tidak disimpan ke file mana pun."
}

list_databases() {
  require_running || return 1
  mysql_root --table -e "SELECT s.schema_name AS \`database\`, s.default_character_set_name AS charset,
    ROUND(COALESCE(SUM(t.data_length + t.index_length), 0) / 1024 / 1024, 2) AS size_mb,
    COUNT(t.table_name) AS tables
    FROM information_schema.schemata s
    LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name
    WHERE s.schema_name NOT IN ($SYSTEM_SCHEMAS)
    GROUP BY s.schema_name, s.default_character_set_name ORDER BY 1"
}

list_users() {
  require_running || return 1
  mysql_root --table -e "SELECT user, host, plugin, account_locked AS locked,
    IF(user='root','(semua)', COALESCE((SELECT GROUP_CONCAT(DISTINCT d.db ORDER BY d.db) FROM mysql.db d WHERE d.user=u.user AND d.host=u.host), '-')) AS \`databases\`
    FROM mysql.user u WHERE user NOT IN ($SYSTEM_USERS) ORDER BY user, host"
}

# ---------------------------------------------------------------------------
# BACKUP
# ---------------------------------------------------------------------------
free_bytes() { df -PB1 "$1" | awk 'NR==2 {print $4}'; }

db_size_bytes() {
  mysql_q "SELECT COALESCE(SUM(data_length + index_length), 0) FROM information_schema.tables WHERE table_schema=$(sql_literal "$1")" | tr -d '[:space:]'
}

# Backup satu database ke <dir>/<db>-YYYYMMDD-HHMMSS.sql.gz. Mencetak path file.
do_backup() {
  local db=$1 dir=${2:-$BACKUP_DIR} ts file tmp size free
  mkdir -p "$dir"; chmod 700 "$dir"
  size=$(db_size_bytes "$db") || return 1
  free=$(free_bytes "$dir")
  if [[ "$size" =~ ^[0-9]+$ && "$free" =~ ^[0-9]+$ ]] && (( free < size + 1073741824 )); then
    err "Ruang disk tidak cukup untuk backup '$db': sisa $(numfmt --to=iec "$free"), ukuran database $(numfmt --to=iec "$size") (+1GiB cadangan)."
    return 1
  fi
  ts=$(date +%Y%m%d-%H%M%S)
  file="$dir/${db}-${ts}.sql.gz"
  [[ -e "$file" ]] && file="$dir/${db}-${ts}-$$.sql.gz"
  tmp="$file.partial"
  log "Backup '$db' -> $file"
  # --single-transaction: snapshot konsisten untuk InnoDB tanpa mengunci tabel.
  if ! MYSQL_PWD="$MYSQL_ROOT_PASSWORD" docker exec -e MYSQL_PWD "$MYSQL_CONTAINER" \
        mysqldump -uroot --single-transaction --quick --routines --triggers --events \
        --hex-blob --set-gtid-purged=OFF --no-tablespaces --default-character-set=utf8mb4 \
        "$db" | gzip -6 > "$tmp"; then
    rm -f -- "$tmp"; err "mysqldump '$db' gagal; file parsial dihapus."; return 1
  fi
  # Validasi: arsip gzip utuh dan dump selesai sampai akhir.
  if ! gzip -t "$tmp" 2>/dev/null || ! grep -q '^-- Dump completed' < <(gzip -dc "$tmp" | tail -n 1); then
    rm -f -- "$tmp"; err "File backup '$db' tidak valid/terpotong; dihapus."; return 1
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$file" || { rm -f -- "$tmp"; err "Gagal menyimpan $file"; return 1; }
  printf '%s\n' "$file"
}

# Backup akun user + grant (tidak ikut di dump per database). Mencetak path file.
do_users_backup() {
  local dir=${1:-$BACKUP_DIR} file users u h sql
  file="$dir/users-$(date +%Y%m%d-%H%M%S).sql"
  users=$(mysql_q "SELECT CONCAT(user, ' ', host) FROM mysql.user WHERE user NOT IN ($SYSTEM_USERS) AND user <> 'root' ORDER BY user, host") || { err "Gagal membaca daftar user."; return 1; }
  sql="SET SESSION print_identified_with_as_hex = ON;"
  while read -r u h; do
    [[ -n "$u" ]] || continue
    sql+=" SHOW CREATE USER $(sql_literal "$u")@$(sql_literal "$h"); SHOW GRANTS FOR $(sql_literal "$u")@$(sql_literal "$h");"
  done <<< "$users"
  {
    echo "-- Akun user & grant dari container $MYSQL_CONTAINER, $(date '+%Y-%m-%d %H:%M:%S')"
    echo "-- Restore manual: mysql -uroot < file ini (lewati user yang sudah ada)."
    mysql_q "$sql" | sed 's/$/;/'
  } > "$file.partial" || { rm -f -- "$file.partial"; err "Backup user gagal."; return 1; }
  chmod 600 "$file.partial"; mv -f "$file.partial" "$file"
  log "User & grant -> $file"
  printf '%s\n' "$file"
}

list_app_databases() {
  mysql_q "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($SYSTEM_SCHEMAS) ORDER BY schema_name"
}

backup_database() {
  require_running || return 1
  local db file failed=0 files=() up
  read -r -p "Nama database yang akan di-backup (kosong = semua database aplikasi): " db
  if [[ -z "$db" ]]; then
    local d dbs=()
    mapfile -t dbs < <(list_app_databases)
    (( ${#dbs[@]} > 0 )) || { err "Tidak ada database aplikasi."; return 1; }
    for d in "${dbs[@]}"; do
      [[ -n "$d" ]] || continue
      if file=$(do_backup "$d"); then echo "OK    $file ($(du -h "$file" | cut -f1))"; files+=("$file"); else echo "GAGAL $d"; failed=1; fi
    done
  else
    valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
    db_exists "$db" || { err "Database '$db' tidak ditemukan."; return 1; }
    file=$(do_backup "$db") || return 1
    files+=("$file")
    echo "Backup selesai: $file ($(du -h "$file" | cut -f1))"
  fi
  if file=$(do_users_backup); then files+=("$file"); fi
  if (( ${#files[@]} > 0 )) && r2_configured; then
    read -r -p "Upload juga ke R2 (folder manual/)? [y/N]: " up
    if [[ "${up,,}" == "y" ]]; then
      if r2_upload_files manual "${files[@]}"; then echo "Upload ke R2 selesai."; else err "Upload ke R2 gagal; file lokal tetap ada."; failed=1; fi
    fi
  elif ! r2_configured; then
    echo "Ingat: salin backup ke luar server secara berkala (atau atur R2 di menu 13)."
  fi
  (( failed == 0 ))
}

# ---------------------------------------------------------------------------
# CLOUDFLARE R2 (via rclone, default dijalankan sebagai container Docker)
# ---------------------------------------------------------------------------
load_r2_conf() {
  R2_ACCOUNT_ID="" R2_ACCESS_KEY_ID="" R2_SECRET_ACCESS_KEY="" R2_BUCKET=""
  R2_PREFIX="" R2_ENDPOINT="" R2_RETENTION_DAYS=30 R2_RCLONE="docker" R2_RCLONE_IMAGE=$RCLONE_IMAGE_DEFAULT
  [[ -f "$R2_CONF" ]] || return 1
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//[[:space:]]/}; value=${value//$'\r'/}
    case "$key" in
      R2_ACCOUNT_ID)        if [[ "$value" =~ ^[A-Za-z0-9]+$ ]]; then R2_ACCOUNT_ID=$value; fi ;;
      R2_ACCESS_KEY_ID)     if [[ "$value" =~ ^[A-Za-z0-9]+$ ]]; then R2_ACCESS_KEY_ID=$value; fi ;;
      R2_SECRET_ACCESS_KEY) if [[ "$value" =~ ^[A-Za-z0-9+/=]+$ ]]; then R2_SECRET_ACCESS_KEY=$value; fi ;;
      R2_BUCKET)            if [[ "$value" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]]; then R2_BUCKET=$value; fi ;;
      R2_PREFIX)            if [[ "$value" =~ ^[A-Za-z0-9._/-]*$ ]]; then R2_PREFIX=${value%/}; fi ;;
      R2_ENDPOINT)          if [[ "$value" =~ ^https?://[A-Za-z0-9.:-]+/?$ ]]; then R2_ENDPOINT=${value%/}; fi ;;
      R2_RETENTION_DAYS)    if [[ "$value" =~ ^[0-9]+$ ]]; then R2_RETENTION_DAYS=$value; fi ;;
      R2_RCLONE)            if [[ "$value" == "docker" || "$value" == "host" ]]; then R2_RCLONE=$value; fi ;;
      R2_RCLONE_IMAGE)      if [[ "$value" =~ ^[A-Za-z0-9._/:@-]+$ ]]; then R2_RCLONE_IMAGE=$value; fi ;;
    esac
  done < "$R2_CONF"
  [[ -n "$R2_ENDPOINT" || -z "$R2_ACCOUNT_ID" ]] || R2_ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
  [[ -n "$R2_ACCESS_KEY_ID" && -n "$R2_SECRET_ACCESS_KEY" && -n "$R2_BUCKET" && -n "$R2_ENDPOINT" ]]
}

r2_configured() { load_r2_conf 2>/dev/null; }

# Lokasi tujuan di R2: r2:<bucket>/<prefix>/<sub>
r2_path() {
  local sub=$1 p=$R2_BUCKET
  [[ -n "$R2_PREFIX" ]] && p="$p/$R2_PREFIX"
  [[ -n "$sub" ]] && p="$p/$sub"
  printf 'r2:%s' "$p"
}

# Jalankan rclone dengan kredensial dari r2.conf. Kredensial tidak pernah masuk ke
# argumen proses: lewat env-file (Docker) atau environment subshell (host).
# Folder backup di-mount di path yang sama, jadi path lokal tidak perlu diterjemahkan.
rclone_run() {
  load_r2_conf || { err "Konfigurasi R2 belum lengkap ($R2_CONF)."; return 1; }
  local envf rc
  envf=$(mktemp "$BASE_DIR/.rclone-env.XXXXXX")
  chmod 600 "$envf"
  cat > "$envf" <<EOF
RCLONE_CONFIG_R2_TYPE=s3
RCLONE_CONFIG_R2_PROVIDER=Cloudflare
RCLONE_CONFIG_R2_ACCESS_KEY_ID=$R2_ACCESS_KEY_ID
RCLONE_CONFIG_R2_SECRET_ACCESS_KEY=$R2_SECRET_ACCESS_KEY
RCLONE_CONFIG_R2_ENDPOINT=$R2_ENDPOINT
RCLONE_CONFIG_R2_REGION=auto
RCLONE_CONFIG_R2_ACL=private
RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
RCLONE_CONFIG=/dev/null
EOF
  mkdir -p "$BACKUP_DIR"
  if [[ "$R2_RCLONE" == "host" ]]; then
    need_cmd rclone || { rm -f -- "$envf"; return 1; }
    ( set -a; while IFS='=' read -r k v; do printf -v "$k" '%s' "$v"; export "${k?}"; done < "$envf"; set +a
      rclone --retries 3 --low-level-retries 10 --stats 0 "$@" )
    rc=$?
  else
    docker run --rm --env-file "$envf" -v "$BACKUP_DIR:$BACKUP_DIR" "$R2_RCLONE_IMAGE" \
      --retries 3 --low-level-retries 10 --stats 0 "$@"
    rc=$?
  fi
  rm -f -- "$envf"
  return "$rc"
}

# Upload file tertentu ke r2:<bucket>/<prefix>/<sub>/
r2_upload_files() {
  local sub=$1 f rc=0; shift
  for f in "$@"; do
    log "Upload $(basename "$f") -> $(r2_path "$sub")/"
    rclone_run copyto "$f" "$(r2_path "$sub")/$(basename "$f")" || rc=1
  done
  return "$rc"
}

# Sinkronkan isi folder auto/ ke R2. mode=copy (lokal tetap) atau move (lokal dihapus
# SETELAH upload terverifikasi). File yang gagal di-upload tetap di lokal dan dicoba
# lagi pada run berikutnya.
r2_sync_auto() {
  local mode=$1 dir=${2:-$AUTO_DIR} sub=${3:-auto}
  [[ -d "$dir" ]] || return 0
  log "R2 $mode: $dir -> $(r2_path "$sub")"
  rclone_run "$mode" "$dir" "$(r2_path "$sub")" \
    --include '*.sql.gz' --include 'users-*.sql' --max-depth 1
}

# Retensi di R2: hapus objek di auto/ yang lebih tua dari N hari, tapi selalu sisakan
# objek terbaru per database dan file users terbaru.
r2_prune() {
  local days=${1:-0} sub=${2:-auto} listing cutoff list_file name ts epoch key
  (( days > 0 )) || return 0
  listing=$(rclone_run lsf "$(r2_path "$sub")" --files-only --format "tp" --separator ";" 2>/dev/null) || { err "Gagal membaca daftar objek R2."; return 1; }
  [[ -n "$listing" ]] || return 0
  cutoff=$(( $(date +%s) - days * 86400 ))
  declare -A newest_ts=() newest_name=()
  local -a rows=()
  while IFS=';' read -r ts name; do
    [[ -n "$name" ]] || continue
    case "$name" in users-*.sql) key="__users__" ;; *.sql.gz) key=$(sed -E 's/-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.sql\.gz$//' <<< "$name") ;; *) continue ;; esac
    epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
    rows+=("$epoch;$key;$name")
    if [[ -z "${newest_ts[$key]:-}" ]] || (( epoch > ${newest_ts[$key]} )); then
      newest_ts[$key]=$epoch; newest_name[$key]=$name
    fi
  done <<< "$listing"
  list_file=$(mktemp "$BACKUP_DIR/.r2-delete.XXXXXX")
  local r e k n count=0
  for r in "${rows[@]}"; do
    IFS=';' read -r e k n <<< "$r"
    (( e < cutoff )) || continue
    [[ "$n" == "${newest_name[$k]}" ]] && continue
    printf '%s\n' "$n" >> "$list_file"; count=$((count+1))
  done
  if (( count > 0 )); then
    log "R2: hapus $count backup lama (> $days hari)"
    rclone_run delete "$(r2_path "$sub")" --files-from-raw "$list_file" --max-depth 1 || { rm -f -- "$list_file"; return 1; }
  fi
  rm -f -- "$list_file"
}

r2_configure() {
  load_r2_conf || true
  local acc key secret bucket prefix endpoint ret ret2="" engine
  cat <<'EOF'
=== Cloudflare R2 ===

LANGKAH 1 - Buat bucket
  Dashboard Cloudflare -> R2 Object Storage -> Create bucket.
  Isi nama (huruf kecil/angka/'-', mis. db-backup). Biarkan PRIVATE: jangan aktifkan
  "Public access" / r2.dev.

LANGKAH 2 - Catat Account ID
  Di halaman R2 Object Storage (Overview), bagian "Account Details" -> Account ID
  (32 karakter heksadesimal). Account ID juga terlihat di URL dashboard
  (dash.cloudflare.com/<ACCOUNT_ID>/...).

LANGKAH 3 - Buat API token
  R2 Object Storage -> "Manage API tokens" -> Create API Token
  ("Account API token" disarankan; "User API token" juga bisa):
    - Permissions      : Object Read & Write
    - Specify bucket(s): Apply to specific buckets only -> pilih bucket langkah 1
    - TTL              : Forever (atau sesuai kebijakan Anda)
  Klik Create, lalu salin "Access Key ID" dan "Secret Access Key".
  Secret hanya ditampilkan SEKALI; simpan sebelum menutup halaman.
  (Bagian "Token value" tidak dipakai di sini.)

Kosongkan isian untuk memakai nilai lama (jika ada).
EOF
  read -r -p "Account ID [${R2_ACCOUNT_ID:-}]: " acc; acc=${acc:-$R2_ACCOUNT_ID}
  [[ "$acc" =~ ^[A-Za-z0-9]+$ ]] || { err "Account ID tidak valid."; return 1; }
  read -r -p "Access Key ID [${R2_ACCESS_KEY_ID:+(tersimpan)}]: " key; key=${key:-$R2_ACCESS_KEY_ID}
  [[ "$key" =~ ^[A-Za-z0-9]+$ ]] || { err "Access Key ID tidak valid."; return 1; }
  read -r -s -p "Secret Access Key [${R2_SECRET_ACCESS_KEY:+(tersimpan)}]: " secret; echo; secret=${secret:-$R2_SECRET_ACCESS_KEY}
  [[ "$secret" =~ ^[A-Za-z0-9+/=]+$ ]] || { err "Secret Access Key tidak valid."; return 1; }
  read -r -p "Nama bucket [${R2_BUCKET:-}]: " bucket; bucket=${bucket:-$R2_BUCKET}
  [[ "$bucket" =~ ^[a-z0-9][a-z0-9-]{1,62}$ ]] || { err "Nama bucket tidak valid (huruf kecil, angka, '-')."; return 1; }
  local def_prefix=${R2_PREFIX:-mysql/$(hostname -s 2>/dev/null || echo server)}
  read -r -p "Prefix/folder di bucket [$def_prefix]: " prefix; prefix=${prefix:-$def_prefix}; prefix=${prefix%/}; prefix=${prefix#/}
  [[ "$prefix" =~ ^[A-Za-z0-9._/-]*$ ]] || { err "Prefix tidak valid."; return 1; }
  local def_ep=${R2_ENDPOINT:-https://${acc}.r2.cloudflarestorage.com}
  echo "Endpoint (bucket jurisdiction EU: https://${acc}.eu.r2.cloudflarestorage.com)"
  read -r -p "Endpoint [$def_ep]: " endpoint; endpoint=${endpoint:-$def_ep}; endpoint=${endpoint%/}
  [[ "$endpoint" =~ ^https?://[A-Za-z0-9.:-]+$ ]] || { err "Endpoint tidak valid."; return 1; }
  read -r -p "Retensi di R2, hari [${R2_RETENTION_DAYS:-30}] (0 = tidak pernah hapus): " ret; ret=${ret:-${R2_RETENTION_DAYS:-30}}
  [[ "$ret" =~ ^[0-9]+$ ]] || { err "Retensi harus angka."; return 1; }
  engine=${R2_RCLONE:-docker}
  if [[ "$engine" == "docker" ]] && command -v rclone >/dev/null 2>&1; then
    local rv rmaj rmin
    rv=$(rclone version 2>/dev/null | head -n1 | grep -oE '[0-9]+\.[0-9]+' | head -n1 || true)
    rmaj=${rv%%.*}; rmin=${rv#*.}
    if [[ "$rv" =~ ^[0-9]+\.[0-9]+$ ]] && (( rmaj > 1 || (rmaj == 1 && rmin >= 59) )); then
      read -r -p "rclone $rv terpasang di host. Pakai rclone host, bukan container? [y/N]: " ret2
      [[ "${ret2,,}" == "y" ]] && engine=host
    else
      echo "Catatan: rclone di host (versi ${rv:-?}) terlalu lama untuk R2 (butuh 1.59+); dipakai container rclone."
    fi
  fi

  local tmp; tmp=$(mktemp "$BASE_DIR/.r2conf.XXXXXX")
  cat > "$tmp" <<EOF
R2_ACCOUNT_ID=$acc
R2_ACCESS_KEY_ID=$key
R2_SECRET_ACCESS_KEY=$secret
R2_BUCKET=$bucket
R2_PREFIX=$prefix
R2_ENDPOINT=$endpoint
R2_RETENTION_DAYS=$ret
R2_RCLONE=$engine
R2_RCLONE_IMAGE=${R2_RCLONE_IMAGE:-$RCLONE_IMAGE_DEFAULT}
EOF
  chmod 600 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$R2_CONF"
  echo "Tersimpan di $R2_CONF (permission 600)."
  r2_test
}

# Tes tulis -> baca -> hapus satu objek kecil.
r2_test() {
  load_r2_conf || { err "R2 belum dikonfigurasi."; return 1; }
  local probe
  mkdir -p "$BACKUP_DIR"
  probe=$(mktemp "$BACKUP_DIR/.r2-test.XXXXXX")
  echo "qolcore r2 test $(date -u +%FT%TZ)" > "$probe"
  echo "Tes koneksi ke $(r2_path "") ..."
  if rclone_run copyto "$probe" "$(r2_path "")/.r2-test" \
     && rclone_run lsf "$(r2_path "")" --files-only --include .r2-test | grep -qx '.r2-test' \
     && rclone_run deletefile "$(r2_path "")/.r2-test"; then
    rm -f -- "$probe"; echo "Koneksi R2 OK (tulis, baca, hapus berhasil)."
  else
    rm -f -- "$probe"; err "Tes R2 gagal. Periksa Account ID, key, bucket, dan izin token."; return 1
  fi
}

r2_browse_download() {
  load_r2_conf || { err "R2 belum dikonfigurasi."; return 1; }
  local sub listing pick name i=0 files=()
  read -r -p "Folder di R2: 1) auto  2) manual [1]: " sub
  [[ "$sub" == "2" ]] && sub=manual || sub=auto
  listing=$(rclone_run lsf "$(r2_path "$sub")" --files-only --format "tsp" --separator ";" | sort -r | head -n 30) || return 1
  [[ -n "$listing" ]] || { echo "Tidak ada file di $(r2_path "$sub")."; return 0; }
  echo "30 file terbaru di $(r2_path "$sub"):"
  while IFS=';' read -r ts size name; do
    i=$((i+1)); files+=("$name")
    printf '  %2d. %s  %10s  %s\n' "$i" "$ts" "$(numfmt --to=iec "$size" 2>/dev/null || echo "$size")" "$name"
  done <<< "$listing"
  read -r -p "Nomor file yang di-download (kosong = batal): " pick
  [[ -n "$pick" ]] || return 0
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#files[@]} )) || { err "Pilihan tidak valid."; return 1; }
  name=${files[$((pick-1))]}
  mkdir -p "$DOWNLOAD_DIR"; chmod 700 "$DOWNLOAD_DIR"
  rclone_run copyto "$(r2_path "$sub")/$name" "$DOWNLOAD_DIR/$name" || { err "Download gagal."; return 1; }
  chmod 600 "$DOWNLOAD_DIR/$name"
  echo "Tersimpan: $DOWNLOAD_DIR/$name"
  [[ "$name" == *.sql.gz ]] && echo "Untuk restore: menu 7 (file hasil download ikut muncul di daftar)."
  return 0
}

# --- Konfigurasi auto backup (dibaca sebagai data, bukan di-source) ---------
load_backup_conf() {
  BACKUP_DATABASES="all"; BACKUP_RETENTION_DAYS=14; BACKUP_TIME="02:30"; BACKUP_TARGET="local"
  [[ -f "$BACKUP_CONF" ]] || return 0
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//[[:space:]]/}; value=${value//$'\r'/}
    case "$key" in
      BACKUP_DATABASES)      if [[ "$value" =~ ^[A-Za-z0-9_,]+$ ]]; then BACKUP_DATABASES=$value; fi ;;
      BACKUP_RETENTION_DAYS) if [[ "$value" =~ ^[0-9]+$ ]]; then BACKUP_RETENTION_DAYS=$value; fi ;;
      BACKUP_TIME)           if [[ "$value" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; then BACKUP_TIME=$value; fi ;;
      BACKUP_TARGET)         if [[ "$value" =~ ^(local|r2|both)$ ]]; then BACKUP_TARGET=$value; fi ;;
    esac
  done < "$BACKUP_CONF"
}

target_label() {
  case "$1" in
    local) echo "lokal saja" ;;
    r2)    echo "R2 saja (file lokal dihapus setelah upload berhasil)" ;;
    both)  echo "lokal + R2" ;;
  esac
}

# Hapus backup otomatis lokal yang lebih tua dari N hari, tapi SELALU sisakan file
# terbaru tiap database (supaya tidak pernah habis walau backup sempat gagal lama).
prune_backups() {
  local days=$1 dir=${2:-$AUTO_DIR} db f newest dbs=()
  (( days > 0 )) || return 0
  [[ -d "${dir:?}" ]] || return 0
  find "${dir:?}" -maxdepth 1 -type f -name '*.partial' -mmin +360 -delete 2>/dev/null || true
  mapfile -t dbs < <(find "${dir:?}" -maxdepth 1 -type f -name '*.sql.gz' -printf '%f\n' \
                     | sed -E 's/-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.sql\.gz$//' | sort -u)
  for db in "${dbs[@]}"; do
    valid_dbname "$db" || continue
    newest=$(find "${dir:?}" -maxdepth 1 -type f -name "${db}-*.sql.gz" -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
    while IFS= read -r f; do
      [[ -n "$f" && "$f" != "$newest" ]] || continue
      rm -f -- "$f" && log "Hapus backup lama: $f"
    done < <(find "${dir:?}" -maxdepth 1 -type f -name "${db}-*.sql.gz" -mmin +"$((days * 1440))")
  done
  newest=$(find "${dir:?}" -maxdepth 1 -type f -name 'users-*.sql' -printf '%T@ %p\n' | sort -nr | head -n1 | cut -d' ' -f2-)
  while IFS= read -r f; do
    [[ -n "$f" && "$f" != "$newest" ]] || continue
    rm -f -- "$f"
  done < <(find "${dir:?}" -maxdepth 1 -type f -name 'users-*.sql' -mmin +"$((days * 1440))")
}

# Dipanggil oleh scheduler: `mysql-manager backup-auto`. Non-interaktif.
backup_auto() {
  local db failed=0 ok=0 dbs=() upload_ok=1
  # Kunci pada folder itu sendiri (dibuka read-only): tidak ada file lock yang bisa
  # dibelokkan lewat symlink untuk menimpa file lain sebagai root.
  exec 9<"$BASE_DIR"
  flock -n 9 || { err "Backup lain sedang berjalan; dilewati."; return 1; }
  base_dir_safe || return 1
  load_backup_conf
  # Instance lokal opsional: manager bisa dipakai murni untuk backup server remote.
  local local_on=0
  if [[ -f "$ENV_FILE" ]]; then
    if load_config && container_running; then
      local_on=1
    else
      err "Instance lokal tidak berjalan; backup lokal dilewati."; failed=1
    fi
  fi
  if [[ "$BACKUP_TARGET" != "local" ]] && ! r2_configured; then
    err "Target '$BACKUP_TARGET' butuh R2, tetapi $R2_CONF belum lengkap. Backup tetap disimpan lokal."
    failed=1; upload_ok=0
  fi
  if (( local_on )); then
    if [[ "$BACKUP_DATABASES" == "all" ]]; then
      mapfile -t dbs < <(list_app_databases)
    else
      IFS=',' read -r -a dbs <<< "$BACKUP_DATABASES"
    fi
    if (( ${#dbs[@]} == 0 )); then err "Instance lokal: tidak ada database untuk di-backup (atau gagal membaca daftar database)."; failed=1; fi
    log "Auto backup mulai: ${dbs[*]} (target: $(target_label "$BACKUP_TARGET"))"
    for db in "${dbs[@]}"; do
      [[ -n "$db" ]] || continue
      if ! valid_dbname "$db" || ! db_exists "$db"; then
        err "Database '$db' tidak ditemukan; dilewati."; failed=1; continue
      fi
      if do_backup "$db" "$AUTO_DIR" >/dev/null; then ok=$((ok+1)); else failed=1; fi
    done
    do_users_backup "$AUTO_DIR" >/dev/null || failed=1
  fi
  # Profil server remote dengan auto: yes.
  remote_auto_backup || failed=1
  ok=$((ok + RA_OK))
  if (( ! local_on )) && (( RA_PROFILES == 0 )); then
    err "Tidak ada yang di-backup: instance lokal belum di-setup/berjalan dan tidak ada profil remote dengan auto: yes."
    return 1
  fi

  # Upload dulu, baru retensi lokal: file yang belum ter-upload tidak dihapus duluan.
  if [[ "$BACKUP_TARGET" != "local" ]] && r2_configured; then
    upload_ok=0
    local mode=copy
    [[ "$BACKUP_TARGET" == "r2" ]] && mode=move
    if r2_sync_auto "$mode" && remote_r2_sync "$mode"; then
      upload_ok=1
      log "Upload R2 berhasil."
      r2_prune "$R2_RETENTION_DAYS" || failed=1
      remote_r2_prune "$R2_RETENTION_DAYS" || failed=1
    else
      err "Upload ke R2 gagal; file tetap disimpan lokal dan akan dicoba lagi pada run berikutnya."
      failed=1
    fi
  fi
  # Retensi lokal hanya kalau ada backup baru yang berhasil.
  if (( ok > 0 )) && (( upload_ok )); then
    prune_backups "$BACKUP_RETENTION_DAYS"
    remote_prune "$BACKUP_RETENTION_DAYS"
  elif (( ok > 0 )); then
    log "Retensi lokal dilewati: upload R2 gagal, backup lokal lama disimpan sampai berhasil ter-upload."
  fi
  if (( failed == 0 )); then
    log "Auto backup selesai: $ok database OK"
  else
    log "Auto backup selesai: $ok database di-dump, ADA YANG GAGAL"
  fi
  return "$failed"
}

has_systemd() { [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; }

schedule_status() {
  load_backup_conf
  echo "Konfigurasi : database=$BACKUP_DATABASES, jam=$BACKUP_TIME, retensi lokal=$BACKUP_RETENTION_DAYS hari"
  echo "Target      : $(target_label "$BACKUP_TARGET")"
  if r2_configured; then
    echo "R2          : $(r2_path "") (retensi $R2_RETENTION_DAYS hari, rclone: $R2_RCLONE)"
  else
    echo "R2          : belum dikonfigurasi"
  fi
  if tg_configured; then
    echo "Telegram    : aktif (kirim saat: $([[ "$TG_NOTIFY" == always ]] && echo 'setiap backup' || echo 'gagal saja'))"
  else
    echo "Telegram    : belum dikonfigurasi"
  fi
  local rp=() p n=0
  mapfile -t rp < <(list_profiles)
  for p in "${rp[@]}"; do load_profile "$p" 2>/dev/null && [[ "$R_AUTO" == yes ]] && n=$((n+1)); done
  echo "Remote      : ${#rp[@]} profil, $n ikut auto backup (menu server remote)"
  echo "Folder lokal: $AUTO_DIR"
  if has_systemd && systemctl is-enabled "$SYSTEMD_UNIT.timer" >/dev/null 2>&1; then
    echo "Scheduler   : systemd timer AKTIF"
    systemctl list-timers "$SYSTEMD_UNIT.timer" --no-pager 2>/dev/null | head -n2 || true
    echo "Hasil terakhir: $(systemctl show -p Result --value "$SYSTEMD_UNIT.service" 2>/dev/null || true)"
  elif [[ -f "$CRON_FILE" ]]; then
    echo "Scheduler   : cron AKTIF ($CRON_FILE)"
  else
    echo "Scheduler   : TIDAK AKTIF"
  fi
  if [[ -d "$AUTO_DIR" ]]; then
    echo "Backup lokal terbaru:"
    find "$AUTO_DIR" -maxdepth 1 -type f -name '*.sql.gz' -printf '%TY-%Tm-%Td %TH:%TM  %10s  %f\n' | sort -r | head -n 5 | sed 's/^/  /'
  fi
}

schedule_enable() {
  load_config 2>/dev/null || true
  load_backup_conf
  local t r d hh mm tg
  read -r -p "Jam backup harian (HH:MM, zona waktu server) [$BACKUP_TIME]: " t; t=${t:-$BACKUP_TIME}
  [[ "$t" =~ ^([01][0-9]|2[0-3]):([0-5][0-9])$ ]] || { err "Format jam harus HH:MM."; return 1; }
  hh=${BASH_REMATCH[1]}; mm=${BASH_REMATCH[2]}
  echo "Database: 'all' = semua database aplikasi (termasuk yang dibuat nanti), atau daftar dipisah koma."
  read -r -p "Database [$BACKUP_DATABASES]: " d; d=${d:-$BACKUP_DATABASES}
  d=${d// /}
  [[ "$d" == "all" || "$d" =~ ^[A-Za-z_][A-Za-z0-9_]*(,[A-Za-z_][A-Za-z0-9_]*)*$ ]] || { err "Daftar database tidak valid."; return 1; }
  echo "Tujuan backup:"
  echo "  1. Lokal saja"
  echo "  2. R2 saja   (dump dibuat lokal sementara, dihapus setelah upload berhasil)"
  echo "  3. Lokal + R2"
  local cur=1; [[ "$BACKUP_TARGET" == "r2" ]] && cur=2; [[ "$BACKUP_TARGET" == "both" ]] && cur=3
  read -r -p "Pilihan [$cur]: " tg; tg=${tg:-$cur}
  case "$tg" in 1) tg=local ;; 2) tg=r2 ;; 3) tg=both ;; *) err "Pilihan tidak valid."; return 1 ;; esac
  if [[ "$tg" != "local" ]] && ! r2_configured; then
    echo "R2 belum dikonfigurasi. Isi kredensial R2 sekarang:"
    r2_configure || { err "Konfigurasi R2 gagal; jadwal tidak diubah."; return 1; }
  fi
  if [[ "$tg" == "r2" ]]; then
    r=$BACKUP_RETENTION_DAYS
  else
    read -r -p "Simpan backup lokal berapa hari [$BACKUP_RETENTION_DAYS] (0 = tidak pernah hapus): " r; r=${r:-$BACKUP_RETENTION_DAYS}
    [[ "$r" =~ ^[0-9]+$ ]] || { err "Retensi harus angka."; return 1; }
  fi

  printf 'BACKUP_DATABASES=%s\nBACKUP_RETENTION_DAYS=%s\nBACKUP_TIME=%s\nBACKUP_TARGET=%s\n' "$d" "$r" "$t" "$tg" > "$BACKUP_CONF"
  chmod 600 "$BACKUP_CONF"; chown root:root "$BACKUP_CONF"
  mkdir -p "$AUTO_DIR"; chmod 700 "$AUTO_DIR"

  # Scheduler menjalankan SALINAN script milik root, bukan file di folder user,
  # supaya file yang bisa diedit user biasa tidak pernah dieksekusi sebagai root.
  install -o root -g root -m 0755 "$SCRIPT_PATH" "$INSTALLED_BIN"
  echo "Script dipasang ke $INSTALLED_BIN"

  if has_systemd; then
    rm -f -- "$CRON_FILE"
    cat > "/etc/systemd/system/$SYSTEMD_UNIT.service" <<EOF
[Unit]
Description=MySQL auto backup ($BASE_DIR)
After=docker.service network-online.target
Wants=network-online.target
Requires=docker.service

[Service]
Type=oneshot
Environment=MYM_BASE_DIR=$BASE_DIR
ExecStart=$INSTALLED_BIN backup-auto
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
EOF
    cat > "/etc/systemd/system/$SYSTEMD_UNIT.timer" <<EOF
[Unit]
Description=Jadwal MySQL auto backup ($BASE_DIR)

[Timer]
OnCalendar=*-*-* $hh:$mm:00
Persistent=true
RandomizedDelaySec=120

[Install]
WantedBy=timers.target
EOF
    chmod 644 "/etc/systemd/system/$SYSTEMD_UNIT.service" "/etc/systemd/system/$SYSTEMD_UNIT.timer"
    systemctl daemon-reload
    systemctl enable --now "$SYSTEMD_UNIT.timer"
    echo "Systemd timer aktif setiap hari jam $t, tujuan: $(target_label "$tg")."
    echo "Jika server mati saat jadwal, backup dijalankan begitu server hidup lagi."
  else
    cat > "$CRON_FILE" <<EOF
# Dibuat oleh mysql-manager
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
$((10#$mm)) $((10#$hh)) * * * root MYM_BASE_DIR=$BASE_DIR $INSTALLED_BIN backup-auto >> $AUTO_DIR/backup.log 2>&1
EOF
    chmod 644 "$CRON_FILE"
    echo "Cron aktif setiap hari jam $t, tujuan: $(target_label "$tg") (log: $AUTO_DIR/backup.log)"
  fi
  echo
  echo "Catatan: jika mysql-manager.sh diperbarui, jalankan menu ini lagi agar salinan"
  echo "di $INSTALLED_BIN ikut diperbarui."
}

schedule_disable() {
  if has_systemd; then
    systemctl disable --now "$SYSTEMD_UNIT.timer" 2>/dev/null || true
    rm -f -- "/etc/systemd/system/$SYSTEMD_UNIT.timer" "/etc/systemd/system/$SYSTEMD_UNIT.service"
    systemctl daemon-reload
  fi
  rm -f -- "$CRON_FILE"
  echo "Auto backup dinonaktifkan. File backup yang sudah ada (lokal & R2) tidak dihapus."
}

schedule_logs() {
  if has_systemd; then
    journalctl -u "$SYSTEMD_UNIT.service" -n 50 --no-pager
  elif [[ -f "$AUTO_DIR/backup.log" ]]; then
    tail -n 50 "$AUTO_DIR/backup.log"
  else
    echo "Belum ada log."
  fi
}

schedule_menu() {
  local c
  schedule_status
  echo
  echo "  1. Aktifkan / ubah jadwal & tujuan (lokal / R2 / lokal + R2)"
  echo "  2. Nonaktifkan jadwal"
  echo "  3. Jalankan auto backup sekarang (tes)"
  echo "  4. Lihat log auto backup"
  echo "  5. Atur kredensial Cloudflare R2"
  echo "  6. Tes koneksi R2"
  echo "  7. Lihat & download backup dari R2"
  echo "  8. Atur notifikasi Telegram"
  echo "  9. Tes notifikasi Telegram"
  echo " 10. Matikan notifikasi Telegram"
  echo "  0. Kembali"
  read -r -p "Pilihan: " c
  case "$c" in
    1) schedule_enable ;;
    2) schedule_disable ;;
    3) backup_auto_notify ;;
    4) schedule_logs ;;
    5) r2_configure ;;
    6) r2_test ;;
    7) r2_browse_download ;;
    8) tg_configure ;;
    9) tg_test ;;
    10) tg_disable ;;
    *) return 0 ;;
  esac
}

# ---------------------------------------------------------------------------
# SERVER REMOTE: backup & restore server MySQL di luar instance lokal ini
# ---------------------------------------------------------------------------
REMOTE_DIR="$BASE_DIR/remotes"          # profil koneksi: remotes/<nama>.conf (root, 600)
RBACKUP_DIR="$BACKUP_DIR/remote"        # backup manual/pengaman: backups/remote/<profil>/
RAUTO_DIR="$AUTO_DIR/remote"            # auto backup: backups/auto/remote/<profil>/
REMOTE_SSL_MODES="DISABLED PREFERRED REQUIRED VERIFY_CA VERIFY_IDENTITY"

valid_profile() { [[ "$1" =~ ^[a-z0-9][a-z0-9_-]{0,31}$ ]]; }

list_profiles() {
  local f
  [[ -d "$REMOTE_DIR" ]] || return 0
  for f in "$REMOTE_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    f=$(basename "$f" .conf)
    valid_profile "$f" && printf '%s\n' "$f"
  done
}

# Baca profil sebagai data (tidak di-source). Password disimpan apa adanya (tanpa trim).
load_profile() {
  local name=$1 f key value
  R_NAME="" R_HOST="" R_PORT="3306" R_USER="" R_PASSWORD="" R_SSLMODE="REQUIRED" R_CA=""
  R_MAINTDB="information_schema" R_DATABASES="all" R_AUTO="no" R_CLIENT="auto"
  valid_profile "$name" || { err "Nama profil tidak valid: '$name'"; return 1; }
  f="$REMOTE_DIR/$name.conf"
  [[ -f "$f" ]] || { err "Profil '$name' tidak ditemukan."; return 1; }
  R_NAME=$name
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ "$line" == *=* && "$line" != \#* ]] || continue
    key=${line%%=*}; value=${line#*=}
    case "$key" in
      R_HOST)      if [[ "$value" =~ ^[A-Za-z0-9._:-]{1,253}$ ]]; then R_HOST=$value; fi ;;
      R_PORT)      if [[ "$value" =~ ^[0-9]{1,5}$ ]]; then R_PORT=$value; fi ;;
      R_USER)      if [[ "$value" =~ ^[A-Za-z0-9_.@-]{1,128}$ ]]; then R_USER=$value; fi ;;
      R_PASSWORD)  R_PASSWORD=$value ;;
      R_SSLMODE)   if [[ " $REMOTE_SSL_MODES " == *" $value "* ]]; then R_SSLMODE=$value; fi ;;
      R_CA)        if [[ -z "$value" || "$value" == system || -f "$value" ]]; then R_CA=$value; fi ;;
      R_MAINTDB)   if valid_dbname "$value"; then R_MAINTDB=$value; fi ;;
      R_DATABASES) if [[ "$value" == all || "$value" =~ ^[A-Za-z0-9_\$-]+(,[A-Za-z0-9_\$-]+)*$ ]]; then R_DATABASES=$value; fi ;;
      R_AUTO)      if [[ "$value" == yes || "$value" == no ]]; then R_AUTO=$value; fi ;;
      R_CLIENT)    if [[ "$value" == auto || "$value" == host || "$value" == docker ]]; then R_CLIENT=$value; fi ;;
    esac
  done < "$f"
  [[ -n "$R_HOST" && -n "$R_USER" ]] || { err "Profil '$name' tidak lengkap (host/user)."; return 1; }
  RC_MODE="" RC_IMAGE="" RS_VERSION="" RS_MAJOR="" RC_EXTRA_DONE=""
}

save_profile() {
  local name=$1 tmp
  mkdir -p "$REMOTE_DIR"; chown root:root "$REMOTE_DIR"; chmod 700 "$REMOTE_DIR"
  tmp=$(mktemp "$REMOTE_DIR/.profile.XXXXXX")
  {
    printf 'R_HOST=%s\nR_PORT=%s\nR_USER=%s\n' "$R_HOST" "$R_PORT" "$R_USER"
    printf 'R_PASSWORD=%s\n' "$R_PASSWORD"
    printf 'R_SSLMODE=%s\nR_CA=%s\nR_MAINTDB=%s\n' "$R_SSLMODE" "$R_CA" "$R_MAINTDB"
    printf 'R_DATABASES=%s\nR_AUTO=%s\nR_CLIENT=%s\n' "$R_DATABASES" "$R_AUTO" "$R_CLIENT"
  } > "$tmp"
  chmod 600 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$REMOTE_DIR/$name.conf"
}

# Pilih profil secara interaktif; hasil di variabel PICKED_PROFILE.
pick_profile() {
  local -a ps=(); local p i=0 pick
  mapfile -t ps < <(list_profiles)
  (( ${#ps[@]} > 0 )) || { err "Belum ada profil server remote. Tambahkan lewat menu 'Tambah / ubah profil'."; return 1; }
  for p in "${ps[@]}"; do
    i=$((i+1))
    if load_profile "$p" 2>/dev/null; then
      printf '  %d. %-16s %s@%s:%s  (db: %s, auto: %s)\n' "$i" "$p" "$R_USER" "$R_HOST" "$R_PORT" "$R_DATABASES" "$R_AUTO"
    else
      printf '  %d. %-16s (profil rusak)\n' "$i" "$p"
    fi
  done
  read -r -p "${1:-Pilih profil}: " pick
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#ps[@]} )) || { err "Pilihan tidak valid."; return 1; }
  PICKED_PROFILE=${ps[$((pick-1))]}
  load_profile "$PICKED_PROFILE"
}

rprofile_list() {
  local -a ps=(); local p
  mapfile -t ps < <(list_profiles)
  (( ${#ps[@]} > 0 )) || { echo "Belum ada profil server remote."; return 0; }
  printf '%-16s %-34s %-16s %-14s %-5s %s\n' "PROFIL" "SERVER" "SSL" "DATABASE" "AUTO" "KLIEN"
  for p in "${ps[@]}"; do
    if load_profile "$p" 2>/dev/null; then
      printf '%-16s %-34s %-16s %-14s %-5s %s\n' "$p" "$R_USER@$R_HOST:$R_PORT" "$R_SSLMODE" "$R_DATABASES" "$R_AUTO" "$R_CLIENT"
    else
      printf '%-16s %s\n' "$p" "(profil rusak; ubah atau hapus)"
    fi
  done
}

rprofile_edit() {
  local name pw pw2 v isnew=0 choices
  read -r -p "Nama profil (huruf kecil/angka/-/_, mis. neon-prod): " name
  valid_profile "$name" || { err "Nama profil tidak valid."; return 1; }
  if [[ -f "$REMOTE_DIR/$name.conf" ]]; then
    load_profile "$name" || return 1
    echo "Mengubah profil '$name'. Kosongkan isian untuk memakai nilai lama."
  else
    isnew=1
    R_NAME=$name R_HOST="" R_PORT="3306" R_USER="" R_PASSWORD="" R_SSLMODE="REQUIRED" R_CA=""
    R_MAINTDB="information_schema" R_DATABASES="all" R_AUTO="no" R_CLIENT="auto"
  fi
    cat <<'EOF'
Contoh: VPS lain, Amazon RDS / Aurora MySQL, Google Cloud SQL, Azure Database for MySQL.
Hak akses minimal user backup:
  GRANT SELECT, SHOW VIEW, TRIGGER, LOCK TABLES, EVENT, SHOW_ROUTINE ON *.* TO 'backup'@'%';
  (SHOW_ROUTINE ada di MySQL 8.0.20+; versi lama: SELECT ON mysql.proc)
Untuk restore: hak membuat/menghapus tabel, view, routine, trigger di database tujuan.
Server tujuan harus bisa dijangkau dari server ini (cek firewall/allowlist IP).
EOF
  read -r -p "Host (domain/IP) [${R_HOST}]: " v; v=${v:-$R_HOST}
  [[ "$v" =~ ^[A-Za-z0-9._:-]{1,253}$ ]] || { err "Host tidak valid."; return 1; }
  R_HOST=$v
  read -r -p "Port [${R_PORT}]: " v; v=${v:-$R_PORT}
  [[ "$v" =~ ^[0-9]{1,5}$ ]] && (( 10#$v >= 1 && 10#$v <= 65535 )) || { err "Port tidak valid."; return 1; }
  R_PORT=$((10#$v))
  read -r -p "Username [${R_USER}]: " v; v=${v:-$R_USER}
  [[ "$v" =~ ^[A-Za-z0-9_.@-]{1,128}$ ]] || { err "Username tidak valid."; return 1; }
  R_USER=$v
  read -r -s -p "Password${R_PASSWORD:+ (kosong = pakai yang tersimpan)}: " pw; echo
  if [[ -n "$pw" ]]; then
    read -r -s -p "Ulangi password: " pw2; echo
    [[ "$pw" == "$pw2" ]] || { err "Password tidak cocok."; return 1; }
    R_PASSWORD=$pw
  fi
  [[ -n "$R_PASSWORD" ]] || { err "Password wajib diisi."; return 1; }
  echo "Mode SSL: $REMOTE_SSL_MODES"
    echo "  DISABLED=tanpa SSL | PREFERRED=SSL jika ada | REQUIRED=terenkripsi, tanpa verifikasi |"
  echo "  VERIFY_CA=cek CA (isi file CA) | VERIFY_IDENTITY=cek CA + nama host (paling aman)."
  read -r -p "Mode SSL [${R_SSLMODE}]: " v; v=${v:-$R_SSLMODE}
  [[ " $REMOTE_SSL_MODES " == *" $v "* ]] || { err "Mode SSL tidak dikenal."; return 1; }
  R_SSLMODE=$v
  read -r -p "File CA untuk verifikasi (kosong = tidak ada${R_CA:+, '-' = hapus}; 'system' = CA bawaan OS) [${R_CA}]: " v
  if [[ "$v" == "-" ]]; then R_CA=""; elif [[ -n "$v" ]]; then
    if [[ "$v" != system ]]; then v=$(expand_path "$v"); [[ -r "$v" ]] || { err "File CA tidak bisa dibaca: $v"; return 1; }; fi
    R_CA=$v
  fi
  
  read -r -p "Database yang di-backup: 'all' atau daftar dipisah koma [${R_DATABASES}]: " v; v=${v:-$R_DATABASES}; v=${v// /}
  [[ "$v" == all || "$v" =~ ^[A-Za-z0-9_\$-]+(,[A-Za-z0-9_\$-]+)*$ ]] || { err "Daftar database tidak valid."; return 1; }
  R_DATABASES=$v
  read -r -p "Ikut auto backup terjadwal (menu auto backup)? yes/no [${R_AUTO}]: " v; v=${v:-$R_AUTO}
  [[ "$v" == yes || "$v" == no ]] || { err "Isi yes atau no."; return 1; }
  R_AUTO=$v
  echo "Klien dump: auto = pakai klien di host jika versinya cocok, selain itu container Docker."
  read -r -p "Klien (auto/host/docker) [${R_CLIENT}]: " v; v=${v:-$R_CLIENT}
  [[ "$v" == auto || "$v" == host || "$v" == docker ]] || { err "Pilihan klien tidak valid."; return 1; }
  R_CLIENT=$v
  save_profile "$name"
  echo "Profil '$name' $( (( isnew )) && echo dibuat || echo diperbarui ) di $REMOTE_DIR/$name.conf (permission 600)."
  load_profile "$name" && rb_test
}

rprofile_delete() {
  local confirm
  pick_profile "Pilih profil yang dihapus" || return 1
  read -r -p "Ketik nama profil ($PICKED_PROFILE) untuk menghapus profil (file backup tidak ikut dihapus): " confirm
  [[ "$confirm" == "$PICKED_PROFILE" ]] || { echo "Dibatalkan."; return 0; }
  rm -f -- "$REMOTE_DIR/$PICKED_PROFILE.conf"
  echo "Profil '$PICKED_PROFILE' dihapus. Backup di $RBACKUP_DIR/$PICKED_PROFILE dan $RAUTO_DIR/$PICKED_PROFILE tetap ada."
}

rprofile_test() { pick_profile "Pilih profil yang dites" || return 1; rb_test; }

# Daftar database yang di-backup untuk profil aktif (R_DATABASES atau semua yang terlihat).
profile_db_list() {
  if [[ "$R_DATABASES" == all ]]; then
    rb_list_dbs
  else
    tr ',' '\n' <<< "$R_DATABASES"
  fi
}

remote_backup_now() {
  local db file failed=0 up dbs=() files=() d dir
  pick_profile "Pilih profil yang di-backup" || return 1
  rb_probe || return 1
  echo "Database di server ini:"
  rb_list_dbs | sed 's/^/  - /'
  read -r -p "Database yang di-backup (kosong = sesuai profil: $R_DATABASES): " db
  if [[ -n "$db" ]]; then
    valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
    dbs=("$db")
  else
    mapfile -t dbs < <(profile_db_list)
  fi
  (( ${#dbs[@]} > 0 )) || { err "Tidak ada database untuk di-backup."; return 1; }
  dir="$RBACKUP_DIR/$R_NAME"
  for d in "${dbs[@]}"; do
    [[ -n "$d" ]] || continue
    if file=$(rb_backup_db "$d" "$dir"); then echo "OK    $file ($(du -h "$file" | cut -f1))"; files+=("$file"); else echo "GAGAL $d"; failed=1; fi
  done
  if file=$(rb_backup_globals "$dir"); then files+=("$file"); fi
  if (( ${#files[@]} > 0 )) && r2_configured; then
    read -r -p "Upload juga ke R2 (folder manual/remote/$R_NAME/)? [y/N]: " up
    if [[ "${up,,}" == "y" ]]; then
      if r2_upload_files "manual/remote/$R_NAME" "${files[@]}"; then echo "Upload ke R2 selesai."; else err "Upload ke R2 gagal; file lokal tetap ada."; failed=1; fi
    fi
  fi
  (( failed == 0 ))
}

remote_restore_now() {
  local file rc t confirm
  echo "Pilih file backup (backup lokal, remote, dan R2 ditampilkan semua)."
  rc=0; file=$(pick_backup) || rc=$?
  (( rc != 2 )) || { echo "Dibatalkan."; return 0; }
  (( rc == 0 )) || return 1
  [[ -f "$file" && -r "$file" ]] || { err "File tidak ditemukan / tidak bisa dibaca: $file"; return 1; }
  echo "File: $file"
  echo
  echo "Restore ke mana?"
  echo "  0. Instance MySQL lokal di server ini (yang dikelola script ini)"
  echo "  atau pilih profil server remote:"
  local -a ps=(); local p i=0
  mapfile -t ps < <(list_profiles)
  for p in "${ps[@]}"; do i=$((i+1)); printf '  %d. %s\n' "$i" "$p"; done
  read -r -p "Tujuan: " t
  if [[ "$t" == 0 ]]; then
    [[ -f "$ENV_FILE" ]] || { err "Instance lokal belum di-setup (menu 1)."; return 1; }
    restore_database "$file"
    return $?
  fi
  [[ "$t" =~ ^[0-9]+$ ]] && (( t >= 1 && t <= ${#ps[@]} )) || { err "Pilihan tidak valid."; return 1; }
  load_profile "${ps[$((t-1))]}" || return 1
  rb_restore_remote "$file"
}

# Dipanggil dari backup_auto: backup semua profil dengan R_AUTO=yes ke $RAUTO_DIR/<profil>/.
# Mengisi RA_PROFILES (jumlah profil) dan RA_OK (jumlah database berhasil).
remote_auto_backup() {
  local p d failed=0 dbs=()
  RA_PROFILES=0 RA_OK=0
  local -a ps=()
  mapfile -t ps < <(list_profiles)
  for p in "${ps[@]}"; do
    load_profile "$p" 2>/dev/null || { err "Profil remote '$p' rusak; dilewati."; failed=1; continue; }
    [[ "$R_AUTO" == yes ]] || continue
    RA_PROFILES=$((RA_PROFILES+1))
    log "Remote '$p' ($R_USER@$R_HOST:$R_PORT): mulai"
    if ! rb_probe >/dev/null; then err "Remote '$p': tidak bisa terhubung."; failed=1; continue; fi
    mapfile -t dbs < <(profile_db_list)
    (( ${#dbs[@]} > 0 )) || { err "Remote '$p': tidak ada database."; failed=1; continue; }
    for d in "${dbs[@]}"; do
      [[ -n "$d" ]] || continue
      valid_dbname "$d" || { err "Remote '$p': nama database tidak valid '$d'."; failed=1; continue; }
      if rb_backup_db "$d" "$RAUTO_DIR/$p" >/dev/null; then RA_OK=$((RA_OK+1)); else failed=1; fi
    done
    rb_backup_globals "$RAUTO_DIR/$p" >/dev/null || true
  done
  return "$failed"
}

remote_auto_dirs() {
  local d
  [[ -d "$RAUTO_DIR" ]] || return 0
  for d in "$RAUTO_DIR"/*/; do
    [[ -d "$d" ]] || continue
    d=${d%/}
    valid_profile "$(basename "$d")" && printf '%s\n' "$d"
  done
}

remote_r2_sync() {
  local mode=$1 d rc=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    r2_sync_auto "$mode" "$d" "auto/remote/$(basename "$d")" || rc=1
  done < <(remote_auto_dirs)
  return "$rc"
}

remote_r2_prune() {
  local days=$1 d rc=0
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    r2_prune "$days" "auto/remote/$(basename "$d")" || rc=1
  done < <(remote_auto_dirs)
  return "$rc"
}

remote_prune() {
  local days=$1 d
  while IFS= read -r d; do
    [[ -n "$d" ]] || continue
    prune_backups "$days" "$d"
  done < <(remote_auto_dirs)
}

remote_menu() {
  local c
  echo "=== Server remote: backup & restore MySQL ==="
  echo "Untuk server MySQL di luar instance lokal (mis. VPS lain, layanan managed)."
  echo "Instance lokal tidak wajib di-setup untuk memakai menu ini."
  echo
  rprofile_list
  echo
  echo "  1. Tambah / ubah profil server"
  echo "  2. Tes koneksi profil"
  echo "  3. Backup sekarang"
  echo "  4. Restore (ke server remote atau instance lokal)"
  echo "  5. Hapus profil"
  echo "  0. Kembali"
  echo "Auto backup terjadwal untuk profil dengan 'auto: yes' berjalan bersama jadwal di menu auto backup."
  read -r -p "Pilihan: " c
  case "$c" in
    1) rprofile_edit ;;
    2) rprofile_test ;;
    3) remote_backup_now ;;
    4) remote_restore_now ;;
    5) rprofile_delete ;;
    *) return 0 ;;
  esac
}

# --- Bagian khusus MySQL ---------------------------------------------------
# Klien: mysqldump/mysql di host jika cocok, selain itu container mysql:<versi server>.
R_CLI="mysql"
R_DUMP="mysqldump"
R_DEF_IMAGE="mysql:8.4"

# Argumen koneksi + SSL untuk profil aktif. <ca_path> = path CA yang terlihat oleh klien.
rc_conn_args() {
  local ca=$1
  RC_ARGS=(--host="$R_HOST" --port="$R_PORT" --user="$R_USER" --default-character-set=utf8mb4)
  RC_ARGS+=(--ssl-mode="$R_SSLMODE")
  if [[ -n "$ca" && "$ca" != system ]]; then RC_ARGS+=(--ssl-ca="$ca"); fi
}

# rc_exec <host|docker> <image> <tool> [args...]; password lewat MYSQL_PWD (bukan argumen).
rc_exec() {
  local mode=$1 image=$2 tool=$3; shift 3
  if [[ "$mode" == host ]]; then
    rc_conn_args "$R_CA"
    MYSQL_PWD="$R_PASSWORD" "$tool" "${RC_ARGS[@]}" "$@"
  else
    local -a dargs=(--rm -i --network host -e MYSQL_PWD)
    if [[ -n "$R_CA" && "$R_CA" != system ]]; then
      dargs+=(-v "$R_CA:/tmp/remote-ca.pem:ro"); rc_conn_args /tmp/remote-ca.pem
    else
      rc_conn_args "$R_CA"
    fi
    ensure_image "$image" || return 1
    MYSQL_PWD="$R_PASSWORD" docker run "${dargs[@]}" --entrypoint "$tool" "$image" "${RC_ARGS[@]}" "$@"
  fi
}

# Pastikan image klien tersedia (pull senyap), supaya pesan pull tidak tercampur output.
ensure_image() {
  docker image inspect "$1" >/dev/null 2>&1 && return 0
  echo "Mengunduh image klien $1 ..." >&2
  docker pull -q "$1" >/dev/null 2>&1 || { err "Gagal mengunduh image $1."; return 1; }
}

# Versi klien di host: "<major>.<minor> <mariadb|mysql>"
host_client_info() {
  command -v "$1" >/dev/null 2>&1 || return 1
  local v; v=$("$1" --version 2>/dev/null) || return 1
  # "mysqldump  Ver 8.0.46-0ubuntu0.24.04.4 ..." / "mariadb-dump  Ver 10.19 Distrib 10.11.14-MariaDB ..."
  local num
  if grep -q 'Distrib ' <<< "$v"; then
    num=$(sed -nE 's/.*Distrib ([0-9]+\.[0-9]+).*/\1/p' <<< "$v" | head -n1)
  else
    num=$(sed -nE 's/.*Ver ([0-9]+\.[0-9]+).*/\1/p' <<< "$v" | head -n1)
  fi
  [[ -n "$num" ]] || return 1
  if grep -qi mariadb <<< "$v"; then echo "$num mariadb"; else echo "$num mysql"; fi
}

rc_probe_client() {
  local info
  info=$(host_client_info "$R_CLI" || true)
  if [[ "$R_CLIENT" != docker && -n "$info" && "$info" == *" mysql" ]]; then
    PROBE_MODE=host PROBE_IMAGE=""
  else
    PROBE_MODE=docker PROBE_IMAGE=$R_DEF_IMAGE
  fi
}

rc_q() { rc_probe_client; rc_exec "$PROBE_MODE" "$PROBE_IMAGE" "$R_CLI" -N -B -e "$1"; }

ver_ge() { # ver_ge <a.b> <c.d>  -> a.b >= c.d
  local a1=${1%%.*} a2=${1#*.} b1=${2%%.*} b2=${2#*.}
  (( a1 > b1 || (a1 == b1 && a2 >= b2) ))
}

rb_probe() {
  local out errf
  errf=$(mktemp)
  if ! out=$(rc_q "SELECT VERSION()" 2>"$errf"); then
    err "Gagal terhubung ke $R_HOST:$R_PORT sebagai $R_USER: $(grep -m1 -E 'ERROR|error' "$errf" || head -n1 "$errf")"
    rm -f -- "$errf"; return 1
  fi
  rm -f -- "$errf"
  RS_VERSION=$(tail -n1 <<< "$out")
  if grep -qi mariadb <<< "$RS_VERSION"; then
    err "Server ini MariaDB ($RS_VERSION). Gunakan mariadb-manager.sh untuk server MariaDB."; return 1
  fi
  RS_MAJOR=$(grep -oE '^[0-9]+\.[0-9]+' <<< "$RS_VERSION")
  [[ -n "$RS_MAJOR" ]] || { err "Versi server tidak dikenali: $RS_VERSION"; return 1; }
}

rc_select() {
  local need=$1 info hv flavor img
  info=$(host_client_info "$R_DUMP" || true)
  hv=${info%% *}; flavor=${info##* }
  if ver_ge "$need" 8.0; then img="mysql:$need"; else img="mysql:8.0"; fi
  case "$R_CLIENT" in
    host)
      [[ -n "$info" ]] || { err "$R_DUMP tidak terpasang di host (klien profil = host)."; return 1; }
      RC_MODE=host RC_IMAGE="" ;;
    docker) RC_MODE=docker RC_IMAGE=$img ;;
    *)
      if [[ -n "$info" && "$flavor" == mysql ]] && ver_ge "$hv" "$need"; then RC_MODE=host RC_IMAGE=""
      else RC_MODE=docker RC_IMAGE=$img; fi ;;
  esac
  if [[ "$RC_MODE" == docker ]] && ! docker image inspect "$RC_IMAGE" >/dev/null 2>&1; then
    docker pull -q "$RC_IMAGE" >/dev/null 2>&1 || { echo "Catatan: image $RC_IMAGE tidak tersedia; memakai $R_DEF_IMAGE." >&2; RC_IMAGE=$R_DEF_IMAGE; }
  fi
}

rc_run() { rc_exec "$RC_MODE" "$RC_IMAGE" "$@"; }

rb_test() {
  echo "Tes koneksi ke $R_USER@$R_HOST:$R_PORT (SSL: $R_SSLMODE)..."
  rb_probe || return 1
  echo "Terhubung. Server: $RS_VERSION"
  rc_select "$RS_MAJOR" || return 1
  echo "Klien dump: $([[ "$RC_MODE" == host ]] && echo "$R_DUMP di host" || echo "container $RC_IMAGE")"
  local c
  c=$(rc_q "SHOW SESSION STATUS LIKE 'Ssl_cipher'" 2>/dev/null | cut -f2)
  echo "Koneksi terenkripsi: $([[ -n "$c" ]] && echo "ya ($c)" || echo "TIDAK")"
  echo "Database yang bisa di-backup:"
  rb_list_dbs | sed 's/^/  - /'
}

rb_list_dbs() {
  rc_q "SELECT schema_name FROM information_schema.schemata WHERE schema_name NOT IN ($SYSTEM_SCHEMAS,'rdsadmin','innodb','tmp') ORDER BY schema_name"
}

rb_db_exists() {
  [[ "$(rc_q "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name=$(sql_literal "$1")" | tr -d '[:space:]')" == "1" ]]
}

# Opsi tambahan yang hanya ada di sebagian versi klien (dicek sekali per run).
rc_dump_extra() {
  if [[ -z "${RC_EXTRA_DONE:-}" ]]; then
    RC_EXTRA=()
    local help
    help=$(rc_exec "$RC_MODE" "$RC_IMAGE" "$R_DUMP" --help 2>/dev/null || true)
    grep -q -- '--set-gtid-purged' <<< "$help" && RC_EXTRA+=(--set-gtid-purged=OFF)
    grep -q -- '--column-statistics' <<< "$help" && RC_EXTRA+=(--column-statistics=0)
    RC_EXTRA_DONE=1
  fi
}

rb_backup_db() {
  local db=$1 dir=$2 ts file tmp
  [[ -n "$RS_MAJOR" ]] || rb_probe >/dev/null || return 1
  [[ -n "$RC_MODE" ]] || rc_select "$RS_MAJOR" || return 1
  rc_dump_extra
  mkdir -p "$dir"; chmod 700 "$dir"
  ts=$(date +%Y%m%d-%H%M%S)
  file="$dir/${db}-${ts}.sql.gz"; [[ -e "$file" ]] && file="$dir/${db}-${ts}-$$.sql.gz"
  tmp="$file.partial"
  log "Backup remote $R_NAME/$db -> $file"
  if ! rc_run "$R_DUMP" --single-transaction --quick --routines --triggers --events --hex-blob \
        --no-tablespaces "${RC_EXTRA[@]}" "$db" | gzip -6 > "$tmp"; then
    rm -f -- "$tmp"; err "$R_DUMP $R_NAME/$db gagal; file parsial dihapus."; return 1
  fi
  if ! gzip -t "$tmp" 2>/dev/null || ! grep -q '^-- Dump completed' < <(gzip -dc "$tmp" | tail -n 1); then
    rm -f -- "$tmp"; err "File backup $R_NAME/$db tidak valid/terpotong; dihapus."; return 1
  fi
  chmod 600 "$tmp"; mv -f "$tmp" "$file"
  printf '%s\n' "$file"
}

# Akun & grant (butuh hak SELECT di mysql.*; di layanan managed biasanya tidak ada).
rb_backup_globals() {
  local dir=$1 file users u h sql=""
  mkdir -p "$dir"; chmod 700 "$dir"
  users=$(rc_q "SELECT CONCAT(user, ' ', host) FROM mysql.user WHERE user NOT IN ($SYSTEM_USERS) AND user NOT IN ('root','rdsadmin','mysql.sys') AND host <> ''" 2>/dev/null) || {
    log "Remote $R_NAME: backup akun user dilewati (tidak ada hak membaca mysql.user; normal di layanan managed)."
    return 1
  }
  [[ -n "$users" ]] || return 1
  while read -r u h; do
    [[ -n "$u" ]] || continue
    sql+=" SHOW CREATE USER $(sql_literal "$u")@$(sql_literal "$h"); SHOW GRANTS FOR $(sql_literal "$u")@$(sql_literal "$h");"
  done <<< "$users"
  file="$dir/users-$(date +%Y%m%d-%H%M%S).sql"
  if { echo "-- Akun user & grant dari $R_NAME ($R_HOST), $(date '+%Y-%m-%d %H:%M:%S')"; rc_q "$sql" | sed 's/$/;/'; } > "$file.partial" 2>/dev/null; then
    chmod 600 "$file.partial"; mv -f "$file.partial" "$file"; printf '%s\n' "$file"
  else
    rm -f -- "$file.partial"; log "Remote $R_NAME: backup akun user gagal (hak akses kurang)."; return 1
  fi
}

rb_restore_remote() {
  local file=$1 db def_db pre confirm c bk fx defmode=1 genfix=0 report probs unfix empty=""
  case "$file" in *.sql|*.sql.gz) ;; *) err "Restore ke MySQL butuh file .sql atau .sql.gz."; return 1 ;; esac
  if [[ "$file" == *.gz ]] && ! gzip -t "$file" 2>/dev/null; then err "Arsip gzip rusak: $file"; return 1; fi
  grep -qiE '^-- (MySQL|MariaDB) dump' < <(dump_cat "$file" 2>/dev/null | head -n 5) || { err "File tidak terlihat seperti hasil mysqldump/mariadb-dump."; return 1; }
  if grep -qE '^(USE |CREATE DATABASE )' < <(dump_cat "$file" 2>/dev/null); then
    err "Dump berisi 'USE'/'CREATE DATABASE' (--databases/--all-databases); restore ke database pilihan tidak aman."
    return 1
  fi
  rb_probe || return 1
  echo "Server tujuan: $R_NAME ($R_USER@$R_HOST:$R_PORT) - $RS_VERSION"
  rc_select "$RS_MAJOR" || return 1
  if command -v python3 >/dev/null 2>&1 && grep -qiE 'GENERATED ALWAYS AS|[[:space:]]AS[[:space:]]*\(.*\)[[:space:]]*(VIRTUAL|STORED|PERSISTENT)' < <(dump_cat "$file" 2>/dev/null); then
    report=$(dump_cat "$file" | python3 -c "$GENFIX_PY" check) || { err "Gagal memeriksa dump."; return 1; }
    probs=$(grep '^PROBLEM ' <<< "$report" | cut -d' ' -f2- || true)
    unfix=$(grep '^UNFIXABLE ' <<< "$report" | cut -d' ' -f2- || true)
    if [[ -n "$unfix" ]]; then
      err "Dump berisi INSERT ke kolom generated yang tidak bisa diperbaiki otomatis:"; sed 's/^/  - /' <<< "$unfix" >&2
      return 1
    fi
    if [[ -n "$probs" ]]; then
      echo "Dump mengisi nilai kolom generated (server akan menolaknya):"
      sed -E 's/^([^ ]+) (.*)$/  - \1.\2/' <<< "$probs"
      read -r -p "Buang nilai kolom tersebut dari INSERT saat restore? [Y/n]: " fx
      [[ "${fx,,}" != "n" ]] || { echo "Dibatalkan."; return 0; }
      genfix=1
    fi
  fi

  def_db=$(db_from_backup_name "$file")
  echo "Database di server tujuan:"
  rb_list_dbs | sed 's/^/  - /'
  read -r -p "Database tujuan${def_db:+ [$def_db]}: " db; db=${db:-$def_db}
  valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
  # DEFINER milik server asal biasanya tidak ada di server tujuan, dan user non-SUPER
  # (layanan managed) tidak boleh memakai DEFINER orang lain -> ganti ke CURRENT_USER.
  if grep -qE 'DEFINER=`[^`]+`@`[^`]+`' < <(dump_cat "$file" 2>/dev/null); then
    echo "Dump berisi view/trigger/routine dengan DEFINER:"
    grep -oE 'DEFINER=`[^`]+`@`[^`]+`' < <(dump_cat "$file" 2>/dev/null) | sort -u | sed 's/^DEFINER=/  - /'
    read -r -p "Ganti semua DEFINER ke CURRENT_USER ($R_USER), disarankan untuk server remote? [Y/n]: " c
    [[ "${c,,}" == "n" ]] && defmode=0
  else
    defmode=0
  fi
  if ! rb_db_exists "$db"; then
    read -r -p "Database '$db' belum ada di $R_NAME. Buat sekarang? [y/N]: " c
    [[ "${c,,}" == "y" ]] || { echo "Dibatalkan."; return 0; }
    rc_q "CREATE DATABASE $(sql_ident "$db") CHARACTER SET utf8mb4" >/dev/null || { err "Gagal membuat database."; return 1; }
  else
    read -r -p "Kosongkan '$db' di $R_NAME dulu (DROP + CREATE; hapus juga tabel yang tidak ada di backup)? [y/N]: " empty
    read -r -p "Backup database '$db' di $R_NAME dulu sebelum ditimpa? [Y/n]: " pre
    if [[ "${pre,,}" != "n" ]]; then
      bk=$(rb_backup_db "$db" "$RBACKUP_DIR/$R_NAME") || { err "Backup pengaman gagal; restore dibatalkan."; return 1; }
      echo "Backup pengaman: $bk"
    fi
  fi
  echo
  echo "PERINGATAN: tabel/objek di $R_NAME/$db yang ada di backup akan DIHAPUS lalu dibuat ulang."
  echo "            Restore tidak atomik: jika gagal di tengah, database bisa ter-restore sebagian."
  read -r -p "Ketik $R_NAME/$db untuk melanjutkan: " confirm
  [[ "$confirm" == "$R_NAME/$db" ]] || { echo "Dibatalkan."; return 0; }
  if [[ "${empty,,}" == "y" ]]; then
    local cs co
    read -r cs co < <(rc_q "SELECT default_character_set_name, default_collation_name FROM information_schema.schemata WHERE schema_name=$(sql_literal "$db")")
    log "Mengosongkan $R_NAME/$db (DROP + CREATE)"
    rc_q "DROP DATABASE $(sql_ident "$db"); CREATE DATABASE $(sql_ident "$db") CHARACTER SET ${cs:-utf8mb4} COLLATE ${co:-utf8mb4_general_ci}" >/dev/null \
      || { err "Gagal mengosongkan database (butuh hak DROP/CREATE DATABASE)."; return 1; }
  fi
  log "Restore $file -> $R_NAME/$db"
  {
    if (( genfix )); then dump_cat "$file" | python3 -c "$GENFIX_PY" fix; else dump_cat "$file"; fi
  } | sed '1{/enable the sandbox mode/d}' | {
    if (( defmode )); then sed -E 's/DEFINER=`[^`]+`@`[^`]+`/DEFINER=CURRENT_USER/g'; else cat; fi
  } | rc_run "$R_CLI" "$db" || {
    err "Restore gagal. $R_NAME/$db mungkin hanya ter-restore sebagian; kembalikan dari backup pengaman jika perlu."
    return 1
  }
  echo "Restore selesai ke $R_NAME/$db."
}

# ---------------------------------------------------------------------------
# NOTIFIKASI TELEGRAM
# ---------------------------------------------------------------------------
TG_CONF="$BASE_DIR/telegram.conf"
TG_API_BASE="${TG_API_BASE:-https://api.telegram.org}"

load_tg_conf() {
  TG_BOT_TOKEN="" TG_CHAT_ID="" TG_NOTIFY="fail"
  [[ -f "$TG_CONF" ]] || return 1
  local key value
  while IFS='=' read -r key value || [[ -n "$key" ]]; do
    key=${key//[[:space:]]/}; value=${value//$'\r'/}
    case "$key" in
      TG_BOT_TOKEN) if [[ "$value" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]]; then TG_BOT_TOKEN=$value; fi ;;
      TG_CHAT_ID)   if [[ "$value" =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]]; then TG_CHAT_ID=$value; fi ;;
      TG_NOTIFY)    if [[ "$value" == "fail" || "$value" == "always" ]]; then TG_NOTIFY=$value; fi ;;
    esac
  done < "$TG_CONF"
  [[ -n "$TG_BOT_TOKEN" && -n "$TG_CHAT_ID" ]]
}

tg_configured() { load_tg_conf 2>/dev/null; }

# Kirim pesan. Token hanya lewat stdin curl (-K -), tidak muncul di daftar proses.
tg_send() {
  local text=$1
  load_tg_conf || { err "Telegram belum dikonfigurasi."; return 1; }
  command -v curl >/dev/null 2>&1 || { err "curl tidak tersedia; notifikasi Telegram tidak bisa dikirim."; return 1; }
  (( ${#text} <= 4000 )) || text="${text:0:3990}…"
  local resp
  resp=$(printf 'url = "%s/bot%s/sendMessage"\n' "$TG_API_BASE" "$TG_BOT_TOKEN" \
    | curl -sS --max-time 20 -K - \
        --data-urlencode "chat_id=$TG_CHAT_ID" \
        --data-urlencode "text=$text" \
        --data-urlencode "disable_web_page_preview=true" 2>&1) || { err "Gagal menghubungi Telegram: $resp"; return 1; }
  if ! grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$resp"; then
    err "Telegram menolak pesan: $(sed -nE 's/.*"description"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$resp" | head -n1)"
    return 1
  fi
}

# Panggil Bot API. Token hanya lewat stdin curl (-K -), tidak muncul di daftar proses.
tg_call() {
  local token=$1 method=$2; shift 2
  command -v curl >/dev/null 2>&1 || { echo '{"ok":false,"description":"curl tidak tersedia di server"}'; return 0; }
  printf 'url = "%s/bot%s/%s"\n' "$TG_API_BASE" "$token" "$method" \
    | curl -sS --max-time 20 -K - "$@" 2>&1 || true
}

tg_ok() { grep -qE '"ok"[[:space:]]*:[[:space:]]*true' <<< "$1"; }
tg_desc() { sed -nE 's/.*"description"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$1" | head -n1; }

# Daftar chat yang pernah mengirim pesan ke bot: "<chat_id><TAB><jenis><TAB><nama>".
tg_find_chats() {
  local token=$1 resp
  resp=$(tg_call "$token" getUpdates --data-urlencode "allowed_updates=[\"message\",\"channel_post\",\"my_chat_member\"]")
  if ! tg_ok "$resp"; then
    echo "ERR	$(tg_desc "$resp")"
    return 0
  fi
  command -v python3 >/dev/null 2>&1 || { echo "ERR	python3 tidak tersedia untuk membaca daftar chat"; return 0; }
  python3 -c '
import json, sys
d = json.load(sys.stdin)
seen = {}
for u in d.get("result", []):
    for k in ("message", "edited_message", "channel_post", "edited_channel_post", "my_chat_member"):
        m = u.get(k)
        if m and "chat" in m:
            c = m["chat"]
            name = c.get("title") or " ".join(x for x in (c.get("first_name"), c.get("last_name")) if x) or c.get("username") or "-"
            if c.get("username") and c.get("type") != "private":
                name += " (@" + c["username"] + ")"
            seen[c["id"]] = (c.get("type", "?"), name)
for cid, (t, n) in seen.items():
    print("%s\t%s\t%s" % (cid, t, n.replace("\t", " ")))
' <<< "$resp"
}

tg_configure() {
  load_tg_conf || true
  command -v curl >/dev/null 2>&1 || { err "curl belum terpasang di server. Pasang dulu (mis. sudo apt install curl), lalu ulangi."; return 1; }
  local token chat mode resp botname rows=() r i pick
  cat <<'EOF'
=== Notifikasi Telegram ===

LANGKAH 1 - Buat bot & ambil token
  1. Buka Telegram, cari @BotFather (akun resmi, ada centang biru), tekan Start.
  2. Kirim perintah:  /newbot
  3. Isi nama bot (bebas, mis. "Backup Server DB").
  4. Isi username bot, harus diakhiri "bot" (mis. qolcore_backup_bot).
  5. BotFather membalas dengan token seperti:
        123456789:AAH4xYz...panjang...
     Salin token itu. RAHASIAKAN: siapa pun yang punya token bisa memakai bot Anda.
     Jika token bocor, kirim /revoke ke @BotFather untuk membuat token baru.

LANGKAH 2 - Ke mana notifikasi dikirim (pilih salah satu)
  - Chat pribadi : buka bot Anda (link t.me/<username_bot> dari BotFather),
                   tekan Start atau kirim pesan apa saja.
  - Grup         : tambahkan bot ke grup, lalu kirim di grup:  /start@<username_bot>
  - Channel      : jadikan bot ADMIN channel (izin "Post messages"),
                   lalu buat satu postingan di channel.
  Bot tidak bisa mengirim pesan ke Anda sebelum langkah 2 dilakukan.

LANGKAH 3 - Script mencari chat ID otomatis dari pesan di langkah 2.
EOF
  echo
  read -r -s -p "Tempel bot token${TG_BOT_TOKEN:+ (kosong = pakai yang tersimpan)}: " token; echo
  token=${token:-$TG_BOT_TOKEN}
  token=${token//[[:space:]]/}
  [[ "$token" =~ ^[0-9]+:[A-Za-z0-9_-]+$ ]] || { err "Format token tidak valid. Contoh: 123456789:AAH4xYz... (angka, titik dua, lalu huruf/angka)."; return 1; }
  resp=$(tg_call "$token" getMe)
  if ! tg_ok "$resp"; then
    err "Token ditolak Telegram: $(tg_desc "$resp")"
    err "Periksa token (salin ulang dari @BotFather) dan pastikan server bisa mengakses api.telegram.org."
    return 1
  fi
  botname=$(sed -nE 's/.*"username"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p' <<< "$resp" | head -n1)
  echo "Token valid. Bot: @${botname:-?}"

  while true; do
    echo
    echo "Pastikan langkah 2 sudah dilakukan (kirim pesan ke @${botname:-bot} / /start@${botname:-bot} di grup)."
    if [[ -n "$TG_CHAT_ID" ]]; then
      read -r -p "Enter = cari chat otomatis | ketik chat ID manual | '-' = pakai yang tersimpan ($TG_CHAT_ID): " chat
    else
      read -r -p "Enter = cari chat otomatis | atau ketik chat ID manual: " chat
    fi
    [[ -z "$chat" ]] || break
    mapfile -t rows < <(tg_find_chats "$token")
    if (( ${#rows[@]} > 0 )) && [[ "${rows[0]}" == ERR* ]]; then
      local why=${rows[0]#ERR	}
      err "Tidak bisa membaca pesan bot: $why"
      [[ "$why" == *webhook* ]] && err "Bot ini memakai webhook (dipakai aplikasi lain). Ketik chat ID manual, atau pakai bot terpisah khusus notifikasi."
      rows=()
    fi
    if (( ${#rows[@]} == 0 )); then
      echo "Belum ada chat yang ditemukan. Kirim pesan ke bot dulu (langkah 2), lalu coba lagi."
      echo "Catatan: Telegram hanya menyimpan pesan bot selama 24 jam terakhir."
      continue
    fi
    echo "Chat yang ditemukan:"
    i=0
    for r in "${rows[@]}"; do
      i=$((i+1)); IFS=$'\t' read -r cid ctype cname <<< "$r"
      printf '  %d. %-16s %-10s %s\n' "$i" "$cid" "$ctype" "$cname"
    done
    read -r -p "Pilih nomor chat (kosong = cari ulang): " pick
    [[ -n "$pick" ]] || continue
    if [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#rows[@]} )); then
      chat=$(cut -f1 <<< "${rows[$((pick-1))]}")
      break
    fi
    echo "Pilihan tidak valid."
  done
  if [[ "$chat" == "-" ]]; then chat=$TG_CHAT_ID; fi
  [[ "$chat" =~ ^(-?[0-9]+|@[A-Za-z0-9_]{5,})$ ]] || { err "Chat ID tidak valid (angka; grup/channel diawali -100; atau @namachannel)."; return 1; }

  echo
  echo "Kirim notifikasi kapan?"
  echo "  1. Hanya jika auto backup gagal"
  echo "  2. Setiap auto backup (berhasil maupun gagal)"
  local cur=1; [[ "$TG_NOTIFY" == "always" ]] && cur=2
  read -r -p "Pilihan [$cur]: " mode; mode=${mode:-$cur}
  case "$mode" in 1) mode=fail ;; 2) mode=always ;; *) err "Pilihan tidak valid."; return 1 ;; esac
  local tmp; tmp=$(mktemp "$BASE_DIR/.tgconf.XXXXXX")
  printf 'TG_BOT_TOKEN=%s\nTG_CHAT_ID=%s\nTG_NOTIFY=%s\n' "$token" "$chat" "$mode" > "$tmp"
  chmod 600 "$tmp"; chown root:root "$tmp"; mv -f "$tmp" "$TG_CONF"
  echo "Tersimpan di $TG_CONF (permission 600)."
  tg_test
}

tg_test() {
  tg_send "✅ Tes notifikasi MySQL manager
Host: $(hostname -s 2>/dev/null || echo '?')
Folder: $BASE_DIR" && echo "Pesan tes terkirim. Cek Telegram Anda."
}

tg_disable() {
  if [[ -f "$TG_CONF" ]]; then
    rm -f -- "$TG_CONF"
    echo "Notifikasi Telegram dimatikan ($TG_CONF dihapus)."
  else
    echo "Notifikasi Telegram belum aktif."
  fi
}

# Jalankan auto backup, simpan log-nya, lalu kirim ringkasan ke Telegram sesuai pengaturan.
backup_auto_notify() {
  local logf rc
  logf=$(mktemp)
  set +e
  ( set -e; backup_auto ) 2>&1 | tee "$logf"
  rc=${PIPESTATUS[0]}
  set -e
  # backup_auto berjalan di subshell; muat ulang konfigurasi untuk isi pesan.
  load_config >/dev/null 2>&1 || true
  if tg_configured && { (( rc != 0 )) || [[ "$TG_NOTIFY" == "always" ]]; }; then
    local status icon body cert_warn
    if (( rc == 0 )); then icon="✅"; status="BERHASIL"; else icon="❌"; status="GAGAL"; fi
    body=$(grep -E 'Backup |GAGAL|ERROR|gagal|selesai|R2|Hapus' "$logf" | sed -E 's/^\[[0-9-]+ ([0-9:]+)\] /\1 /' | tail -n 25)
    cert_warn=$(cert_expiry_warning 2>/dev/null || true)
    tg_send "$icon Auto backup MySQL $status
Host: $(hostname -s 2>/dev/null || echo '?')
Folder: $BASE_DIR
Container: ${MYSQL_CONTAINER:-?}
${cert_warn:+⚠️ $cert_warn
}
$body" >/dev/null || echo "Peringatan: notifikasi Telegram gagal dikirim." >&2
  fi
  rm -f -- "$logf"
  return "$rc"
}

# ---------------------------------------------------------------------------
# UNINSTALL INSTANCE
# ---------------------------------------------------------------------------
# Hapus path di dalam folder proyek saja (pengaman tambahan untuk rm -rf).
safe_rm_in_base() {
  local p
  for p in "$@"; do
    [[ -n "$p" && "$p" == "$BASE_DIR"/* && "$p" != *"/../"* && "$p" != *"/.." ]] || { err "Menolak menghapus path di luar folder proyek: '$p'"; return 1; }
    [[ -e "$p" || -L "$p" ]] || continue
    rm -rf -- "${p:?}"
  done
}

uninstall_instance() {
  load_config || return 1
  local final_bk="" del_data="" del_backups="" confirm="" others=""
  local -a cfg_files=(.env compose.yaml backup.conf r2.conf telegram.conf remotes)
  echo "=== Uninstall instance MySQL ==="
  echo "Folder    : $BASE_DIR"
  echo "Container : $MYSQL_CONTAINER"
  echo
  echo "Yang SELALU dilakukan:"
  echo "  - Menghentikan & menghapus container (docker compose down)"
  echo "  - Mematikan jadwal auto backup instance ini"
  echo "Yang opsional (ditanya satu per satu):"
  echo "  - Backup terakhir semua database sebelum uninstall"
  echo "  - Menghapus data database (data/) beserta konfigurasi (.env, compose.yaml, dll.)"
  echo "  - Menghapus folder backups/"
  echo "Script ini sendiri ($(basename "$SCRIPT_PATH")) tidak dihapus. Backup di R2 tidak disentuh."
  echo

  if container_running; then
    read -r -p "Buat backup terakhir semua database dulu? [Y/n]: " final_bk
    if [[ "${final_bk,,}" != "n" ]]; then
      local d f failed=0 dbs=()
      mapfile -t dbs < <(list_app_databases)
      for d in "${dbs[@]}"; do
        [[ -n "$d" ]] || continue
        if f=$(do_backup "$d"); then echo "OK    $f"; else echo "GAGAL $d"; failed=1; fi
      done
      do_users_backup >/dev/null || failed=1
      if (( failed )); then
        read -r -p "Sebagian backup gagal. Tetap lanjut uninstall? [y/N]: " confirm
        [[ "${confirm,,}" == "y" ]] || { echo "Dibatalkan."; return 0; }
      fi
    fi
  else
    echo "Catatan: container tidak berjalan, backup terakhir tidak bisa dibuat."
  fi

  read -r -p "Hapus juga DATA database (data/) dan konfigurasinya? Tidak bisa dibatalkan. [y/N]: " del_data
  if [[ "${del_data,,}" == "y" ]]; then
    read -r -p "Hapus juga folder backups/ (termasuk semua backup lokal)? [y/N]: " del_backups
  fi

  echo
  echo "Ringkasan:"
  echo "  - Container $MYSQL_CONTAINER dihentikan & dihapus"
  echo "  - Jadwal auto backup dimatikan"
  if [[ "${del_data,,}" == "y" ]]; then
    echo "  - DIHAPUS: data/ dan ${cfg_files[*]}"
  else
    echo "  - Data & konfigurasi DISIMPAN (bisa dijalankan lagi dengan menu 2)"
  fi
  [[ "${del_backups,,}" == "y" ]] && echo "  - DIHAPUS: backups/"
  read -r -p "Ketik nama container ($MYSQL_CONTAINER) untuk melanjutkan: " confirm
  [[ "$confirm" == "$MYSQL_CONTAINER" ]] || { echo "Dibatalkan."; return 0; }
  if [[ "${del_data,,}" == "y" ]]; then
    read -r -p "Ketik HAPUS DATA untuk konfirmasi penghapusan data: " confirm
    [[ "$confirm" == "HAPUS DATA" ]] || { echo "Dibatalkan (tidak ada yang diubah)."; return 0; }
  fi

  log "Mematikan jadwal auto backup"
  schedule_disable >/dev/null 2>&1 || true
  log "docker compose down"
  (cd "$BASE_DIR" && docker compose down --remove-orphans) || { err "docker compose down gagal; tidak ada data yang dihapus."; return 1; }

  # Salinan script untuk scheduler dihapus hanya jika tidak ada instance lain yang memakainya.
  others=$(ls /etc/systemd/system/mym-backup-*.timer /etc/cron.d/mym-backup-* 2>/dev/null || true)
  if [[ -z "$others" && -f "$INSTALLED_BIN" ]]; then
    rm -f -- "$INSTALLED_BIN" && log "Hapus $INSTALLED_BIN (tidak dipakai instance lain)"
  fi

  if [[ "${del_data,,}" == "y" ]]; then
    local -a targets=("$BASE_DIR/data")
    local c
    for c in "${cfg_files[@]}"; do targets+=("$BASE_DIR/$c"); done
    log "Menghapus data & konfigurasi"
    safe_rm_in_base "${targets[@]}" || return 1
    rm -f -- "$BASE_DIR"/.backup.lock
  fi
  if [[ "${del_backups,,}" == "y" ]]; then
    log "Menghapus backups/"
    safe_rm_in_base "$BACKUP_DIR" || return 1
  fi
  echo
  echo "Uninstall selesai."
  if [[ "${del_data,,}" == "y" ]]; then
    echo "Folder $BASE_DIR siap dipakai untuk setup baru (menu 1)."
  else
    echo "Data tetap di $BASE_DIR/data. Jalankan menu 2 untuk menyalakan lagi."
  fi
  [[ "${del_backups,,}" == "y" ]] || echo "Backup lokal tetap di $BACKUP_DIR."
  echo "Image Docker tidak dihapus; hapus manual jika perlu: docker image rm <image>"
}

# ---------------------------------------------------------------------------
# HAPUS DATABASE + USER
# ---------------------------------------------------------------------------
drop_database() {
  require_running || return 1
  local db esc conns ids pre confirm kill drop_users="" u h grants
  local -a exclusive=() shared=()
  echo "Database aplikasi:"
  list_app_databases | sed 's/^/  - /'
  read -r -p "Nama database yang akan DIHAPUS: " db
  valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
  db_exists "$db" || { err "Database '$db' tidak ditemukan."; return 1; }
  case "$db" in mysql|information_schema|performance_schema|sys) err "Database sistem tidak boleh dihapus."; return 1 ;; esac

  # Di mysql.db, '_' pada nama database bisa tersimpan sebagai '\_' (escape wildcard).
  esc=${db//_/\\_}
  # Versi aman-regex untuk dicocokkan di output SHOW GRANTS ('$' adalah metakarakter).
  local dbre=${db//\$/\\\$} escre=${esc//\\/\\\\}
  escre=${escre//\$/\\\$}
  while read -r u h; do
    [[ -n "$u" ]] || continue
    # User eksklusif = selain USAGE, hak aksesnya hanya ke database ini.
    grants=$(mysql_root -N -B --raw -e "SHOW GRANTS FOR $(sql_literal "$u")@$(sql_literal "$h")" \
      | grep -vE '^GRANT USAGE ON \*\.\* TO ' | grep -vE "^GRANT .* ON \`($dbre|$escre)\`\.\* TO " || true)
    if [[ -z "$grants" ]]; then exclusive+=("$u@$h"); else shared+=("$u@$h"); fi
  done < <(mysql_q "SELECT DISTINCT user, host FROM mysql.db WHERE (db=$(sql_literal "$db") OR db=$(sql_literal "$esc")) AND user <> 'root' ORDER BY user, host")

  ids=$(mysql_q "SELECT id FROM information_schema.processlist WHERE db=$(sql_literal "$db") AND id <> CONNECTION_ID()" | tr '\n' ' ')
  conns=$(wc -w <<< "$ids")
  echo "Koneksi aktif   : $conns"
  (( ${#exclusive[@]} )) && echo "User khusus db ini   : ${exclusive[*]}"
  (( ${#shared[@]} )) && echo "User dengan akses lain: ${shared[*]} (hanya hak ke '$db' yang dicabut)"
  if (( conns > 0 )); then
    read -r -p "Ada $conns koneksi aktif. Putuskan semuanya saat menghapus? [y/N]: " kill
    [[ "${kill,,}" == "y" ]] || { echo "Dibatalkan. Hentikan aplikasi yang memakai '$db' dulu."; return 0; }
  fi
  if (( ${#exclusive[@]} )); then
    read -r -p "Hapus juga user khusus database ini (${exclusive[*]})? [Y/n]: " drop_users
    [[ "${drop_users,,}" == "n" ]] && drop_users="" || drop_users=1
  fi
  read -r -p "Backup database '$db' dulu sebelum dihapus? [Y/n]: " pre
  if [[ "${pre,,}" != "n" ]]; then
    local bk
    bk=$(do_backup "$db") || { err "Backup gagal; penghapusan dibatalkan."; return 1; }
    echo "Backup: $bk"
  fi
  echo
  echo "AKAN DIHAPUS PERMANEN: database '$db'${drop_users:+ dan user ${exclusive[*]}}."
  read -r -p "Ketik nama database ($db) untuk konfirmasi: " confirm
  [[ "$confirm" == "$db" ]] || { echo "Dibatalkan."; return 0; }

  local id
  for id in $ids; do
    [[ "$id" =~ ^[0-9]+$ ]] && mysql_root -e "KILL $id" >/dev/null 2>&1 || true
  done
  mysql_root -e "DROP DATABASE $(sql_ident "$db");" || { err "Gagal menghapus database."; return 1; }
  echo "Database '$db' dihapus."
  # MySQL tidak mencabut grant saat database dihapus; tanpa ini, database baru dengan
  # nama sama otomatis bisa diakses lagi oleh user lama.
  local a
  for a in "${shared[@]}"; do
    u=${a%@*}; h=${a#*@}
    mysql_root -e "REVOKE ALL PRIVILEGES ON $(sql_ident "$db").* FROM $(sql_literal "$u")@$(sql_literal "$h");" >/dev/null 2>&1 \
      && echo "Hak $a ke '$db' dicabut." || true
  done
  if [[ -n "$drop_users" ]]; then
    for a in "${exclusive[@]}"; do
      u=${a%@*}; h=${a#*@}
      if mysql_root -e "DROP USER $(sql_literal "$u")@$(sql_literal "$h");"; then echo "User $a dihapus."; else echo "User $a gagal dihapus."; fi
    done
  else
    for a in "${exclusive[@]}"; do
      u=${a%@*}; h=${a#*@}
      mysql_root -e "REVOKE ALL PRIVILEGES ON $(sql_ident "$db").* FROM $(sql_literal "$u")@$(sql_literal "$h");" >/dev/null 2>&1 || true
    done
  fi
  [[ "$db" != "$MYSQL_DATABASE" ]] || echo "Catatan: '$db' adalah database awal di .env (MYSQL_DATABASE); nilai itu hanya dipakai saat setup pertama."
}

# ---------------------------------------------------------------------------
# SERTIFIKAT SSL
# ---------------------------------------------------------------------------
# MySQL menyimpan sertifikat di datadir: ca.pem, server-cert.pem, server-key.pem.
SSL_CERT_FILE="$DATA_DIR/server-cert.pem"
SSL_KEY_FILE="$DATA_DIR/server-key.pem"
SSL_CA_FILE="$DATA_DIR/ca.pem"

cert_days_left() {
  local f=${1:-$SSL_CERT_FILE} end
  [[ -r "$f" ]] || return 1
  end=$(openssl x509 -in "$f" -noout -enddate 2>/dev/null | cut -d= -f2) || return 1
  echo $(( ( $(date -d "$end" +%s) - $(date +%s) ) / 86400 ))
}

cert_expiry_warning() {
  local d
  d=$(cert_days_left) || return 0
  if (( d < 0 )); then
    echo "Sertifikat SSL sudah KEDALUWARSA $(( -d )) hari lalu. Rotasi lewat menu 15."
  elif (( d < 30 )); then
    echo "Sertifikat SSL berakhir dalam $d hari. Rotasi lewat menu 15."
  fi
}

show_cert_info() {
  local f=$1
  openssl x509 -in "$f" -noout -subject -issuer -enddate 2>/dev/null | sed -E 's/^subject=/  Subject : /; s/^issuer=/  Issuer  : /; s/^notAfter=/  Berlaku s.d.: /'
  echo "  Sisa    : $(cert_days_left "$f") hari"
}

served_not_after() {
  mysql_q "SELECT variable_value FROM performance_schema.global_status WHERE variable_name='Ssl_server_not_after'" 2>/dev/null | head -n1
}

rotate_ssl() {
  require_running || return 1
  need_cmd openssl || return 1
  [[ -f "$SSL_CERT_FILE" && -f "$SSL_KEY_FILE" ]] || { err "Sertifikat tidak ditemukan di $DATA_DIR."; return 1; }
  local choice tmpd ts bdir crt_in key_in ca_in uid gid f before after
  # Owner diambil dari key yang sedang dipakai mysqld (pasti terbaca olehnya).
  uid=$(stat -c '%u' "$SSL_KEY_FILE"); gid=$(stat -c '%g' "$SSL_KEY_FILE")
  echo "Sertifikat saat ini:"
  show_cert_info "$SSL_CERT_FILE"
  echo
  echo "  1. Buat CA + sertifikat self-signed baru (berlaku 10 tahun)"
  echo "  2. Pakai sertifikat sendiri (mis. dari CA / Let's Encrypt): fullchain + key (+ CA opsional)"
  echo "  0. Batal"
  read -r -p "Pilihan: " choice
  case "$choice" in 1|2) ;; *) echo "Dibatalkan."; return 0 ;; esac

  tmpd=$(mktemp -d "$BASE_DIR/.ssl.XXXXXX")
  if [[ "$choice" == 1 ]]; then
    if ! { openssl req -new -x509 -days 3650 -nodes -newkey rsa:2048 -keyout "$tmpd/ca-key.pem" -out "$tmpd/ca.pem" \
             -subj "/CN=${MYSQL_CONTAINER}_CA" \
        && openssl req -new -nodes -newkey rsa:2048 -keyout "$tmpd/server-key.pem" -out "$tmpd/server.csr" \
             -subj "/CN=${MYSQL_CONTAINER}" \
        && openssl x509 -req -days 3650 -in "$tmpd/server.csr" -CA "$tmpd/ca.pem" -CAkey "$tmpd/ca-key.pem" \
             -CAcreateserial -out "$tmpd/server-cert.pem"; } >/dev/null 2>&1; then
      safe_rm_in_base "$tmpd"; err "Gagal membuat sertifikat."; return 1
    fi
  else
    read -r -p "Path file sertifikat (fullchain.pem / .crt): " crt_in; crt_in=$(expand_path "$crt_in")
    read -r -p "Path file private key (privkey.pem / .key): " key_in; key_in=$(expand_path "$key_in")
    read -r -p "Path file CA/chain (kosong = pertahankan ca.pem lama): " ca_in; [[ -z "$ca_in" ]] || ca_in=$(expand_path "$ca_in")
    [[ -r "$crt_in" && -r "$key_in" ]] || { safe_rm_in_base "$tmpd"; err "File tidak ditemukan / tidak bisa dibaca."; return 1; }
    [[ -z "$ca_in" || -r "$ca_in" ]] || { safe_rm_in_base "$tmpd"; err "File CA tidak bisa dibaca."; return 1; }
    openssl x509 -in "$crt_in" -noout 2>/dev/null || { safe_rm_in_base "$tmpd"; err "File sertifikat tidak valid (harus PEM)."; return 1; }
    openssl pkey -in "$key_in" -noout 2>/dev/null || { safe_rm_in_base "$tmpd"; err "Private key tidak valid atau terenkripsi passphrase."; return 1; }
    if [[ "$(openssl x509 -in "$crt_in" -noout -pubkey 2>/dev/null)" != "$(openssl pkey -in "$key_in" -pubout 2>/dev/null)" ]]; then
      safe_rm_in_base "$tmpd"; err "Private key tidak cocok dengan sertifikat."; return 1
    fi
    openssl x509 -in "$crt_in" -noout -checkend 0 >/dev/null 2>&1 || { safe_rm_in_base "$tmpd"; err "Sertifikat sudah kedaluwarsa."; return 1; }
    cat -- "$crt_in" > "$tmpd/server-cert.pem"; cat -- "$key_in" > "$tmpd/server-key.pem"
    if [[ -n "$ca_in" ]]; then cat -- "$ca_in" > "$tmpd/ca.pem"; fi
  fi
  echo "Sertifikat baru:"
  show_cert_info "$tmpd/server-cert.pem"

  ts=$(date +%Y%m%d-%H%M%S)
  bdir="$BACKUP_DIR/ssl-$ts"
  mkdir -p "$bdir"; chmod 700 "$bdir"
  for f in ca.pem ca-key.pem server-cert.pem server-key.pem; do
    [[ -f "$DATA_DIR/$f" ]] && cp -p -- "$DATA_DIR/$f" "$bdir/"
  done
  for f in ca.pem ca-key.pem server-cert.pem server-key.pem; do
    [[ -f "$tmpd/$f" ]] || continue
    install -o "$uid" -g "$gid" -m 600 "$tmpd/$f" "$DATA_DIR/$f"
  done
  [[ -f "$tmpd/ca.pem" ]] && chmod 644 "$DATA_DIR/ca.pem"
  [[ -f "$tmpd/server-cert.pem" ]] && chmod 644 "$DATA_DIR/server-cert.pem"
  safe_rm_in_base "$tmpd"
  echo "Sertifikat lama disimpan di $bdir"

  before=$(served_not_after)
  local errf; errf=$(mktemp)
  if mysql_root -e "ALTER INSTANCE RELOAD TLS" 2>"$errf"; then
    after=$(served_not_after)
    echo "TLS dimuat ulang tanpa restart. Berlaku s.d. (dari server): ${after:-?}"
    rm -f -- "$errf"
  else
    err "MySQL menolak sertifikat baru: $(head -n 1 "$errf")"
    rm -f -- "$errf"
    # Kembalikan persis seperti semula (owner & mode ikut, karena dibackup dengan cp -p).
    for f in ca.pem ca-key.pem server-cert.pem server-key.pem; do
      if [[ -f "$bdir/$f" ]]; then cp -p -- "$bdir/$f" "$DATA_DIR/$f"; fi
    done
    mysql_root -e "ALTER INSTANCE RELOAD TLS" >/dev/null 2>&1 || true
    err "Sertifikat lama dikembalikan (server masih memakai sertifikat sebelumnya: ${before:-?})."
    return 1
  fi
}


# ---------------------------------------------------------------------------
# RESTORE
# ---------------------------------------------------------------------------
# Nama database dari nama file backup: <db>-YYYYMMDD-HHMMSS[-pid].sql[.gz]
db_from_backup_name() {
  sed -nE 's/^(.+)-[0-9]{8}-[0-9]{6}(-[0-9]+)?\.sql(\.gz)?$/\1/p' <<< "$(basename "$1")"
}

# Baca isi dump (gzip atau plain) ke stdout.
dump_cat() {
  case "$1" in
    *.gz) gzip -dc -- "$1" ;;
    *)    cat -- "$1" ;;
  esac
}

# Filter python untuk dump dari tool lain (Navicat, HeidiSQL, phpMyAdmin, dll.) yang
# menyertakan nilai kolom GENERATED (VIRTUAL/STORED) di INSERT. MySQL menolaknya
# (ERROR 3105), jadi nilai kolom itu dibuang dan MySQL menghitung ulang sendiri.
# Dump hasil mysqldump tidak pernah berisi nilai kolom generated, jadi tidak berubah.
GENFIX_PY=$(cat <<'PYEOF'
import re, sys

# Filter dump SQL: buang nilai kolom GENERATED (VIRTUAL/STORED) dari INSERT/REPLACE,
# karena MySQL menolak nilai eksplisit untuk kolom generated (ERROR 3105).
# mode "check": cetak "PROBLEM <tabel> <kolom>" / "UNFIXABLE <tabel> <alasan>".
# mode "fix"  : tulis ulang dump ke stdout.
# Data diproses sebagai bytes (latin-1) supaya isi biner/encoding apa pun tidak berubah.
mode = sys.argv[1] if len(sys.argv) > 1 else "check"
inp = sys.stdin.buffer
out = sys.stdout.buffer

CREATE_RE = re.compile(r'^\s*CREATE\s+TABLE\s+(?:IF\s+NOT\s+EXISTS\s+)?`((?:[^`]|``)+)`', re.I)
COL_RE = re.compile(r'^\s+`((?:[^`]|``)+)`\s')
GEN_RE = re.compile(r'GENERATED\s+ALWAYS\s+AS\b', re.I)
GEN2_RE = re.compile(r'\sAS\s*\(.*\)\s*(VIRTUAL|STORED)\b', re.I)
INS_RE = re.compile(r'^\s*((?:INSERT(?:\s+(?:IGNORE|LOW_PRIORITY|HIGH_PRIORITY|DELAYED))*\s+INTO)|(?:REPLACE(?:\s+(?:LOW_PRIORITY|DELAYED))?\s+INTO))\s+`((?:[^`]|``)+)`\s*', re.I)
VALUES_RE = re.compile(r'\s*VALUES?\s*', re.I)
TOK = re.compile(r"'(?:[^'\\]|\\.|'')*'|\"(?:[^\"\\]|\\.|\"\")*\"|`(?:[^`]|``)*`|[(),;]|[^'\"`(),;]+|(['\"`])", re.S)

tables = {}          # nama -> (daftar kolom, set kolom generated)
problems = set()
unfixable = set()


def split_top_level(text):
    """Pecah teks pada koma di luar kurung/kutip (beberapa definisi kolom dalam satu baris)."""
    parts, cur, depth = [], [], 0
    for m in TOK.finditer(text):
        t = m.group(0)
        if t == '(':
            depth += 1
        elif t == ')':
            depth -= 1
        elif t == ',' and depth == 0:
            parts.append(''.join(cur)); cur = []; continue
        cur.append(t)
    parts.append(''.join(cur))
    return [p for p in parts if p.strip()]


def statement_complete(buf):
    for m in TOK.finditer(buf):
        if m.group(1):           # kutip belum ditutup -> statement berlanjut ke baris berikut
            return False
        if m.group(0) == ';':
            return True
    return False


def parse_insert(stmt):
    """Kembalikan (verb, tabel, kolom|None, [tuple nilai], sisa) atau None jika tidak bisa di-parse."""
    m = INS_RE.match(stmt)
    if not m:
        return None
    verb, table = m.group(1), m.group(2).replace('``', '`')
    pos = m.end()
    cols = None
    toks = [t.group(0) for t in TOK.finditer(stmt, pos)]
    i = 0
    if i < len(toks) and toks[i] == '(':
        cols = []
        i += 1
        while i < len(toks) and toks[i] != ')':
            t = toks[i].strip()
            if t and t != ',':
                if not (t.startswith('`') and t.endswith('`')):
                    return None
                cols.append(t[1:-1].replace('``', '`'))
            i += 1
        i += 1
    rest = ''.join(toks[i:])
    vm = VALUES_RE.match(rest)
    if not vm:
        return None
    toks = [t.group(0) for t in TOK.finditer(rest, vm.end())]
    rows, i = [], 0
    while True:
        while i < len(toks) and toks[i].strip() == '':
            i += 1
        if i >= len(toks) or toks[i] != '(':
            return None
        i += 1
        depth, cur, vals = 0, [], []
        while i < len(toks):
            t = toks[i]
            if t == '(':
                depth += 1
            elif t == ')':
                if depth == 0:
                    break
                depth -= 1
            elif t == ',' and depth == 0:
                vals.append(''.join(cur).strip()); cur = []; i += 1; continue
            cur.append(t); i += 1
        if i >= len(toks):
            return None
        vals.append(''.join(cur).strip())
        rows.append(vals)
        i += 1
        while i < len(toks) and toks[i].strip() == '':
            i += 1
        if i < len(toks) and toks[i] == ',':
            i += 1
            continue
        tail = ''.join(toks[i:])
        if tail.strip() != ';':      # mis. ON DUPLICATE KEY UPDATE / SELECT -> tidak didukung
            return None
        return verb, table, cols, rows, tail


def handle_insert(stmt):
    m = INS_RE.match(stmt)
    if not m:
        return stmt
    table = m.group(2).replace('``', '`')
    info = tables.get(table)
    if not info or not info[1]:
        return stmt
    allcols, gen = info
    parsed = parse_insert(stmt)
    if parsed is None:
        unfixable.add((table, 'format INSERT tidak dikenali'))
        return stmt
    verb, _, cols, rows, tail = parsed
    cols = cols if cols is not None else allcols
    if any(len(r) != len(cols) for r in rows):
        unfixable.add((table, 'jumlah nilai tidak sama dengan jumlah kolom'))
        return stmt
    drop = [k for k, c in enumerate(cols) if c in gen]
    if not drop:
        return stmt
    for k in drop:
        problems.add((table, cols[k]))
    keep = [k for k in range(len(cols)) if k not in drop]
    q = lambda c: '`' + c.replace('`', '``') + '`'
    head = '%s %s (%s) VALUES ' % (verb, q(table), ','.join(q(cols[k]) for k in keep))
    body = ','.join('(' + ','.join(r[k] for k in keep) + ')' for r in rows)
    return head + body + tail.rstrip('\n') + '\n'


cur_table = None
buf = None
for raw in inp:
    line = raw.decode('latin-1')
    if buf is not None:
        buf += line
        if statement_complete(buf):
            res = handle_insert(buf)
            if mode == 'fix':
                out.write(res.encode('latin-1'))
            buf = None
        continue
    if cur_table is not None:
        if line.lstrip().startswith(')'):
            cur_table = None
        else:
            for part in split_top_level(line):
                cm = COL_RE.match(' ' + part.lstrip())
                if cm:
                    name = cm.group(1).replace('``', '`')
                    tables[cur_table][0].append(name)
                    if GEN_RE.search(part) or GEN2_RE.search(' ' + part):
                        tables[cur_table][1].add(name)
        if mode == 'fix':
            out.write(raw)
        continue
    cm = CREATE_RE.match(line)
    if cm:
        cur_table = cm.group(1).replace('``', '`')
        tables[cur_table] = ([], set())
        if mode == 'fix':
            out.write(raw)
        continue
    if INS_RE.match(line):
        buf = line
        if statement_complete(buf):
            res = handle_insert(buf)
            if mode == 'fix':
                out.write(res.encode('latin-1'))
            buf = None
        continue
    if mode == 'fix':
        out.write(raw)

if buf is not None and mode == 'fix':
    out.write(buf.encode('latin-1'))

if mode == 'check':
    for t, c in sorted(problems):
        print('PROBLEM %s %s' % (t, c))
    for t, why in sorted(unfixable):
        print('UNFIXABLE %s %s' % (t, why))
PYEOF
)

# Kumpulkan semua backup: lokal (backups/, auto/, downloaded/) dan R2 (auto/, manual/).
# Output per baris: epoch|sumber|lokasi|ukuran|nama_file (terbaru dulu; nama file unik,
# salinan lokal diutamakan bila file yang sama juga ada di R2).
collect_backups() {
  local d listing ts size name epoch sub p rel
  {
    for d in "$BACKUP_DIR" "$AUTO_DIR" "$DOWNLOAD_DIR"; do
      [[ -d "$d" ]] || continue
      find "$d" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.sql' \) ! -name 'users-*' \
        -printf "%T@|lokal|%p|%s|%f\n" | sed -E 's/^([0-9]+)\.[0-9]+\|/\1|/'
    done
    for d in "$RBACKUP_DIR"/*/ "$RAUTO_DIR"/*/; do
      [[ -d "$d" ]] || continue
      p=$(basename "$d")
      find "$d" -maxdepth 1 -type f \( -name '*.sql.gz' -o -name '*.sql' \) ! -name 'users-*' \
        -printf "%T@|lokal:$p|%p|%s|%f\n" | sed -E 's/^([0-9]+)\.[0-9]+\|/\1|/'
    done
    if r2_configured; then
      for sub in auto manual; do
        if listing=$(rclone_run lsf "$(r2_path "$sub")" --files-only --format "tsp" --separator ";" --include '*.sql.gz' 2>/dev/null); then
          while IFS=';' read -r ts size name; do
            [[ -n "$name" && "$name" != users-* ]] || continue
            epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
            printf '%s|R2:%s|%s|%s|%s\n' "$epoch" "$sub" "$sub/$name" "$size" "$name"
          done <<< "$listing"
        else
          echo "Peringatan: gagal membaca daftar backup R2 ($sub); hanya backup lokal yang ditampilkan." >&2
        fi
      done
      for sub in auto/remote manual/remote; do
        if listing=$(rclone_run lsf "$(r2_path "$sub")" -R --files-only --format "tsp" --separator ";" --include '*.sql.gz' 2>/dev/null); then
          while IFS=';' read -r ts size rel; do
            [[ "$rel" == */* ]] || continue
            p=${rel%%/*}; name=${rel##*/}
            epoch=$(date -d "$ts" +%s 2>/dev/null) || continue
            printf '%s|R2:%s|%s|%s|%s\n' "$epoch" "${sub%%/*}:$p" "$sub/$rel" "$size" "$name"
          done <<< "$listing"
        fi
      done
    fi
  } | awk -F'|' '!($5 in best) || ($2 ~ /^lokal/ && src[$5] !~ /^lokal/) { best[$5] = $0; src[$5] = $2 }
                 END { for (k in best) print best[k] }' | sort -t'|' -k1,1nr
}

# Pilih backup secara interaktif. Mencetak path file lokal yang siap di-restore
# (backup dari R2 di-download dulu ke downloaded/). Return 2 = batal.
pick_backup() {
  local filter rows=() r i=0 pick epoch src loc size name dbn path
  read -r -p "Filter nama database (kosong = semua): " filter
  [[ -z "$filter" ]] || valid_dbname "$filter" || { err "Filter tidak valid."; return 1; }
  echo "Mencari backup lokal$(r2_configured && echo ' dan R2')..." >&2
  while IFS= read -r r; do
    [[ -n "$r" ]] || continue
    IFS='|' read -r epoch src loc size name <<< "$r"
    dbn=$(db_from_backup_name "$name")
    [[ -n "$dbn" ]] || continue
    [[ -z "$filter" || "$dbn" == "$filter" ]] || continue
    rows+=("$r")
    (( ${#rows[@]} < 40 )) || break
  done < <(collect_backups)
  {
    if (( ${#rows[@]} == 0 )); then
      echo "Tidak ada backup yang ditemukan${filter:+ untuk '$filter'}."
    else
      printf '\n %3s  %-16s  %-22s  %-20s  %8s  %s\n' "No" "Waktu" "Sumber" "Database" "Ukuran" "File"
      for r in "${rows[@]}"; do
        i=$((i+1))
        IFS='|' read -r epoch src loc size name <<< "$r"
        printf ' %3d  %-16s  %-22s  %-20s  %8s  %s\n' "$i" "$(date -d "@$epoch" '+%Y-%m-%d %H:%M')" "$src" \
          "$(db_from_backup_name "$name")" "$(numfmt --to=iec "$size" 2>/dev/null || echo "$size")" "$name"
      done
    fi
    echo
    echo "  m = masukkan path file manual (.sql / .sql.gz)"
  } >&2
  read -r -p "Pilih nomor backup (kosong = batal): " pick
  [[ -n "$pick" ]] || return 2
  if [[ "${pick,,}" == "m" ]]; then
    read -r -p "Path file backup: " path
    expand_path "$path"
    return 0
  fi
  [[ "$pick" =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#rows[@]} )) || { err "Pilihan tidak valid."; return 1; }
  IFS='|' read -r epoch src loc size name <<< "${rows[$((pick-1))]}"
  if [[ "$src" == lokal* ]]; then
    printf '%s\n' "$loc"
  else
    load_r2_conf || { err "Konfigurasi R2 tidak lengkap."; return 1; }
    mkdir -p "$DOWNLOAD_DIR"; chmod 700 "$DOWNLOAD_DIR"
    echo "Download $name dari R2..." >&2
    rclone_run copyto "$(r2_path "")/$loc" "$DOWNLOAD_DIR/$name" >&2 || { err "Download dari R2 gagal."; return 1; }
    chmod 600 "$DOWNLOAD_DIR/$name"
    echo "Tersimpan: $DOWNLOAD_DIR/$name" >&2
    printf '%s\n' "$DOWNLOAD_DIR/$name"
  fi
}

# ---------------------------------------------------------------------------
# GANTI PASSWORD
# ---------------------------------------------------------------------------
change_password() {
  require_running || return 1
  local acct user host n password password2 confirm in_env="" verify_host recreate
  echo "Akun yang ada:"
  mysql_q "SELECT CONCAT('  - ', user, '@', host) FROM mysql.user WHERE user NOT IN ($SYSTEM_USERS) ORDER BY user, host"
  read -r -p "Akun yang diganti password-nya (user atau user@host) [root@localhost]: " acct
  acct=${acct:-root@localhost}
  if [[ "$acct" == *@* ]]; then
    user=${acct%@*}; host=${acct#*@}
  else
    user=$acct
    n=$(mysql_q "SELECT COUNT(*) FROM mysql.user WHERE user=$(sql_literal "$user")" | tr -d '[:space:]')
    [[ "$n" == "1" ]] || { err "User '$user' tidak ada atau punya beberapa host; tulis lengkap sebagai user@host."; return 1; }
    host=$(mysql_q "SELECT host FROM mysql.user WHERE user=$(sql_literal "$user")" | tr -d '[:space:]')
  fi
  [[ "$user" == "root" ]] || valid_username "$user" || { err "Username tidak valid."; return 1; }
  valid_host "$host" || { err "Host tidak valid."; return 1; }
  [[ "$(mysql_q "SELECT COUNT(*) FROM mysql.user WHERE user=$(sql_literal "$user") AND host=$(sql_literal "$host")" | tr -d '[:space:]')" == "1" ]] \
    || { err "Akun $user@$host tidak ditemukan."; return 1; }
  [[ "$user" == "root" && "$host" == "localhost" ]] && in_env=MYSQL_ROOT_PASSWORD
  [[ -z "$in_env" && "$user" == "$MYSQL_USER" && "$host" == "%" ]] && in_env=MYSQL_PASSWORD

  read -r -s -p "Password baru (kosong = generate otomatis): " password; echo
  if [[ -z "$password" ]]; then
    password=$(gen_password)
  else
    read -r -s -p "Ulangi password: " password2; echo
    [[ "$password" == "$password2" ]] || { err "Password tidak cocok."; return 1; }
    if [[ -n "$in_env" ]]; then
      [[ "$password" =~ ^[A-Za-z0-9@#%+=._-]{16,}$ ]] || { err "Password untuk akun ini disimpan di .env: minimal 16 karakter; hanya huruf, angka, dan @ # % + = . _ -"; return 1; }
    else
      (( ${#password} >= 12 )) || { err "Password minimal 12 karakter."; return 1; }
    fi
  fi

  echo "PERINGATAN: aplikasi/klien yang memakai $user@$host harus diperbarui dengan password baru."
  echo "            Koneksi yang sedang terbuka tetap jalan; koneksi baru wajib memakai password baru."
  read -r -p "Ketik GANTI untuk melanjutkan: " confirm
  [[ "$confirm" == "GANTI" ]] || { echo "Dibatalkan."; return 0; }

  # Password dikirim lewat stdin (bukan argumen proses).
  if ! mysql_root <<SQL
ALTER USER $(sql_literal "$user")@$(sql_literal "$host") IDENTIFIED BY $(sql_literal "$password");
SQL
  then
    err "Gagal mengubah password. Tidak ada yang berubah."; return 1
  fi
  echo "Password $user@$host di MySQL sudah diubah."

  if [[ -n "$in_env" ]]; then
    if ! env_set "$in_env" "$password"; then
      err "Password di MySQL SUDAH berubah, tetapi gagal menulis $ENV_FILE."
      err "Simpan password ini dan perbarui $in_env di .env secara manual: $password"
      return 1
    fi
    echo "$ENV_FILE diperbarui ($in_env)."
    [[ "$in_env" == MYSQL_ROOT_PASSWORD ]] && MYSQL_ROOT_PASSWORD=$password
  fi

  # Verifikasi login dengan password baru.
  if [[ "$user" == "root" && "$host" == "localhost" ]]; then
    if mysql_q "SELECT 1" >/dev/null 2>&1; then echo "Verifikasi login root: BERHASIL."; else echo "Catatan: verifikasi login root gagal."; fi
  elif [[ "$host" == "%" || "$host" == "127.0.0.1" ]]; then
    if MYSQL_PWD="$password" docker exec -e MYSQL_PWD "$MYSQL_CONTAINER" \
         mysql -h 127.0.0.1 -u "$user" --ssl-mode=REQUIRED -N -B -e "SELECT 1" >/dev/null 2>&1; then
      echo "Verifikasi login TCP+TLS dengan password baru: BERHASIL."
    else
      echo "Catatan: verifikasi login otomatis gagal. Password tetap sudah diganti."
    fi
  else
    echo "Catatan: akun dengan host '$host' tidak bisa diverifikasi dari dalam container."
  fi

  if [[ -n "$in_env" ]]; then
    echo
    echo "Container masih menyimpan password lama di environment-nya (terlihat di 'docker inspect'),"
    echo "walau tidak dipakai lagi untuk login. Recreate container untuk menyegarkannya;"
    echo "data tetap aman, downtime beberapa detik."
    read -r -p "Recreate container sekarang? [y/N]: " recreate
    if [[ "${recreate,,}" == "y" ]]; then
      (cd "$BASE_DIR" && docker compose up -d --force-recreate) || { err "Recreate gagal; jalankan menu 2."; return 1; }
      wait_ready "$MYSQL_CONTAINER" && echo "MySQL siap." || { err "MySQL belum siap. Periksa logs."; return 1; }
    else
      echo "OK. Container ikut diperbarui otomatis saat menu 2 (Start) dijalankan berikutnya."
    fi
  fi
  echo
  echo "Password baru untuk $user@$host: $password"
  echo "Simpan sekarang dan perbarui konfigurasi aplikasi."
}

restore_database() {
  require_running || return 1
  local file db def_db confirm pre empty rc definers new_def="" d sug genfix=0
  if [[ -n "${1:-}" ]]; then
    file=$1
  else
    rc=0; file=$(pick_backup) || rc=$?
    (( rc != 2 )) || { echo "Dibatalkan."; return 0; }
    (( rc == 0 )) || return 1
  fi
  [[ -f "$file" && -r "$file" ]] || { err "File tidak ditemukan / tidak bisa dibaca: $file"; return 1; }
  case "$file" in *.sql|*.sql.gz) ;; *) err "Format harus .sql atau .sql.gz"; return 1 ;; esac
  if [[ "$file" == *.gz ]] && ! gzip -t "$file" 2>/dev/null; then
    err "Arsip gzip rusak: $file"; return 1
  fi
  if ! grep -qiE '^-- (MySQL|MariaDB) dump' < <(dump_cat "$file" 2>/dev/null | head -n 5); then
    err "File tidak terlihat seperti hasil mysqldump."; return 1
  fi
  # Dump yang dibuat dengan --databases/--all-databases berisi USE `db`, sehingga
  # datanya masuk ke database aslinya, bukan ke database tujuan yang dipilih.
  if grep -qE '^(USE |CREATE DATABASE )' < <(dump_cat "$file" 2>/dev/null); then
    err "Dump berisi 'USE'/'CREATE DATABASE' (dibuat dengan --databases/--all-databases)."
    err "Restore ke database pilihan tidak aman. Restore manual, atau buat dump per database tanpa --databases."
    return 1
  fi
  echo "File: $file"

  # Kolom generated: cek SEBELUM ada perubahan apa pun, karena restore tidak atomik.
  if grep -qiE 'GENERATED ALWAYS AS|[[:space:]]AS[[:space:]]*\(.*\)[[:space:]]*(VIRTUAL|STORED)' < <(dump_cat "$file" 2>/dev/null); then
    if ! command -v python3 >/dev/null 2>&1; then
      echo "Catatan: dump berisi kolom generated (VIRTUAL/STORED), tapi python3 tidak tersedia untuk memeriksanya."
      echo "         Dump hasil mysqldump aman. Jika restore gagal dengan ERROR 3105, pasang python3 lalu ulangi."
    else
      local report probs unfix
      echo "Memeriksa kolom generated (VIRTUAL/STORED) di dump..."
      report=$(dump_cat "$file" | python3 -c "$GENFIX_PY" check) || { err "Gagal memeriksa dump."; return 1; }
      probs=$(grep '^PROBLEM ' <<< "$report" | cut -d' ' -f2- || true)
      unfix=$(grep '^UNFIXABLE ' <<< "$report" | cut -d' ' -f2- || true)
      if [[ -n "$unfix" ]]; then
        err "Dump berisi INSERT ke tabel dengan kolom generated yang tidak bisa diperbaiki otomatis:"
        sed 's/^/  - /' <<< "$unfix" >&2
        err "Buat ulang dump dengan mysqldump (menu 6 di server asal), atau export tanpa kolom generated."
        return 1
      fi
      if [[ -n "$probs" ]]; then
        echo "Dump mengisi nilai kolom generated (biasanya hasil export GUI). MySQL akan menolaknya (ERROR 3105):"
        sed -E 's/^([^ ]+) (.*)$/  - \1.\2/' <<< "$probs"
        local fx
        read -r -p "Buang nilai kolom tersebut dari INSERT saat restore (MySQL menghitung ulang)? [Y/n]: " fx
        [[ "${fx,,}" != "n" ]] || { echo "Dibatalkan: restore akan gagal tanpa perbaikan ini."; return 0; }
        genfix=1
      else
        echo "Kolom generated aman (nilainya tidak ada di INSERT)."
      fi
    fi
  fi

  def_db=$(db_from_backup_name "$file")
  if [[ -n "$def_db" ]] && valid_dbname "$def_db" && db_exists "$def_db"; then
    read -r -p "Restore ke database yang sudah ada [$def_db]: " db
    db=${db:-$def_db}
  else
    [[ -n "$def_db" ]] && echo "Database asal '$def_db' belum ada di server ini. Buat dulu lewat menu 5 jika ingin restore ke nama yang sama."
    read -r -p "Restore ke database yang sudah ada: " db
  fi
  valid_dbname "$db" || { err "Nama database tidak valid."; return 1; }
  db_exists "$db" || { err "Database '$db' tidak ada. Buat dulu lewat menu 5."; return 1; }
  case "$db" in mysql|information_schema|performance_schema|sys) err "Restore ke database sistem tidak diizinkan."; return 1 ;; esac

  # DEFINER di view/trigger/routine/event: jika user aslinya tidak ada di server ini,
  # objek tersebut gagal dipakai. Tawarkan untuk mengganti ke user lain.
  definers=$(grep -oE 'DEFINER=`[^`]+`@`[^`]+`' < <(dump_cat "$file" 2>/dev/null) | sort -u || true)
  if [[ -n "$definers" ]]; then
    echo "Dump berisi objek dengan DEFINER:"
    while IFS= read -r d; do
      local du dh
      du=$(sed -E 's/^DEFINER=`([^`]+)`@`([^`]+)`$/\1/' <<< "$d"); dh=$(sed -E 's/^DEFINER=`([^`]+)`@`([^`]+)`$/\2/' <<< "$d")
      if [[ "$(mysql_q "SELECT COUNT(*) FROM mysql.user WHERE user=$(sql_literal "$du") AND host=$(sql_literal "$dh")" | tr -d '[:space:]')" == "1" ]]; then
        echo "  - $du@$dh (ada)"
      else
        echo "  - $du@$dh (TIDAK ADA di server ini)"
      fi
    done <<< "$definers"
    sug=$(mysql_q "SELECT CONCAT(user,'@',host) FROM mysql.db WHERE db=$(sql_literal "$db") AND user <> 'root' ORDER BY user LIMIT 1" | tr -d '[:space:]' || true)
    read -r -p "Ganti semua DEFINER ke user@host${sug:+ [$sug]} (ketik '-' untuk membiarkan apa adanya): " new_def
    new_def=${new_def:-$sug}
    if [[ -z "$new_def" || "$new_def" == "-" ]]; then
      new_def=""
    else
      local nu=${new_def%@*} nh=${new_def#*@}
      [[ "$new_def" == *@* ]] && valid_username "$nu" && valid_host "$nh" || { err "Format harus user@host, mis. qolcore_user@%."; return 1; }
      [[ "$(mysql_q "SELECT COUNT(*) FROM mysql.user WHERE user=$(sql_literal "$nu") AND host=$(sql_literal "$nh")" | tr -d '[:space:]')" == "1" ]] || { err "User $new_def tidak ada."; return 1; }
      new_def="DEFINER=\`$nu\`@\`$nh\`"
    fi
  fi

  echo
  echo "PERINGATAN: tabel/objek di '$db' yang ada di backup akan DIHAPUS lalu dibuat ulang."
  echo "            Restore MySQL tidak atomik: jika gagal di tengah, database bisa setengah ter-restore."
  read -r -p "Kosongkan seluruh database '$db' dulu (hapus juga tabel yang tidak ada di backup)? [y/N]: " empty
  read -r -p "Buat backup database '$db' terlebih dahulu? [Y/n]: " pre
  if [[ "${pre,,}" != "n" ]]; then
    local prefile
    prefile=$(do_backup "$db") || { err "Backup pengaman gagal; restore dibatalkan."; return 1; }
    echo "Backup pengaman: $prefile"
  fi
  read -r -p "Ketik RESTORE untuk melanjutkan: " confirm
  [[ "$confirm" == "RESTORE" ]] || { echo "Dibatalkan."; return 0; }

  if [[ "${empty,,}" == "y" ]]; then
    local cs co
    read -r cs co < <(mysql_q "SELECT default_character_set_name, default_collation_name FROM information_schema.schemata WHERE schema_name=$(sql_literal "$db")")
    log "Mengosongkan database '$db' (DROP + CREATE, grant tetap berlaku)"
    mysql_root -e "DROP DATABASE $(sql_ident "$db"); CREATE DATABASE $(sql_ident "$db") CHARACTER SET $cs COLLATE $co;" \
      || { err "Gagal mengosongkan database."; return 1; }
  fi

  log "Restore $file -> $db"
  {
    if (( genfix )); then dump_cat "$file" | python3 -c "$GENFIX_PY" fix; else dump_cat "$file"; fi
  } | sed '1{/enable the sandbox mode/d}' | {
    if [[ -n "$new_def" ]]; then sed -E "s/DEFINER=\`[^\`]+\`@\`[^\`]+\`/$new_def/g"; else cat; fi
  } | mysql_root "$db" || {
    err "Restore gagal. Database '$db' mungkin hanya ter-restore sebagian."
    [[ "${pre,,}" != "n" ]] && err "Kembalikan dari backup pengaman di atas (menu 7) jika perlu."
    return 1
  }
  echo "Restore selesai ke database '$db'."
}

# ---------------------------------------------------------------------------
# STATUS & OPERASI DOCKER
# ---------------------------------------------------------------------------
show_status() {
  load_config || return 1
  (cd "$BASE_DIR" && docker compose ps)
}

show_ssl() {
  require_running || return 1
  mysql_root --table -e "SELECT variable_name AS setting, variable_value AS value FROM performance_schema.global_variables
    WHERE variable_name IN ('require_secure_transport','tls_version','ssl_ca','ssl_cert','skip_name_resolve','local_infile','bind_address')
    UNION ALL SELECT variable_name, variable_value FROM performance_schema.global_status
    WHERE variable_name IN ('Ssl_server_not_before','Ssl_server_not_after')"
}

show_logs() {
  load_config || return 1
  echo "(Tekan Ctrl+C untuk kembali ke menu)"
  docker logs --tail 100 -f "$MYSQL_CONTAINER" || true
}

# Pastikan folder data milik user mysql di container. Return 10 = baru diperbaiki.
ensure_data_dir_owner() {
  local uid=${MYSQL_UID:-} gid=${MYSQL_GID:-}
  [[ -d "$DATA_DIR" ]] || return 0
  if [[ -z "$uid" ]]; then
    uid=$(docker run --rm --entrypoint id "$MYSQL_IMAGE" -u mysql 2>/dev/null || true)
    gid=$(docker run --rm --entrypoint id "$MYSQL_IMAGE" -g mysql 2>/dev/null || true)
    [[ "$uid" =~ ^[0-9]+$ ]] || { err "Tidak bisa membaca UID mysql dari image $MYSQL_IMAGE."; return 1; }
    [[ "$gid" =~ ^[0-9]+$ ]] || gid=$uid
    env_set MYSQL_UID "$uid"; env_set MYSQL_GID "$gid"
  fi
  [[ -n "$gid" ]] || gid=$uid
  if [[ "$(stat -c '%u' "$DATA_DIR")" != "$uid" ]]; then
    echo "Memperbaiki owner $DATA_DIR -> $uid:$gid (user mysql di container)"
    chown "$uid:$gid" "$DATA_DIR" && chmod 700 "$DATA_DIR" || { err "Gagal mengubah owner $DATA_DIR."; return 1; }
    return 10
  fi
  return 0
}

start_stack() {
  load_config || return 1
  check_docker || return 1
  local fixed=0
  ensure_data_dir_owner || { (( $? == 10 )) && fixed=1 || return 1; }
  if (( fixed )); then
    (cd "$BASE_DIR" && docker compose up -d --force-recreate) || return 1
  else
    (cd "$BASE_DIR" && docker compose up -d) || return 1
  fi
  echo "Menunggu MySQL siap..."
  wait_ready "$MYSQL_CONTAINER" && echo "MySQL siap." || { err "MySQL belum siap. Periksa logs."; return 1; }
}
stop_stack()    { load_config || return 1; (cd "$BASE_DIR" && docker compose stop); }
restart_stack() { load_config || return 1; (cd "$BASE_DIR" && docker compose restart); }

# ---------------------------------------------------------------------------
# MENU
# ---------------------------------------------------------------------------
# Jalankan aksi menu di subshell dengan `set -e` aktif: perintah yang gagal
# menghentikan aksi itu saja, lalu kembali ke menu.
run_action() {
  local rc
  set +e
  ( set -e; trap - INT; "$@" )
  rc=$?
  set -e
  if (( rc == 130 )); then
    echo; echo "Dibatalkan (Ctrl+C)."
  elif (( rc != 0 )); then
    echo; echo "Aksi gagal (exit code $rc)."
  fi
  pause
}

main_menu() {
  local choice cw
  trap 'echo' INT
  while true; do
    clear 2>/dev/null || true
    echo "=============================================="
    echo "          MYSQL DOCKER MANAGER"
    echo "=============================================="
    echo "Folder   : $BASE_DIR"
    if [[ -f "$ENV_FILE" ]] && load_config 2>/dev/null; then
      echo "Container: $MYSQL_CONTAINER | Bind: $MYSQL_BIND:$MYSQL_PORT"
      check_ownership
      cw=$(cert_expiry_warning 2>/dev/null || true)
      [[ -z "$cw" ]] || echo "PERINGATAN: $cw"
      if [[ -f "$INSTALLED_BIN" ]] && { [[ -f "$CRON_FILE" ]] || [[ -f "/etc/systemd/system/$SYSTEMD_UNIT.timer" ]]; } \
         && ! cmp -s "$SCRIPT_PATH" "$INSTALLED_BIN"; then
        echo "PERINGATAN: salinan scheduler ($INSTALLED_BIN) berbeda dari script ini; buka menu auto backup -> 1 untuk memperbarui."
      fi
    elif [[ -f "$COMPOSE_FILE" ]]; then
      echo "Status: compose.yaml ada tetapi .env tidak ditemukan/tidak valid"
    else
      echo "Status: Belum setup"
    fi
    echo "----------------------------------------------"
    echo " 1. Setup MySQL dari nol"
    echo " 2. Start MySQL"
    echo " 3. Stop MySQL"
    echo " 4. Restart MySQL"
    echo " 5. Buat database + user baru"
    echo " 6. Backup database"
    echo " 7. Restore database (pilih dari backup)"
    echo " 8. List database"
    echo " 9. List user"
    echo "10. Cek status container & SSL"
    echo "11. Lihat MySQL logs"
    echo "12. Ganti password user/root"
    echo "13. Auto backup & Cloudflare R2"
    echo "14. Hapus database + user"
    echo "15. Rotasi sertifikat SSL"
    echo "16. Uninstall instance (hapus container, opsional data)"
    echo "17. Server remote: backup & restore (server MySQL lain)"
    echo " 0. Keluar"
    echo "=============================================="
    if ! read -r -p "Pilih menu: " choice; then echo; exit 0; fi
    echo
    case "$choice" in
      1) run_action setup_stack ;;
      2) run_action start_stack ;;
      3) run_action stop_stack ;;
      4) run_action restart_stack ;;
      5) run_action create_database ;;
      6) run_action backup_database ;;
      7) run_action restore_database ;;
      8) run_action list_databases ;;
      9) run_action list_users ;;
      10) run_action show_status_ssl ;;
      11) run_action show_logs ;;
      12) run_action change_password ;;
      13) run_action schedule_menu ;;
      14) run_action drop_database ;;
      15) run_action rotate_ssl ;;
      16) run_action uninstall_instance ;;
      17) run_action remote_menu ;;
      0) echo "Selesai."; exit 0 ;;
      *) echo "Pilihan tidak dikenal."; pause ;;
    esac
  done
}

show_status_ssl() {
  show_status || return 1
  echo
  show_ssl
}

set -e
case "${1:-}" in
  backup-auto)
    # Mode non-interaktif untuk scheduler (systemd timer / cron).
    need_cmd docker; need_cmd flock; need_cmd gzip
    set +e
    backup_auto_notify
    exit $?
    ;;
  "") ;;
  *)
    echo "Pemakaian: $0              menu interaktif"
    echo "           $0 backup-auto  backup terjadwal (non-interaktif)"
    exit 2 ;;
esac
need_cmd openssl || exit 1
need_cmd gzip || exit 1
main_menu
