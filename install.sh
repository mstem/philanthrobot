#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/usr/local/etc/mac-studio-monitor"
LOG_DIR="/usr/local/var/log"
PLIST_DEST="/Library/LaunchDaemons/com.evens.macstudio-presence.plist"
LABEL="com.evens.macstudio-presence"
MONITOR_USER="_presencemonitor"
MONITOR_GROUP="daemon"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Dedicated unprivileged user so the daemon does not run as root
if ! dscl . -read "/Users/$MONITOR_USER" >/dev/null 2>&1; then
    uid=401
    while dscl . -list /Users UniqueID | awk '{print $2}' | grep -qx "$uid"; do
        uid=$((uid + 1))
    done
    sudo dscl . -create "/Users/$MONITOR_USER"
    sudo dscl . -create "/Users/$MONITOR_USER" UserShell /usr/bin/false
    sudo dscl . -create "/Users/$MONITOR_USER" UniqueID "$uid"
    sudo dscl . -create "/Users/$MONITOR_USER" PrimaryGroupID 1
    sudo dscl . -create "/Users/$MONITOR_USER" NFSHomeDirectory /var/empty
    sudo dscl . -create "/Users/$MONITOR_USER" RealName "Mac Studio presence monitor"
    sudo dscl . -create "/Users/$MONITOR_USER" IsHidden 1
    echo "Created daemon user $MONITOR_USER (uid $uid)"
fi

sudo install -d -m 755 "$INSTALL_DIR" "$LOG_DIR"
sudo install -d -m 700 -o "$MONITOR_USER" -g "$MONITOR_GROUP" "$CONFIG_DIR"
sudo install -m 755 "$SCRIPT_DIR/mac-studio-presence-monitor.py" "$INSTALL_DIR/mac-studio-presence-monitor.py"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    # The real config (with the Slack webhook) lives outside the repo
    SRC_CONFIG="$SCRIPT_DIR/config.example.json"
    [ -f "$HOME/.config/mac-studio-monitor/config.json" ] && SRC_CONFIG="$HOME/.config/mac-studio-monitor/config.json"
    sudo install -m 600 -o "$MONITOR_USER" -g "$MONITOR_GROUP" "$SRC_CONFIG" "$CONFIG_DIR/config.json"
    echo "Wrote config to $CONFIG_DIR/config.json (from $SRC_CONFIG)"
fi

# Fix ownership/permissions on upgrade from a root-owned install
sudo chown -R "$MONITOR_USER:$MONITOR_GROUP" "$CONFIG_DIR"
sudo chmod 700 "$CONFIG_DIR"
sudo chmod 600 "$CONFIG_DIR/config.json"

# Pre-create log files the unprivileged daemon can append to
for f in "$LOG_DIR/mac-studio-presence-monitor.log" "$LOG_DIR/mac-studio-presence.jsonl"; do
    sudo touch "$f"
    sudo chown "$MONITOR_USER:$MONITOR_GROUP" "$f"
    sudo chmod 600 "$f"
done

sudo install -m 644 "$SCRIPT_DIR/com.evens.macstudio-presence.plist" "$PLIST_DEST"

sudo launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST_DEST"
sudo launchctl kickstart -k "system/$LABEL"

echo "Installed and started $LABEL (running as $MONITOR_USER)"
echo "Logs: $LOG_DIR/mac-studio-presence-monitor.log"
