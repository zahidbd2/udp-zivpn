#!/bin/bash
# - ZiVPN Remover -
clear
echo -e "Uninstalling ZiVPN, Management Scripts, and REST API..."

# Stop and disable services
echo "Stopping and disabling services..."
systemctl stop zivpn.service 1> /dev/null 2> /dev/null
systemctl disable zivpn.service 1> /dev/null 2> /dev/null
systemctl stop zivpn-api.service 1> /dev/null 2> /dev/null
systemctl disable zivpn-api.service 1> /dev/null 2> /dev/null

# Remove service files
echo "Removing systemd service files..."
rm -f /etc/systemd/system/zivpn.service 1> /dev/null 2> /dev/null
rm -f /etc/systemd/system/zivpn-api.service 1> /dev/null 2> /dev/null
systemctl daemon-reload

# Kill any running process just in case
killall zivpn 1> /dev/null 2> /dev/null

# Remove firewall rule if it exists
iptables -D INPUT -p tcp --dport 5888 -j ACCEPT 1> /dev/null 2> /dev/null

# Remove directories, binaries, and license files
echo "Removing application files..."
rm -rf /etc/zivpn 1> /dev/null 2> /dev/null # This removes /etc/zivpn/api and api_auth.key as well
rm -f /usr/local/bin/zivpn 1> /dev/null 2> /dev/null
rm -f /usr/local/bin/zivpn-manager 1> /dev/null 2> /dev/null
rm -f /usr/local/bin/zivpn_helper.sh 1> /dev/null 2> /dev/null

# Remove specific cron jobs
echo "Removing cron jobs..."
(crontab -l 2>/dev/null | grep -v "zivpn") | crontab -


# Remove system integration from shell profiles
echo "Removing shell integrations..."
PROFILE_FILES=("/root/.bashrc" "/root/.bash_profile")
for PROFILE_FILE in "${PROFILE_FILES[@]}"; do
    if [ -f "$PROFILE_FILE" ]; then
        sed -i "/alias menu='\/usr\/local\/bin\/zivpn-manager'/d" "$PROFILE_FILE"
        sed -i "/\/usr\/local\/bin\/zivpn-manager/d" "$PROFILE_FILE"
    fi
done

echo "Verifying removal..."
if pgrep "zivpn" >/dev/null; then
  echo -e "Server process is still running."
else
  echo -e "Server process stopped."
fi

if [ -f "/usr/local/bin/zivpn" ] || [ -f "/usr/local/bin/zivpn-manager" ] || [ -d "/etc/zivpn" ]; then
  echo -e "Files still remaining, please check manually."
else
  echo -e "Successfully Removed All Application Files."
fi

# Optional: Uninstall Node.js
echo ""
read -p "Do you want to uninstall Node.js and npm? (This may affect other applications) [y/N]: " uninstall_nodejs
if [[ "$uninstall_nodejs" == [yY] || "$uninstall_nodejs" == [yY][eE][sS] ]]; then
    echo "Uninstalling Node.js and npm..."
    apt-get purge -y nodejs npm
    apt-get autoremove -y
    rm -f /etc/apt/sources.list.d/nodesource.list
    echo "Node.js has been uninstalled."
else
    echo "Skipping Node.js uninstallation."
fi


echo "Cleaning Cache & Swap"
echo 3 > /proc/sys/vm/drop_caches
sysctl -w vm.drop_caches=3
swapoff -a && swapon -a
echo -e "Done."
