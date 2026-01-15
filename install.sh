#!/bin/bash
# Zivpn UDP Module Manager
# This script installs the base Zivpn service and then sets up an advanced management interface.

# --- UI Definitions ---
YELLOW='\033[1;33m'
RED='\033[0;31m'
BOLD_WHITE='\033[1;37m'
CYAN='\033[0;36m'
GREEN='\033[0;32m'
LIGHT_GREEN='\033[1;32m'
NC='\033[0m' # No Color

# --- License Info ---
LICENSE_URL="https://raw.githubusercontent.com/kedaivpn/izin/main/licence"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"

# --- Pre-flight Checks ---
if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo or run as root user." >&2
  exit 1
fi

# --- License Verification Function ---
function verify_license() {
    echo "Verifying installation license..."
    local SERVER_IP
    SERVER_IP=$(curl -s ifconfig.me)
    if [ -z "$SERVER_IP" ]; then
        echo -e "${RED}Failed to retrieve server IP. Please check your internet connection.${NC}"
        exit 1
    fi

    local license_data
    license_data=$(curl -s "$LICENSE_URL")
    if [ $? -ne 0 ] || [ -z "$license_data" ]; then
        echo -e "${RED}Gagal terhubung ke server lisensi. Mohon periksa koneksi internet Anda.${NC}"
        exit 1
    fi

    local license_entry
    license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")

    if [ -z "$license_entry" ]; then
        echo -e "${RED}Verifikasi Lisensi Gagal! IP Anda tidak terdaftar. IP: ${SERVER_IP}${NC}"
        exit 1
    fi

    local client_name
    local expiry_date_str
    client_name=$(echo "$license_entry" | awk '{print $1}')
    expiry_date_str=$(echo "$license_entry" | awk '{print $2}')

    local expiry_timestamp
    expiry_timestamp=$(date -d "$expiry_date_str" +%s)
    local current_timestamp
    current_timestamp=$(date +%s)

    if [ "$expiry_timestamp" -le "$current_timestamp" ]; then
        echo -e "${RED}Verifikasi Lisensi Gagal! Lisensi untuk IP ${SERVER_IP} telah kedaluwarsa. Tanggal Kedaluwarsa: ${expiry_date_str}${NC}"
        exit 1
    fi
    
    echo -e "${LIGHT_GREEN}Verifikasi Lisensi Berhasil! Client: ${client_name}, IP: ${SERVER_IP}${NC}"
    sleep 2 # Brief pause to show the message
    
    mkdir -p /etc/zivpn
    echo "CLIENT_NAME=${client_name}" > "$LICENSE_INFO_FILE"
    echo "EXPIRY_DATE=${expiry_date_str}" >> "$LICENSE_INFO_FILE"
}

# --- Utility Functions ---
function restart_zivpn() {
    echo "Restarting ZIVPN service..."
    systemctl restart zivpn.service
    echo "Service restarted."
}

# --- Internal Logic Functions (for API calls) ---
function _create_account_api_logic() {
    local password_base="$1"
    local days="$2"
    local db_file="/etc/zivpn/users.db"

    if [ -z "$password_base" ] || [ -z "$days" ]; then
        echo "Error: Password and days are required."
        return 1
    fi

    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid number of days."
        return 1
    fi

    # Generate random suffix and create the new password
    local random_suffix
    random_suffix=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 6)
    local password="${password_base}${random_suffix}"

    if grep -q "^${password}:" "$db_file"; then
        # In the unlikely event of a collision, we can just error out.
        echo "Error: A user with the generated password '${password}' already exists. Please try again."
        return 1
    fi

    local expiry_date
    expiry_date=$(date -d "+$days days" +%s)
    echo "${password}:${expiry_date}" >> "$db_file"

    # Use a temporary file for atomic write
    jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json

    if [ $? -eq 0 ]; then
        # IMPORTANT: The success message now returns the *new* full password
        echo "Success: Account '${password_base}' created with password '${password}', expires in ${days} days."
        restart_zivpn
        return 0
    else
        # Rollback the change in users.db if config update fails
        sed -i "/^${password}:/d" "$db_file"
        echo "Error: Failed to update config.json."
        return 1
    fi
}

function _create_account_logic() {
    local password="$1"
    local days="$2"
    local db_file="/etc/zivpn/users.db"

    if [ -z "$password" ] || [ -z "$days" ]; then
        echo "Error: Password and days are required."
        return 1
    fi
    
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid number of days."
        return 1
    fi

    if grep -q "^${password}:" "$db_file"; then
        echo "Error: Password '${password}' already exists."
        return 1
    fi

    local expiry_date
    expiry_date=$(date -d "+$days days" +%s)
    echo "${password}:${expiry_date}" >> "$db_file"
    
    # Use a temporary file for atomic write
    jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
    
    if [ $? -eq 0 ]; then
        echo "Success: Account '${password}' created, expires in ${days} days."
        restart_zivpn
        return 0
    else
        # Rollback the change in users.db if config update fails
        sed -i "/^${password}:/d" "$db_file"
        echo "Error: Failed to update config.json."
        return 1
    fi
}

# --- Core Logic Functions ---
function create_manual_account() {
    echo "--- Create New Zivpn Account ---"
    read -p "Enter new password: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi

    read -p "Enter active period (in days): " days
    if ! [[ "$days" =~ ^[0-9]+$ ]]; then
        echo "Invalid number of days."
        return
    fi

    # Call the logic function and capture its output
    local result
    result=$(_create_account_logic "$password" "$days")
    
    # Display logic remains here for interactive mode if successful
    if [[ "$result" == "Success"* ]]; then
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        if [ -n "$user_line" ]; then
            local expiry_date
            expiry_date=$(echo "$user_line" | cut -d: -f2)

            local CERT_CN
            CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
            local HOST
            if [ "$CERT_CN" == "zivpn" ]; then
                HOST=$(curl -s ifconfig.me)
            else
                HOST=$CERT_CN
            fi

            local EXPIRE_FORMATTED
            EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y")
            
            clear
            echo "🔹Informasi Akun zivpn Anda🔹"
            echo "┌─────────────────────"
            echo "│ Host: $HOST"
            echo "│ Pass: $password"
            echo "│ Expire: $EXPIRE_FORMATTED"
            echo "└─────────────────────"
            echo "♨ᵗᵉʳⁱᵐᵃᵏᵃˢⁱʰ ᵗᵉˡᵃʰ ᵐᵉⁿᵍᵍᵘⁿᵃᵏᵃⁿ ˡᵃʸᵃⁿᵃⁿ ᵏᵃᵐⁱ♨"
        fi
    else
        # If it failed, show the error message
        echo "$result"
    fi
    
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _generate_api_key() {
    clear
    echo "--- Generate API Authentication Key ---"
    
    # Generate a 6-character alphanumeric key
    local api_key
    api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 6)
    
    local key_file="/etc/zivpn/api_auth.key"
    
    echo "$api_key" > "$key_file"
    chmod 600 "$key_file"
    
    echo "New API authentication key has been generated and saved."
    echo "Key: ${api_key}"
    
    echo "Sending API key to Telegram..."
    # Get Server IP and Domain for the notification
    local server_ip
    server_ip=$(curl -s ifconfig.me)
    local cert_cn
    cert_cn=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    local domain
    if [ "$cert_cn" == "zivpn" ] || [ -z "$cert_cn" ]; then
        domain=$server_ip
    else
        domain=$cert_cn
    fi
    
    /usr/local/bin/zivpn_helper.sh api-key-notification "$api_key" "$server_ip" "$domain"
    
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _create_trial_account_logic() {
    local minutes="$1"
    local db_file="/etc/zivpn/users.db"

    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        echo "Error: Invalid number of minutes."
        return 1
    fi

    local password="trial$(shuf -i 10000-99999 -n 1)"

    local expiry_date
    expiry_date=$(date -d "+$minutes minutes" +%s)
    echo "${password}:${expiry_date}" >> "$db_file"
    
    jq --arg pass "$password" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json
    
    if [ $? -eq 0 ]; then
        echo "Success: Trial account '${password}' created, expires in ${minutes} minutes."
        restart_zivpn
        return 0
    else
        sed -i "/^${password}:/d" "$db_file"
        echo "Error: Failed to update config.json."
        return 1
    fi
}

function create_trial_account() {
    echo "--- Create Trial Zivpn Account ---"
    read -p "Enter active period (in minutes): " minutes
    if ! [[ "$minutes" =~ ^[0-9]+$ ]]; then
        echo "Invalid number of minutes."
        return
    fi

    local result
    result=$(_create_trial_account_logic "$minutes")
    
    if [[ "$result" == "Success"* ]]; then
        # Extract password from the success message
        local password
        password=$(echo "$result" | sed -n "s/Success: Trial account '\([^']*\)'.*/\1/p")
        
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        if [ -n "$user_line" ]; then
            local expiry_date
            expiry_date=$(echo "$user_line" | cut -d: -f2)

            local CERT_CN
            CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p')
            local HOST
            if [ "$CERT_CN" == "zivpn" ]; then
                HOST=$(curl -s ifconfig.me)
            else
                HOST=$CERT_CN
            fi

            local EXPIRE_FORMATTED
            EXPIRE_FORMATTED=$(date -d "@$expiry_date" +"%d %B %Y %H:%M:%S")
            
            clear
            echo "🔹Informasi Akun zivpn Anda🔹"
            echo "┌─────────────────────"
            echo "│ Host: $HOST"
            echo "│ Pass: $password"
            echo "│ Expire: $EXPIRE_FORMATTED"
            echo "└─────────────────────"
            echo "♨ᵗᵉʳⁱᵐᵃᵏᵃˢⁱʰ ᵗᵉˡᵃʰ ᵐᵉⁿᵍᵍᵘⁿᵃᵏᵃⁿ ˡᵃʸᵃⁿᵃⁿ ᵏᵃᵐⁱ♨"
        fi
    else
        echo "$result"
    fi
    
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _renew_account_logic() {
    local password="$1"
    local days="$2"
    local db_file="/etc/zivpn/users.db"

    if [ -z "$password" ] || [ -z "$days" ]; then
        echo "Error: Password and days are required."
        return 1
    fi
    
    if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
        echo "Error: Invalid number of days."
        return 1
    fi

    local user_line
    user_line=$(grep "^${password}:" "$db_file")

    if [ -z "$user_line" ]; then
        echo "Error: Account '${password}' not found."
        return 1
    fi

    local current_expiry_date
    current_expiry_date=$(echo "$user_line" | cut -d: -f2)

    if ! [[ "$current_expiry_date" =~ ^[0-9]+$ ]]; then
        echo "Error: Corrupted database entry for user '$password'."
        return 1
    fi
    
    local seconds_to_add=$((days * 86400))
    local new_expiry_date=$((current_expiry_date + seconds_to_add))
    
    sed -i "s/^${password}:.*/${password}:${new_expiry_date}/" "$db_file"
    echo "Success: Account '${password}' has been renewed for ${days} days."
    return 0
}

function renew_account() {
    clear
    echo "--- Renew Account ---"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Enter password to renew: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi

    read -p "Enter number of days to extend: " days
    if ! [[ "$days" =~ ^[1-9][0-9]*$ ]]; then
        echo "Invalid number of days. Please enter a positive number."
        return
    fi

    local result
    result=$(_renew_account_logic "$password" "$days")
    
    if [[ "$result" == "Success"* ]]; then
        local db_file="/etc/zivpn/users.db"
        local user_line
        user_line=$(grep "^${password}:" "$db_file")
        local new_expiry_date
        new_expiry_date=$(echo "$user_line" | cut -d: -f2)
        local new_expiry_formatted
        new_expiry_formatted=$(date -d "@$new_expiry_date" +"%d %B %Y")
        echo "Account '${password}' has been renewed. New expiry date: ${new_expiry_formatted}."
    else
        echo "$result"
    fi
    read -p "Tekan Enter untuk kembali ke menu..."
}

function _delete_account_logic() {
    local password="$1"
    local db_file="/etc/zivpn/users.db"
    local config_file="/etc/zivpn/config.json"
    local tmp_config_file="${config_file}.tmp"

    if [ -z "$password" ]; then
        echo "Error: Password is required."
        return 1
    fi

    if [ ! -f "$db_file" ] || ! grep -q "^${password}:" "$db_file"; then
        echo "Error: Password '${password}' not found."
        return 1
    fi

    # Step 1: Try to update the config file first to a temporary location
    jq --arg pass "$password" 'del(.auth.config[] | select(. == $pass))' "$config_file" > "$tmp_config_file"
    
    if [ $? -eq 0 ]; then
        # Step 2: If config update is successful, remove user from db
        sed -i "/^${password}:/d" "$db_file"
        
        # Step 3: Atomically replace the old config with the new one
        mv "$tmp_config_file" "$config_file"
        
        echo "Success: Account '${password}' deleted."
        restart_zivpn
        return 0
    else
        # If config update fails, do not touch the db file and report error
        rm -f "$tmp_config_file" # Clean up temp file
        echo "Error: Failed to update config.json. No changes were made."
        return 1
    fi
}

function delete_account() {
    clear
    echo "--- Delete Account ---"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Enter password to delete: " password
    if [ -z "$password" ]; then
        echo "Password cannot be empty."
        return
    fi

    local result
    result=$(_delete_account_logic "$password")
    
    echo "$result" # Display the result from the logic function
    read -p "Tekan Enter untuk kembali ke menu..."
}

function change_domain() {
    echo "--- Change Domain ---"
    read -p "Enter the new domain name for the SSL certificate: " domain
    if [ -z "$domain" ]; then
        echo "Domain name cannot be empty."
        return
    fi

    echo "Generating new certificate for domain '${domain}'..."
    openssl req -new -newkey rsa:4096 -days 365 -nodes -x509 \
        -subj "/C=US/ST=California/L=Los Angeles/O=Example Corp/OU=IT Department/CN=${domain}" \
        -keyout "/etc/zivpn/zivpn.key" -out "/etc/zivpn/zivpn.crt"

    echo "New certificate generated."
    restart_zivpn
}

function _display_accounts() {
    local db_file="/etc/zivpn/users.db"

    if [ ! -f "$db_file" ] || [ ! -s "$db_file" ]; then
        echo "No accounts found."
        return
    fi

    local current_date
    current_date=$(date +%s)
    printf "%-20s | %s\n" "Password" "Expires in (days)"
    echo "------------------------------------------"
    while IFS=':' read -r password expiry_date; do
        if [[ -n "$password" ]]; then
            local remaining_seconds=$((expiry_date - current_date))
            if [ $remaining_seconds -gt 0 ]; then
                local remaining_days=$((remaining_seconds / 86400))
                printf "%-20s | %s days\n" "$password" "$remaining_days"
            else
                printf "%-20s | Expired\n" "$password"
            fi
        fi
    done < "$db_file"
    echo "------------------------------------------"
}

function list_accounts() {
    clear
    echo "--- Active Accounts ---"
    _display_accounts
    echo "" # Add a newline for better spacing
    read -p "Press Enter to return to the menu..."
}

function format_bytes_to_human() {
    local bytes=$1
    if ! [[ "$bytes" =~ ^[0-9]+$ ]] || [ -z "$bytes" ]; then
        bytes=0
    fi
    
    awk -v val="$bytes" 'BEGIN {
        if (val < 1024) {
            printf "%.2f B", val
        } else if (val < 1048576) {
            printf "%.2f KiB", val / 1024
        } else if (val < 1073741824) {
            printf "%.2f MiB", val / 1048576
        } else if (val < 1099511627776) {
            printf "%.2f GiB", val / 1073741824
        } else {
            printf "%.2f TiB", val / 1099511627776
        }
    }'
}

function get_main_interface() {
    # Find the default network interface using the IP route. This is the most reliable method.
    ip -o -4 route show to default | awk '{print $5}' | head -n 1
}

function _draw_info_panel() {
    # --- Fetch Data ---
    local os_info isp_info ip_info host_info bw_today bw_month client_name license_exp

    os_info=$( (hostnamectl 2>/dev/null | grep "Operating System" | cut -d: -f2 | sed 's/^[ \t]*//') || echo "N/A" )
    os_info=${os_info:-"N/A"}

    local ip_data
    ip_data=$(curl -s ipinfo.io)
    ip_info=$(echo "$ip_data" | jq -r '.ip // "N/A"')
    isp_info=$(echo "$ip_data" | jq -r '.org // "N/A"')
    ip_info=${ip_info:-"N/A"}
    isp_info=${isp_info:-"N/A"}

    local CERT_CN
    CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
        host_info=$ip_info
    else
        host_info=$CERT_CN
    fi
    host_info=${host_info:-"N/A"}

    if command -v vnstat &> /dev/null; then
        local iface
        iface=$(get_main_interface)
        local current_year current_month current_day
        current_year=$(date +%Y)
        current_month=$(date +%-m) # Use %-m to avoid leading zero
        current_day=$(date +%-d) # Use %-d to avoid leading zero for days < 10

        # Run vnstat --json once to get all data (vnstat 2.x compatible)
        local vnstat_json
        vnstat_json=$(vnstat --json 2>/dev/null)

        # Daily (Sum rx + tx from .traffic.day)
        local today_bytes=0
        if [[ -n "$vnstat_json" && "$vnstat_json" == "{"* ]]; then
            today_bytes=$(echo "$vnstat_json" | jq --arg iface "$iface" --argjson year "$current_year" --argjson month "$current_month" --argjson day "$current_day" '
              (
                (.interfaces[] | select(.name == $iface) | .traffic.day // [])[] 
                | select(.date.year == $year and .date.month == $month and .date.day == $day) 
                | .rx + .tx
              ) // 0
            ' | head -n 1)
        fi
        bw_today=$(format_bytes_to_human "$today_bytes")

        # Monthly (Sum rx + tx from .traffic.month)
        local month_bytes=0
        if [[ -n "$vnstat_json" && "$vnstat_json" == "{"* ]]; then
             month_bytes=$(echo "$vnstat_json" | jq --arg iface "$iface" --argjson year "$current_year" --argjson month "$current_month" '
              (
                (.interfaces[] | select(.name == $iface) | .traffic.month // [])[] 
                | select(.date.year == $year and .date.month == $month) 
                | .rx + .tx
              ) // 0
            ' | head -n 1)
        fi
        bw_month=$(format_bytes_to_human "$month_bytes")

    else
        bw_today="N/A"
        bw_month="N/A"
    fi

    # --- License Info ---
    if [ -f "$LICENSE_INFO_FILE" ]; then
        source "$LICENSE_INFO_FILE" # Loads CLIENT_NAME and EXPIRY_DATE
        client_name=${CLIENT_NAME:-"N/A"}
        
        if [ -n "$EXPIRY_DATE" ]; then
            local expiry_timestamp
            expiry_timestamp=$(date -d "$EXPIRY_DATE" +%s)
            local current_timestamp
            current_timestamp=$(date +%s)
            local remaining_seconds=$((expiry_timestamp - current_timestamp))
            if [ $remaining_seconds -gt 0 ]; then
                license_exp="$((remaining_seconds / 86400)) days"
            else
                license_exp="Expired"
            fi
        else
            license_exp="N/A"
        fi
    else
        client_name="N/A"
        license_exp="N/A"
    fi

    # --- Print Panel ---
    printf "  ${RED}%-7s${BOLD_WHITE}%-18s ${RED}%-6s${BOLD_WHITE}%-19s${NC}\n" "OS:" "${os_info}" "ISP:" "${isp_info}"
    printf "  ${RED}%-7s${BOLD_WHITE}%-18s ${RED}%-6s${BOLD_WHITE}%-19s${NC}\n" "IP:" "${ip_info}" "Host:" "${host_info}"
    printf "  ${RED}%-7s${BOLD_WHITE}%-18s ${RED}%-6s${BOLD_WHITE}%-19s${NC}\n" "Client:" "${client_name}" "EXP:" "${license_exp}"
    printf "  ${RED}%-7s${BOLD_WHITE}%-18s ${RED}%-6s${BOLD_WHITE}%-19s${NC}\n" "Today:" "${bw_today}" "Month:" "${bw_month}"
}

function _draw_service_status() {
    local status_text status_color status_output
    local service_status
    service_status=$(systemctl is-active zivpn.service 2>/dev/null)

    if [ "$service_status" = "active" ]; then
        status_text="Running"
        status_color="${LIGHT_GREEN}"
    elif [ "$service_status" = "inactive" ]; then
        status_text="Stopped"
        status_color="${RED}"
    elif [ "$service_status" = "failed" ]; then
        status_text="Error"
        status_color="${RED}"
    else
        status_text="Unknown"
        status_color="${RED}"
    fi

    status_output="${CYAN}Service: ${status_color}${status_text}${NC}"
    
    # Center the text
    local menu_width=55  # Total width of the menu box including borders
    local text_len_visible
    text_len_visible=$(echo -e "$status_output" | sed 's/\x1b\[[0-9;]*m//g' | wc -c)
    text_len_visible=$((text_len_visible - 1))

    local padding_total=$((menu_width - text_len_visible))
    local padding_left=$((padding_total / 2))
    local padding_right=$((padding_total - padding_left))
    
    echo -e "${YELLOW}╠════════════════════════════════════════════════════╣${NC}"
    echo -e "$(printf '%*s' $padding_left)${status_output}$(printf '%*s' $padding_right)"
    echo -e "${YELLOW}╠════════════════════════════════════════════════════╣${NC}"
}

function setup_auto_backup() {
    echo "--- Configure Auto Backup ---"
    if [ ! -f "/etc/zivpn/telegram.conf" ]; then
        echo "Telegram is not configured. Please run a manual backup once to set it up."
        return
    fi

    read -p "Enter backup interval in hours (e.g., 6, 12, 24). Enter 0 to disable: " interval
    if ! [[ "$interval" =~ ^[0-9]+$ ]]; then
        echo "Invalid input. Please enter a number."
        return
    fi

    (crontab -l 2>/dev/null | grep -v "# zivpn-auto-backup") | crontab -

    if [ "$interval" -gt 0 ]; then
        local cron_schedule="0 */${interval} * * *"
        (crontab -l 2>/dev/null; echo "${cron_schedule} /usr/local/bin/zivpn_helper.sh backup >/dev/null 2>&1 # zivpn-auto-backup") | crontab -
        echo "Auto backup scheduled to run every ${interval} hour(s)."
    else
        echo "Auto backup has been disabled."
    fi
}

function create_account() {
    clear
    echo -e "${YELLOW}╔════════════════// ${RED}Create Account${YELLOW} //════════════════╗${NC}"
    echo -e "${YELLOW}║                                                    ║${NC}"
    echo -e "${YELLOW}║   ${RED}1)${NC} ${BOLD_WHITE}Create Zivpn                                  ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}2)${NC} ${BOLD_WHITE}Trial Zivpn                                   ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}0)${NC} ${BOLD_WHITE}Back to Main Menu                             ${YELLOW}║${NC}"
    echo -e "${YELLOW}║                                                    ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════╝${NC}"
    
    read -p "Enter your choice [0-2]: " choice

    case $choice in
        1) create_manual_account ;;
        2) create_trial_account ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
}

function show_backup_menu() {
    clear
    echo -e "${YELLOW}╔═══════════════// ${RED}Backup/Restore${YELLOW} //═══════════════╗${NC}"
    echo -e "${YELLOW}║                                                  ║${NC}"
    echo -e "${YELLOW}║   ${RED}1)${NC} ${BOLD_WHITE}Backup Data                                 ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}2)${NC} ${BOLD_WHITE}Restore Data                                ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}3)${NC} ${BOLD_WHITE}Auto Backup                                 ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}4)${NC} ${BOLD_WHITE}Atur Ulang Notifikasi Telegram              ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}0)${NC} ${BOLD_WHITE}Back to Main Menu                           ${YELLOW}║${NC}"
    echo -e "${YELLOW}║                                                  ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════╝${NC}"
    
    read -p "Enter your choice [0-4]: " choice
    
    case $choice in
        1) /usr/local/bin/zivpn_helper.sh backup ;;
        2) /usr/local/bin/zivpn_helper.sh restore ;;
        3) setup_auto_backup ;;
        4) /usr/local/bin/zivpn_helper.sh setup-telegram ;;
        0) return ;;
        *) echo "Invalid option." ;;
    esac
}

function show_expired_message_and_exit() {
    clear
    echo -e "\n${RED}=====================================================${NC}"
    echo -e "${RED}           LISENSI ANDA TELAH KEDALUWARSA!           ${NC}"
    echo -e "${RED}=====================================================${NC}\n"
    echo -e "${BOLD_WHITE}Akses ke layanan ZIVPN di server anda telah dihentikan."
    echo -e "Segala aktivitas VPN tidak akan berfungsi lagi.\n"
    echo -e "Untuk memperpanjang lisensi dan mengaktifkan kembali layanan,"
    echo -e "silakan hubungi admin https://wa.me/6287777694482 \n"
    echo -e "${LIGHT_GREEN}Setelah diperpanjang, layanan akan aktif kembali secara otomatis.${NC}\n"
    exit 0
}

function show_menu() {
    if [ -f "/etc/zivpn/.expired" ]; then
        show_expired_message_and_exit
    fi

    clear
    figlet "UDP ZIVPN" | lolcat
    
    echo -e "${YELLOW}╔══════════════════// ${CYAN}KEDAI SSH${YELLOW} //═══════════════════╗${NC}"
    _draw_info_panel
    _draw_service_status
    echo -e "${YELLOW}║                                                    ║${NC}"
    echo -e "${YELLOW}║   ${RED}1)${NC} ${BOLD_WHITE}Create Account                                ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}2)${NC} ${BOLD_WHITE}Renew Account                                 ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}3)${NC} ${BOLD_WHITE}Delete Account                                ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}4)${NC} ${BOLD_WHITE}Change Domain                                 ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}5)${NC} ${BOLD_WHITE}List Accounts                                 ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}6)${NC} ${BOLD_WHITE}Backup/Restore                                ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}7)${NC} ${BOLD_WHITE}Generate API Auth Key                         ${YELLOW}║${NC}"
    echo -e "${YELLOW}║   ${RED}0)${NC} ${BOLD_WHITE}Exit                                          ${YELLOW}║${NC}"
    echo -e "${YELLOW}║                                                    ║${NC}"
    echo -e "${YELLOW}╚════════════════════════════════════════════════════╝${NC}"
    
    read -p "Enter your choice [0-7]: " choice

    case $choice in
        1) create_account ;;
        2) renew_account ;;
        3) delete_account ;;
        4) change_domain ;;
        5) list_accounts ;;
        6) show_backup_menu ;;
        7) _generate_api_key ;;
        0) exit 0 ;;
        *) echo "Invalid option. Please try again." ;;
    esac
}

# --- Main Installation and Setup Logic ---
function run_setup() {
    verify_license # <-- VERIFY LICENSE HERE

    # --- Run Base Installation ---
    echo "--- Starting Base Installation ---"
    wget -O zi.sh https://raw.githubusercontent.com/kedaivpn/udp-zivpn/main/zi.sh
    if [ $? -ne 0 ]; then echo "Failed to download base installer. Aborting."; exit 1; fi
    chmod +x zi.sh
    ./zi.sh
    if [ $? -ne 0 ]; then echo "Base installation script failed. Aborting."; exit 1; fi
    rm zi.sh
    echo "--- Base Installation Complete ---"

    # --- Setting up Advanced Management ---
    echo "--- Setting up Advanced Management ---"

    if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null || ! command -v zip &> /dev/null || ! command -v figlet &> /dev/null || ! command -v lolcat &> /dev/null || ! command -v vnstat &> /dev/null; then
        echo "Installing dependencies (jq, curl, zip, figlet, lolcat, vnstat)..."
        apt-get update && apt-get install -y jq curl zip figlet lolcat vnstat
    fi

    # --- vnstat setup ---
    echo "Configuring vnstat for bandwidth monitoring..."
    local net_interface
    net_interface=$(ip -o -4 route show to default | awk '{print $5}' | head -n 1)
    if [ -n "$net_interface" ]; then
        echo "Detected network interface: $net_interface"
        # Wait for the service to be available after installation
        sleep 2
        systemctl stop vnstat
        vnstat -u -i "$net_interface" --force
        systemctl enable vnstat
        systemctl start vnstat
        echo "vnstat setup complete for interface $net_interface."
    else
        echo "Warning: Could not automatically detect network interface for vnstat."
    fi
    
    # Download helper script from repository
    echo "Downloading helper script..."
    wget -O /usr/local/bin/zivpn_helper.sh https://raw.githubusercontent.com/kedaivpn/udp-zivpn/main/zivpn_helper.sh
    if [ $? -ne 0 ]; then
        echo "Failed to download helper script. Aborting."
        exit 1
    fi
    chmod +x /usr/local/bin/zivpn_helper.sh

    echo "Clearing initial password(s) set during base installation..."
    jq '.auth.config = []' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json

    touch /etc/zivpn/users.db

    RANDOM_PASS="zivpn$(shuf -i 10000-99999 -n 1)"
    EXPIRY_DATE=$(date -d "+1 day" +%s)

    echo "Creating a temporary initial account..."
    echo "${RANDOM_PASS}:${EXPIRY_DATE}" >> /etc/zivpn/users.db
    jq --arg pass "$RANDOM_PASS" '.auth.config += [$pass]' /etc/zivpn/config.json > /etc/zivpn/config.json.tmp && mv /etc/zivpn/config.json.tmp /etc/zivpn/config.json

    echo "Setting up expiry check cron job..."
    cat <<'EOF' > /etc/zivpn/expire_check.sh
#!/bin/bash
DB_FILE="/etc/zivpn/users.db"
CONFIG_FILE="/etc/zivpn/config.json"
TMP_DB_FILE="${DB_FILE}.tmp"
CURRENT_DATE=$(date +%s)
SERVICE_RESTART_NEEDED=false

if [ ! -f "$DB_FILE" ]; then exit 0; fi
> "$TMP_DB_FILE"

while IFS=':' read -r password expiry_date; do
    if [[ -z "$password" ]]; then continue; fi

    if [ "$expiry_date" -le "$CURRENT_DATE" ]; then
        echo "User '${password}' has expired. Deleting permanently."
        jq --arg pass "$password" 'del(.auth.config[] | select(. == $pass))' "$CONFIG_FILE" > "${CONFIG_FILE}.tmp" && mv "${CONFIG_FILE}.tmp" "$CONFIG_FILE"
        SERVICE_RESTART_NEEDED=true
    else
        echo "${password}:${expiry_date}" >> "$TMP_DB_FILE"
    fi
done < "$DB_FILE"

mv "$TMP_DB_FILE" "$DB_FILE"

if [ "$SERVICE_RESTART_NEEDED" = true ]; then
    echo "Restarting zivpn service due to user removal."
    systemctl restart zivpn.service
fi
exit 0
EOF
    chmod +x /etc/zivpn/expire_check.sh
    CRON_JOB_EXPIRY="* * * * * /etc/zivpn/expire_check.sh # zivpn-expiry-check"
    (crontab -l 2>/dev/null | grep -v "# zivpn-expiry-check") | crontab -
    (crontab -l 2>/dev/null; echo "$CRON_JOB_EXPIRY") | crontab -

    echo "Setting up license check script and cron job..."
    cat <<'EOF' > /etc/zivpn/license_checker.sh
#!/bin/bash
# Zivpn License Checker
# This script is run by a cron job to periodically check the license status.

# --- Configuration ---
LICENSE_URL="https://raw.githubusercontent.com/kedaivpn/izin/main/licence"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"
EXPIRED_LOCK_FILE="/etc/zivpn/.expired"
TELEGRAM_CONF="/etc/zivpn/telegram.conf"
LOG_FILE="/var/log/zivpn_license.log"

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# --- Helper Functions ---
function get_host() {
    local CERT_CN
    CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
        curl -s ifconfig.me
    else
        echo "$CERT_CN"
    fi
}

function get_isp() {
    curl -s ipinfo.io | jq -r '.org // "N/A"'
}


# --- Telegram Notification Function ---
send_telegram_message() {
    local message="$1"
    
    if [ ! -f "$TELEGRAM_CONF" ]; then
        log "Telegram config not found, skipping notification."
        return
    fi
    
    source "$TELEGRAM_CONF"
    if [ -n "$TELEGRAM_BOT_TOKEN" ] && [ -n "$TELEGRAM_CHAT_ID" ]; then
        local api_url="https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage"
        curl -s -X POST "$api_url" -d "chat_id=${TELEGRAM_CHAT_ID}" --data-urlencode "text=${message}" -d "parse_mode=Markdown" > /dev/null
        log "Simple telegram notification sent."
    else
        log "Telegram config found but token or chat ID is missing."
    fi
}

# --- Main Logic ---
log "Starting license check..."

# 1. Get Server IP
SERVER_IP=$(curl -s ifconfig.me)
if [ -z "$SERVER_IP" ]; then
    log "Error: Failed to retrieve server IP. Exiting."
    exit 1
fi

# 2. Get Local License Info
if [ ! -f "$LICENSE_INFO_FILE" ]; then
    log "Error: Local license info file not found. Exiting."
    exit 1
fi
source "$LICENSE_INFO_FILE" # This loads CLIENT_NAME and EXPIRY_DATE

# 3. Fetch Remote License Data
license_data=$(curl -s "$LICENSE_URL")
if [ $? -ne 0 ] || [ -z "$license_data" ]; then
    log "Error: Failed to connect to license server. Exiting."
    exit 1
fi

# 4. Check License Status from Remote
license_entry=$(echo "$license_data" | grep -w "$SERVER_IP")

if [ -z "$license_entry" ]; then
    # IP not found in remote list (Revoked)
    if [ ! -f "$EXPIRED_LOCK_FILE" ]; then
        log "License for IP ${SERVER_IP} has been REVOKED."
        systemctl stop zivpn.service
        touch "$EXPIRED_LOCK_FILE"
        local MSG="Notifikasi Otomatis: Lisensi untuk Klien \`${CLIENT_NAME}\` dengan IP \`${SERVER_IP}\` telah dicabut (REVOKED). Layanan zivpn telah dihentikan."
        send_telegram_message "$MSG"
    fi
    exit 0
fi

# 5. IP Found, Check for Expiry or Renewal
client_name_remote=$(echo "$license_entry" | awk '{print $1}')
expiry_date_remote=$(echo "$license_entry" | awk '{print $2}')
expiry_timestamp_remote=$(date -d "$expiry_date_remote" +%s)
current_timestamp=$(date +%s)

# Update local license info file with the latest from server
if [ "$expiry_date_remote" != "$EXPIRY_DATE" ]; then
    log "Remote license has a different expiry date (${expiry_date_remote}). Updating local file."
    echo "CLIENT_NAME=${client_name_remote}" > "$LICENSE_INFO_FILE"
    echo "EXPIRY_DATE=${expiry_date_remote}" >> "$LICENSE_INFO_FILE"
    CLIENT_NAME=$client_name_remote
    EXPIRY_DATE=$expiry_date_remote
fi

if [ "$expiry_timestamp_remote" -le "$current_timestamp" ]; then
    # License is EXPIRED
    if [ ! -f "$EXPIRED_LOCK_FILE" ]; then
        log "License for IP ${SERVER_IP} has EXPIRED."
        systemctl stop zivpn.service
        touch "$EXPIRED_LOCK_FILE"
        local host
        host=$(get_host)
        local isp
        isp=$(get_isp)
        log "Sending rich expiry notification via helper script..."
        /usr/local/bin/zivpn_helper.sh expiry-notification "$host" "$SERVER_IP" "$CLIENT_NAME" "$isp" "$EXPIRY_DATE"
    fi
else
    # License is ACTIVE (potentially renewed)
    if [ -f "$EXPIRED_LOCK_FILE" ]; then
        log "License for IP ${SERVER_IP} has been RENEWED/ACTIVATED."
        rm "$EXPIRED_LOCK_FILE"
        systemctl start zivpn.service
        local host
        host=$(get_host)
        local isp
        isp=$(get_isp)
        log "Sending rich renewed notification via helper script..."
        /usr/local/bin/zivpn_helper.sh renewed-notification "$host" "$SERVER_IP" "$CLIENT_NAME" "$isp" "$expiry_timestamp_remote"
    else
        log "License is active and valid. No action needed."
    fi
fi

log "License check finished."
exit 0
EOF
    chmod +x /etc/zivpn/license_checker.sh

    CRON_JOB_LICENSE="*/5 * * * * /etc/zivpn/license_checker.sh # zivpn-license-check"
    (crontab -l 2>/dev/null | grep -v "# zivpn-license-check") | crontab -
    (crontab -l 2>/dev/null; echo "$CRON_JOB_LICENSE") | crontab -

    # --- Telegram Notification Setup ---
    if [ ! -f "/etc/zivpn/telegram.conf" ]; then
        echo ""
        read -p "Apakah Anda ingin mengatur notifikasi Telegram untuk status lisensi? (y/n): " confirm
        if [[ "$confirm" == [yY] || "$confirm" == [yY][eE][sS] ]]; then
            /usr/local/bin/zivpn_helper.sh setup-telegram
        else
            echo "Anda dapat mengaturnya nanti melalui menu Backup/Restore."
        fi
    fi

    restart_zivpn

    # --- API Setup ---
    echo "--- Setting up REST API Service ---"
    
    # 1. Install Node.js v18
    if ! command -v node &> /dev/null; then
        echo "Node.js not found. Installing Node.js v18..."
        curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
        sudo apt-get install -y nodejs
    else
        echo "Node.js is already installed."
    fi
    
    # 2. Create API directory and files
    mkdir -p /etc/zivpn/api
    
    cat <<'EOF' > /etc/zivpn/api/package.json
{
  "name": "zivpn-api",
  "version": "1.0.0",
  "description": "API for managing ZIVPN",
  "main": "api.js",
  "scripts": { "start": "node api.js" },
  "dependencies": { "express": "^4.17.1" }
}
EOF

    cat <<'EOF' > /etc/zivpn/api/api.js
const express = require('express');
const { execFile } = require('child_process');
const fs = require('fs');
const app = express();
const PORT = 5888;
const AUTH_KEY_PATH = '/etc/zivpn/api_auth.key';
const ZIVPN_MANAGER_SCRIPT = '/usr/local/bin/zivpn-manager';

const authenticate = (req, res, next) => {
    const providedAuthKey = req.query.auth;
    if (!providedAuthKey) return res.status(401).json({ status: 'error', message: 'Authentication key is required.' });

    fs.readFile(AUTH_KEY_PATH, 'utf8', (err, storedKey) => {
        if (err) return res.status(500).json({ status: 'error', message: 'Could not read authentication key.' });
        if (providedAuthKey.trim() !== storedKey.trim()) return res.status(403).json({ status: 'error', message: 'Invalid authentication key.' });
        next();
    });
};
app.use(authenticate);

const executeZivpnManager = (command, args, res) => {
    execFile('sudo', [ZIVPN_MANAGER_SCRIPT, command, ...args], (error, stdout, stderr) => {
        if (error) {
            const errorMessage = stderr.includes('Error:') ? stderr : 'An internal server error occurred.';
            return res.status(500).json({ status: 'error', message: errorMessage.trim() });
        }
        if (stdout.toLowerCase().includes('success')) {
            res.json({ status: 'success', message: stdout.trim() });
        } else {
            res.status(400).json({ status: 'error', message: stdout.trim() });
        }
    });
};

app.all('/create/zivpn', (req, res) => {
    const { password, exp } = req.query;
    if (!password || !exp) return res.status(400).json({ status: 'error', message: 'Parameters password and exp are required.' });
    executeZivpnManager('create_account', [password, exp], res);
});
app.all('/delete/zivpn', (req, res) => {
    const { password } = req.query;
    if (!password) return res.status(400).json({ status: 'error', message: 'Parameter password is required.' });
    executeZivpnManager('delete_account', [password], res);
});
app.all('/renew/zivpn', (req, res) => {
    const { password, exp } = req.query;
    if (!password || !exp) return res.status(400).json({ status: 'error', message: 'Parameters password and exp are required.' });
    executeZivpnManager('renew_account', [password, exp], res);
});
app.all('/trial/zivpn', (req, res) => {
    const { exp } = req.query;
    if (!exp) return res.status(400).json({ status: 'error', message: 'Parameter exp is required.' });
    executeZivpnManager('trial_account', [exp], res);
});

app.listen(PORT, () => console.log('ZIVPN API server running on port ' + PORT));
EOF

    # 3. Install npm dependencies
    echo "Installing API dependencies..."
    npm install --prefix /etc/zivpn/api
    
    # 4. Create and enable systemd service
    cat <<'EOF' > /etc/systemd/system/zivpn-api.service
[Unit]
Description=ZIVPN REST API Service
After=network.target
[Service]
Type=simple
User=root
WorkingDirectory=/etc/zivpn/api
ExecStart=/usr/bin/node /etc/zivpn/api/api.js
Restart=on-failure
[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable zivpn-api.service
    systemctl start zivpn-api.service
    
    # 5. Generate initial API key
    echo "Generating initial API key..."
    local initial_api_key
    initial_api_key=$(LC_ALL=C tr -dc 'a-zA-Z0-9' < /dev/urandom | head -c 6)
    echo "$initial_api_key" > /etc/zivpn/api_auth.key
    chmod 600 /etc/zivpn/api_auth.key
    
    # 6. Open firewall port
    echo "Opening firewall port 5888 for API..."
    iptables -I INPUT -p tcp --dport 5888 -j ACCEPT
    
    echo "--- API Setup Complete ---"


    # --- System Integration ---
    echo "--- Integrating management script into the system ---"
    cp "$0" /usr/local/bin/zivpn-manager
    chmod +x /usr/local/bin/zivpn-manager

    PROFILE_FILE="/root/.bashrc"
    if [ -f "/root/.bash_profile" ]; then PROFILE_FILE="/root/.bash_profile"; fi
    
    ALIAS_CMD="alias menu='/usr/local/bin/zivpn-manager'"
    AUTORUN_CMD="/usr/local/bin/zivpn-manager"

    grep -qF "$ALIAS_CMD" "$PROFILE_FILE" || echo "$ALIAS_CMD" >> "$PROFILE_FILE"
    grep -qF "$AUTORUN_CMD" "$PROFILE_FILE" || echo "$AUTORUN_CMD" >> "$PROFILE_FILE"

    echo "The 'menu' command is now available."
    echo "The management menu will now open automatically on login."
    
    echo "-----------------------------------------------------"
    echo "Advanced management setup complete."
    echo "Password for temporary account (expires 24h): ${RANDOM_PASS}"
    echo "-----------------------------------------------------"
    read -p "Press Enter to continue to the management menu..."
}

# --- Main Script ---
function main() {
    # Non-interactive mode for API calls
    if [ "$#" -gt 0 ]; then
        local command="$1"
        shift
        case "$command" in
            create_account)
                _create_account_api_logic "$@"
                ;;
            delete_account)
                _delete_account_logic "$@"
                ;;
            renew_account)
                _renew_account_logic "$@"
                ;;
            trial_account)
                _create_trial_account_logic "$@"
                ;;
            *)
                echo "Error: Unknown command '$command'"
                exit 1
                ;;
        esac
        exit $?
    fi

    if [ ! -f "/etc/systemd/system/zivpn.service" ]; then
        run_setup
    fi

    while true; do
        show_menu
    done
}

# Execute main function only when script is run directly, not sourced
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
