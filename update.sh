#!/bin/bash
# Zivpn Update Script
# This script applies the update for the Vercel API License Migration.
# Run this as root.

if [ "$(id -u)" -ne 0 ]; then
  echo "This script must be run as root. Please use sudo or run as root user." >&2
  exit 1
fi

echo "--- Updating Zivpn Components ---"

# 1. Commenting out previous update logic (zivpn_helper.sh)
# echo "Updating zivpn_helper.sh..."
# wget -O /usr/local/bin/zivpn_helper.sh https://raw.githubusercontent.com/kedaivpn/udp-zivpn/main/zivpn_helper.sh
# if [ $? -ne 0 ]; then
#     echo "Warning: Failed to download zivpn_helper.sh from main repo. Skipping."
# else
#     chmod +x /usr/local/bin/zivpn_helper.sh
#     echo "zivpn_helper.sh updated successfully."
# fi

# 2. Install dependencies
echo "Installing dependencies..."
if ! command -v jq &> /dev/null || ! command -v curl &> /dev/null; then
    apt-get update -y > /dev/null 2>&1
    apt-get install -y jq curl > /dev/null 2>&1
fi

# 3. Update license_checker.sh
echo "Updating license_checker.sh..."
cat <<'EOF' > /etc/zivpn/license_checker.sh
#!/bin/bash
# Zivpn License Checker
# This script is run by a cron job to periodically check the license status.

# --- Configuration ---
LICENSE_URL="https://licence-manager-nu.vercel.app/api/check"
LICENSE_INFO_FILE="/etc/zivpn/.license_info"
EXPIRED_LOCK_FILE="/etc/zivpn/.expired"
TELEGRAM_CONF="/etc/zivpn/telegram.conf"
LOG_FILE="/var/log/zivpn_license.log"

# --- Logging ---
log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" >> "$LOG_FILE"
}

# --- Helper Functions ---
function get_public_ip() {
    local ip=""
    # List of services to try
    local services=(
        "https://api.ipify.org"
        "https://ifconfig.me/ip"
        "https://icanhazip.com"
        "https://ipinfo.io/ip"
        "https://checkip.amazonaws.com"
    )

    for service in "${services[@]}"; do
        # Use curl with timeout, silence output, follow redirects
        ip=$(curl -s --max-time 3 "$service" | tr -d '[:space:]')

        # Check if the retrieved string is a valid IPv4 address
        if [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "$ip"
            return 0
        fi
    done

    return 1
}

function get_host() {
    local CERT_CN
    CERT_CN=$(openssl x509 -in /etc/zivpn/zivpn.crt -noout -subject | sed -n 's/.*CN = \([^,]*\).*/\1/p' 2>/dev/null || echo "")
    if [ "$CERT_CN" == "zivpn" ] || [ -z "$CERT_CN" ]; then
        local ip
        ip=$(get_public_ip)
        if [ -n "$ip" ]; then
            echo "$ip"
        else
            echo "N/A"
        fi
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
SERVER_IP=$(get_public_ip)
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
license_data=$(curl -s "${LICENSE_URL}?ip=${SERVER_IP}")
if [ $? -ne 0 ] || [ -z "$license_data" ]; then
    log "Error: Failed to connect to license server. Exiting."
    exit 1
fi

# 4. Check License Status from Remote
valid=$(echo "$license_data" | jq -r '.valid')

if [ "$valid" != "true" ]; then
    # IP not found in remote list (Revoked / Banned)
    msg=$(echo "$license_data" | jq -r '.message // "IP Anda tidak terdaftar atau dibanned."')
    if [ ! -f "$EXPIRED_LOCK_FILE" ]; then
        log "License for IP ${SERVER_IP} is INVALID/REVOKED: ${msg}"
        systemctl stop zivpn.service
        touch "$EXPIRED_LOCK_FILE"
        MSG="Notifikasi Otomatis: Lisensi untuk Klien \`${CLIENT_NAME}\` dengan IP \`${SERVER_IP}\` telah dicabut/tidak valid (${msg}). Layanan zivpn telah dihentikan."
        send_telegram_message "$MSG"
    fi
    exit 0
fi

# 5. License Valid, Check for Expiry or Renewal
client_name_remote=$(echo "$license_data" | jq -r '.client_name')
expiry_date_remote=$(echo "$license_data" | jq -r '.expired_date')
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

# 4. Update api.js
echo "Updating api.js..."
cat <<'EOF' > /etc/zivpn/api/api.js
const express = require('express');
const { execFile, exec } = require('child_process');
const fs = require('fs');
const app = express();
const PORT = 5888;
const AUTH_KEY_PATH = '/etc/zivpn/api_auth.key';
const ZIVPN_MANAGER_SCRIPT = '/usr/local/bin/zivpn-manager';
const LICENSE_INFO_FILE = '/etc/zivpn/.license_info';
const EXPIRED_LOCK_FILE = '/etc/zivpn/.expired';

app.use(express.json());

const authenticate = (req, res, next) => {
    if (req.path === '/callback/licence') {
        return next();
    }

    const providedAuthKey = req.query.auth;

    if (!providedAuthKey) return res.status(401).json({ status: 'error', message: 'Authentication key is required.' });

    fs.readFile(AUTH_KEY_PATH, 'utf8', (err, storedKey) => {
        if (err) return res.status(500).json({ status: 'error', message: 'Could not read authentication key.' });
        if (providedAuthKey.trim() !== storedKey.trim()) return res.status(403).json({ status: 'error', message: 'Invalid authentication key.' });
        next();
    });
};
app.use(authenticate);

// Rate Limiting Logic
const requestLimits = {};
const RATE_LIMIT_DURATION = 20000; // 20 seconds

const checkRateLimit = (username) => {
    if (requestLimits[username]) {
        return false;
    }
    requestLimits[username] = true;
    setTimeout(() => {
        delete requestLimits[username];
    }, RATE_LIMIT_DURATION);
    return true;
};

const executeZivpnManager = (command, args, res) => {
    execFile('sudo', [ZIVPN_MANAGER_SCRIPT, command, ...args], (error, stdout, stderr) => {
        if (error) {
            const errorMessage = (stderr && typeof stderr === 'string' && stderr.includes('Error:')) ? stderr : 'An internal server error occurred.';
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

    if (!checkRateLimit(password)) {
        return res.status(429).json({ status: 'error', message: 'Rate limit exceeded. Please wait 20 seconds before creating/renewing this account again.' });
    }

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

    if (!checkRateLimit(password)) {
        return res.status(429).json({ status: 'error', message: 'Rate limit exceeded. Please wait 20 seconds before creating/renewing this account again.' });
    }

    executeZivpnManager('renew_account', [password, exp], res);
});
app.all('/trial/zivpn', (req, res) => {
    const { exp } = req.query;
    if (!exp) return res.status(400).json({ status: 'error', message: 'Parameter exp is required.' });
    executeZivpnManager('trial_account', [exp], res);
});

app.post('/callback/licence', (req, res) => {
    const { action, client_name, expired_date, status } = req.body;

    if (!action || !client_name || !expired_date || !status) {
        return res.status(400).json({ status: 'error', message: 'Invalid payload.' });
    }

    const expiryTimestamp = new Date(expired_date).getTime() / 1000;
    const currentTimestamp = Math.floor(Date.now() / 1000);
    const isExpired = expiryTimestamp <= currentTimestamp;

    if (action === 'delete' || status === 'banned' || isExpired) {
        exec('systemctl stop zivpn.service && touch ' + EXPIRED_LOCK_FILE, (error, stdout, stderr) => {
            if (error) return res.status(500).json({ status: 'error', message: 'Failed to stop service.' });
            res.json({ status: 'success', message: 'License revoked and service stopped.' });
        });
    } else if (action === 'update' && status === 'active' && !isExpired) {
        const licenseInfoContent = `CLIENT_NAME='${client_name.replace(/'/g, "'\\''")}'\nEXPIRY_DATE='${expired_date.replace(/'/g, "'\\''")}'\n`;
        fs.writeFile(LICENSE_INFO_FILE, licenseInfoContent, (err) => {
            if (err) return res.status(500).json({ status: 'error', message: 'Failed to update license info.' });

            exec('rm -f ' + EXPIRED_LOCK_FILE + ' && systemctl start zivpn.service', (error, stdout, stderr) => {
                if (error) return res.status(500).json({ status: 'error', message: 'Failed to start service.' });
                res.json({ status: 'success', message: 'License updated and service started.' });
            });
        });
    } else {
        res.status(400).json({ status: 'error', message: 'Action not handled based on conditions.' });
    }
});

app.listen(PORT, () => console.log('ZIVPN API server running on port ' + PORT));
EOF

# 5. Apply persistence fixes for sysctl and iptables
echo "Applying persistence fixes for sysctl and iptables..."
cat <<EOF > /etc/sysctl.d/zivpn.conf
net.core.rmem_max=16777216
net.core.wmem_max=16777216
EOF
sysctl -p /etc/sysctl.d/zivpn.conf > /dev/null 2>&1

CORE_IFACE=$(ip -4 route ls | grep default | grep -Po '(?<=dev )(\S+)' | head -1)
if [ -n "$CORE_IFACE" ] && [ -f /etc/systemd/system/zivpn.service ]; then
    # Remove existing ExecStartPre/Post related to iptables just in case to prevent duplicates
    sed -i '/ExecStartPre=-\/sbin\/iptables/d' /etc/systemd/system/zivpn.service
    sed -i '/ExecStartPost=\/sbin\/iptables/d' /etc/systemd/system/zivpn.service
    sed -i '/ExecStopPost=-\/sbin\/iptables/d' /etc/systemd/system/zivpn.service

    # Insert the new rules around ExecStart
    sed -i "/ExecStart=\/usr\/local\/bin\/zivpn/i ExecStartPre=-/sbin/iptables -t nat -D PREROUTING -i ${CORE_IFACE} -p udp --dport 6000:19999 -j DNAT --to-destination :5667" /etc/systemd/system/zivpn.service
    sed -i "/ExecStart=\/usr\/local\/bin\/zivpn/a ExecStartPost=/sbin/iptables -t nat -A PREROUTING -i ${CORE_IFACE} -p udp --dport 6000:19999 -j DNAT --to-destination :5667\nExecStopPost=-/sbin/iptables -t nat -D PREROUTING -i ${CORE_IFACE} -p udp --dport 6000:19999 -j DNAT --to-destination :5667" /etc/systemd/system/zivpn.service

    # Ensure current iptables are clean and set (if service is already running)
    iptables -t nat -D PREROUTING -i "${CORE_IFACE}" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 > /dev/null 2>&1 || true
    iptables -t nat -A PREROUTING -i "${CORE_IFACE}" -p udp --dport 6000:19999 -j DNAT --to-destination :5667 > /dev/null 2>&1 || true
fi

# Restart services
echo "Restarting services..."
systemctl daemon-reload
systemctl restart zivpn-api.service
if systemctl is-active --quiet zivpn.service; then
    systemctl restart zivpn.service
fi

echo "--- Update Complete ---"
echo "License verification has been migrated to Vercel API, and persistence fixes applied."
