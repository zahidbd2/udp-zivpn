#!/bin/bash
# ZIVPN Helper Script for Backup and Restore

# --- Configuration ---
CONFIG_DIR="/etc/zivpn"
TELEGRAM_CONF="${CONFIG_DIR}/telegram.conf"
BACKUP_FILES=("config.json" "users.db")

# --- Helper Functions ---
function get_host() {
    local CERT_CN
    CERT_CN=$(openssl x509 -in "${CONFIG_DIR}/zivpn.crt" -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
    if [ "$CERT_CN" == "zivpn" ]; then
        curl -s ifconfig.me
    else
        echo "$CERT_CN"
    fi
}

function send_telegram_notification() {
    local message="$1"
    local keyboard="$2"

    if [ ! -f "$TELEGRAM_CONF" ]; then
        return 1
    fi
    # shellcheck source=/etc/zivpn/telegram.conf
    source "$TELEGRAM_CONF"

    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        if [ -n "$keyboard" ]; then
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "reply_markup=${keyboard}" > /dev/null
        else
            curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" > /dev/null
        fi
    fi
}

# --- Core Functions ---
function setup_telegram() {
    echo "--- Konfigurasi Notifikasi Telegram ---"
    read -p "Masukkan Bot API Key Anda: " api_key
    read -p "Masukkan ID Chat Telegram Anda (dapatkan dari @userinfobot): " chat_id

    if [ -z "$api_key" ] || [ -z "$chat_id" ]; then
        echo "API Key dan ID Chat tidak boleh kosong. Pengaturan dibatalkan."
        return 1
    fi

    echo "TELEGRAM_BOT_TOKEN=${api_key}" > "$TELEGRAM_CONF"
    echo "TELEGRAM_CHAT_ID=${chat_id}" >> "$TELEGRAM_CONF"
    chmod 600 "$TELEGRAM_CONF"
    echo "Konfigurasi berhasil disimpan di $TELEGRAM_CONF"
    return 0
}

function handle_backup() {
    echo "--- Memulai Proses Backup ---"

    if [ ! -f "$TELEGRAM_CONF" ]; then
        echo "Kredensial Telegram tidak ditemukan."
        setup_telegram
        if [ $? -ne 0 ]; then
            echo "Proses backup dibatalkan karena konfigurasi Telegram gagal."
            exit 1
        fi
    fi

    # shellcheck source=/etc/zivpn/telegram.conf
    source "$TELEGRAM_CONF"

    local backup_filename="zivpn_backup_$(date +%Y%m%d-%H%M%S).zip"
    local temp_backup_path="/tmp/${backup_filename}"

    echo "Creating backup archive..."
    zip "$temp_backup_path" -j "$CONFIG_DIR/config.json" "$CONFIG_DIR/users.db" > /dev/null
    if [ $? -ne 0 ]; then
        echo "Failed to create backup archive. Aborting."
        rm -f "$temp_backup_path"
        exit 1
    fi

    echo "Sending backup to Telegram..."
    local response
    response=$(curl -s -F "chat_id=${TELEGRAM_CHAT_ID}" -F "document=@${temp_backup_path}" "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendDocument")

    local file_id
    file_id=$(echo "$response" | jq -r '.result.document.file_id')

    if [ -z "$file_id" ] || [ "$file_id" == "null" ]; then
        echo "Failed to upload backup to Telegram. Please check your API Key and Chat ID."
        echo "Telegram API response: $response"
        rm -f "$temp_backup_path"
        exit 1
    fi

    echo "Backup sent successfully. Sending details..."
    local host
    host=$(get_host)
    local current_date
    current_date=$(date +"%d %B %Y")

    local backup_message
    backup_message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
   ⚠️Backup ZIVPN⚠️   
◇━━━━━━━━━━━━━━◇ 
HOST  : ${host}
Tanggal : ${current_date}
Id file    :  ${file_id}
◇━━━━━━━━━━━━━━◇
Silahkan copy id file nya untuk restore
EOF
)
    send_telegram_notification "$backup_message"

    rm -f "$temp_backup_path"
    echo "Backup process complete."
}

function handle_expiry_notification() {
    local host="$1"
    local ip="$2"
    local client="$3"
    local isp="$4"
    local exp_date="$5"

    local message
    message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
 ⛔SC ZIVPN EXPIRED ⛔
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP DATE  : ${exp_date}
◇━━━━━━━━━━━━━━◇
EOF
)

    local keyboard
    keyboard=$(cat <<EOF
{
    "inline_keyboard": [
        [
            {
                "text": "Perpanjang Licence",
                "url": "https://t.me/Kedai_vpn"
            }
        ]
    ]
}
EOF
)
    send_telegram_notification "$message" "$keyboard"
}

function handle_renewed_notification() {
    local host="$1"
    local ip="$2"
    local client="$3"
    local isp="$4"
    local expiry_timestamp="$5"

    local current_timestamp
    current_timestamp=$(date +%s)
    local remaining_seconds=$((expiry_timestamp - current_timestamp))
    local remaining_days=$((remaining_seconds / 86400))

    local message
    message=$(cat <<EOF
◇━━━━━━━━━━━━━━◇
  ✅RENEW SC ZIVPN✅
◇━━━━━━━━━━━━━━◇
IP VPS  : ${ip}
HOST  : ${host}
ISP     : ${isp}
CLIENT : ${client}
EXP : ${remaining_days} Days
◇━━━━━━━━━━━━━━◇
EOF
)
    # Send without a keyboard
    send_telegram_notification "$message"
}

function handle_api_key_notification() {
    local api_key="$1"
    local server_ip="$2"
    local domain="$3"

    local message
    message=$(cat <<EOF
🚀 API UDP ZIVPN 🚀
   🔑 Auth Key: ${api_key}
   🌐 Server IP: ${server_ip}
   🌍 Domain: ${domain}
EOF
)
    send_telegram_notification "$message"
}

function handle_restore() {
    echo "--- Starting Restore Process ---"

    if [ ! -f "$TELEGRAM_CONF" ]; then
        echo "Telegram credentials not found. Cannot perform restore."
        echo "Please run the backup function at least once to configure."
        exit 1
    fi

    # shellcheck source=/etc/zivpn/telegram.conf
    source "$TELEGRAM_CONF"

    read -p "Enter the File ID for the backup you want to restore: " file_id
    if [ -z "$file_id" ]; then
        echo "File ID cannot be empty. Aborting."
        exit 1
    fi

    read -p "WARNING: This will overwrite current user data. Are you sure? (y/n): " confirm
    if [ "$confirm" != "y" ]; then
        echo "Restore cancelled."
        exit 0
    fi

    echo "Fetching file information from Telegram..."
    local response
    response=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${file_id}")
    
    local file_path
    file_path=$(echo "$response" | jq -r '.result.file_path')

    if [ -z "$file_path" ] || [ "$file_path" == "null" ]; then
        echo "Failed to get file path from Telegram. Is the File ID correct?"
        echo "Telegram API response: $response"
        exit 1
    fi

    local download_url="https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${file_path}"
    local temp_restore_path="/tmp/restore_$(basename "$file_path")"

    echo "Downloading backup file..."
    curl -s -o "$temp_restore_path" "$download_url"
    if [ $? -ne 0 ]; then
        echo "Failed to download backup file. Aborting."
        rm -f "$temp_restore_path"
        exit 1
    fi

    echo "Extracting and restoring data..."
    unzip -o "$temp_restore_path" -d "$CONFIG_DIR"
    if [ $? -ne 0 ]; then
        echo "Failed to extract backup archive. Aborting."
        rm -f "$temp_restore_path"
        exit 1
    fi

    rm -f "$temp_restore_path"
    
    echo "Restarting ZIVPN service to apply changes..."
    systemctl restart zivpn.service

    echo "Restore complete! User data has been restored from backup."
}

# --- Main Script Logic ---
case "$1" in
    backup)
        handle_backup
        ;;
    restore)
        handle_restore
        ;;
    setup-telegram)
        setup_telegram
        ;;
    expiry-notification)
        if [ $# -ne 6 ]; then
            echo "Usage: $0 expiry-notification <host> <ip> <client> <isp> <exp_date>"
            exit 1
        fi
        handle_expiry_notification "$2" "$3" "$4" "$5" "$6"
        ;;
    renewed-notification)
        if [ $# -ne 6 ]; then
            echo "Usage: $0 renewed-notification <host> <ip> <client> <isp> <expiry_timestamp>"
            exit 1
        fi
        handle_renewed_notification "$2" "$3" "$4" "$5" "$6"
        ;;
    api-key-notification)
        if [ $# -ne 4 ]; then
            echo "Usage: $0 api-key-notification <api_key> <server_ip> <domain>"
            exit 1
        fi
        handle_api_key_notification "$2" "$3" "$4"
        ;;
    *)
        echo "Usage: $0 {backup|restore|setup-telegram|expiry-notification|renewed-notification|api-key-notification}"
        exit 1
        ;;
esac
