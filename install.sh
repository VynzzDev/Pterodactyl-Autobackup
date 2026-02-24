#!/bin/bash
#################################################################
#  Auto backup script by VynzzDev                               #
#                                                               #
#                                                               #
#  Contributors:                                                #
#  VynzzDev                                                     #
#                                                               #
#  Link: https://vynzzhost.com                                  #
#                                                               #
#################################################################

set -e

if [ "$(id -u)" -ne 0 ]; then
    echo "Please run this installer as root."
    exit 1
fi

echo "======================================"
echo "     AutoBackup Production Installer  "
echo "======================================"

BASE_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL_DIR="/etc/autobackup"
BIN_PATH="/usr/local/bin/autobackup"
LOG_FILE="/var/log/autobackup.log"
CRON_LOG="/var/log/autobackup-cron.log"

if [ -f "$BASE_DIR/config.env" ]; then
    source "$BASE_DIR/config.env"
fi

TZ="${TZ:-UTC}"
BACKUP_CRON="${BACKUP_CRON:-0 3 * * *}"

echo "[1/6] Installing dependencies..."

if command -v apt-get >/dev/null 2>&1; then
    apt-get update -y
    apt-get install -y tar pigz curl grep sed findutils util-linux dos2unix
elif command -v dnf >/dev/null 2>&1; then
    dnf install -y tar pigz curl grep sed findutils util-linux dos2unix
elif command -v yum >/dev/null 2>&1; then
    yum install -y tar pigz curl grep sed findutils util-linux dos2unix
elif command -v pacman >/dev/null 2>&1; then
    pacman -Syu --noconfirm
    pacman -S --noconfirm tar pigz curl grep sed findutils util-linux dos2unix
else
    echo "Unsupported OS"
    exit 1
fi

echo "[2/6] Installing rclone (if not installed)..."
if ! command -v rclone >/dev/null 2>&1; then
    curl https://rclone.org/install.sh | bash
fi

echo "[3/6] Creating required directories..."
mkdir -p "$INSTALL_DIR"
mkdir -p "$INSTALL_DIR/temp"
mkdir -p "$(dirname "$LOG_FILE")"

touch "$LOG_FILE"
touch "$CRON_LOG"

echo "[4/6] Copying configuration..."
cp -f "$BASE_DIR/config.env" "$INSTALL_DIR/config.env"

echo "[5/6] Installing main backup binary..."
cp -f "$BASE_DIR/src/backup.sh" "$BIN_PATH"
chmod +x "$BIN_PATH"

echo "Converting line endings to Unix format..."
dos2unix "$INSTALL_DIR/config.env" >/dev/null 2>&1 || true
dos2unix "$BIN_PATH" >/dev/null 2>&1 || true

echo "[6/6] Setting timezone & cron job..."

if command -v timedatectl >/dev/null 2>&1; then
    if timedatectl list-timezones | grep -qx "$TZ"; then
        timedatectl set-timezone "$TZ"
        echo "Timezone set to $TZ"
    else
        echo "Invalid timezone: $TZ"
        echo "Using system default timezone."
    fi
fi

CRON_JOB="$BACKUP_CRON $BIN_PATH >> $CRON_LOG 2>&1"

( crontab -l 2>/dev/null | grep -v "$BIN_PATH" ; echo "$CRON_JOB" ) | crontab -

echo "Cron job installed: $BACKUP_CRON"

echo "======================================"
echo "Installation completed successfully!"
echo "Binary: $BIN_PATH"
echo "Config: $INSTALL_DIR/config.env"
echo "Log:    $LOG_FILE"
echo "======================================"

echo
read -p "Do you want to run backup now? (y/n): " RUN_NOW

if [[ "$RUN_NOW" == "y" || "$RUN_NOW" == "Y" ]]; then
    echo "Running backup..."
    $BIN_PATH
else
    echo "Installation finished. Backup schedule: $BACKUP_CRON (Timezone: $TZ)"
fi

exit 0