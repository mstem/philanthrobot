#!/bin/bash
set -euo pipefail

INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/usr/local/etc/philanthrobot"
LOG_DIR="/usr/local/var/log"
PLIST_DEST="/Library/LaunchDaemons/com.evens.philanthrobot.plist"
LABEL="com.evens.philanthrobot"
MONITOR_USER="_presencemonitor"
MONITOR_GROUP="daemon"

# Pre-rename install, superseded by the names above (see migrate_from_old_names)
OLD_CONFIG_DIR="/usr/local/etc/mac-studio-monitor"
OLD_PLIST_DEST="/Library/LaunchDaemons/com.evens.macstudio-presence.plist"
OLD_LABEL="com.evens.macstudio-presence"
OLD_BIN="$INSTALL_DIR/mac-studio-presence-monitor.py"
OLD_LOG="$LOG_DIR/mac-studio-presence-monitor.log"
OLD_AUDIT="$LOG_DIR/mac-studio-presence.jsonl"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Stop the old job before moving its state, so the two never run at once and
# race on state.json. Data is carried over first; the old files go last.
migrate_from_old_names() {
    [ -e "$OLD_PLIST_DEST" ] || [ -d "$OLD_CONFIG_DIR" ] || return 0
    echo "Migrating from $OLD_LABEL"

    if [ -e "$OLD_PLIST_DEST" ]; then
        sudo launchctl bootout system "$OLD_PLIST_DEST" 2>/dev/null || true
    fi

    sudo install -d -m 700 -o "$MONITOR_USER" -g "$MONITOR_GROUP" "$CONFIG_DIR"
    for f in config.json state.json; do
        if [ -f "$OLD_CONFIG_DIR/$f" ] && [ ! -f "$CONFIG_DIR/$f" ]; then
            sudo cp -p "$OLD_CONFIG_DIR/$f" "$CONFIG_DIR/$f"
            echo "  carried over $f"
        fi
    done
    if [ -f "$OLD_AUDIT" ] && [ ! -f "$LOG_DIR/philanthrobot.jsonl" ]; then
        sudo mv "$OLD_AUDIT" "$LOG_DIR/philanthrobot.jsonl"
        echo "  moved audit log"
    fi

    sudo rm -f "$OLD_PLIST_DEST" "$OLD_BIN" "$OLD_LOG"
    sudo rm -rf "$OLD_CONFIG_DIR"
    echo "  removed old plist, binary and config dir"
}

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
    sudo dscl . -create "/Users/$MONITOR_USER" RealName "philanthrobot presence monitor"
    sudo dscl . -create "/Users/$MONITOR_USER" IsHidden 1
    echo "Created daemon user $MONITOR_USER (uid $uid)"
fi

sudo install -d -m 755 "$INSTALL_DIR" "$LOG_DIR"
sudo install -d -m 700 -o "$MONITOR_USER" -g "$MONITOR_GROUP" "$CONFIG_DIR"

migrate_from_old_names

sudo install -m 755 "$SCRIPT_DIR/philanthrobot-monitor.py" "$INSTALL_DIR/philanthrobot-monitor.py"

if [ ! -f "$CONFIG_DIR/config.json" ]; then
    # The real config (with the Slack webhook) lives outside the repo
    SRC_CONFIG="$SCRIPT_DIR/config.example.json"
    [ -f "$HOME/.config/philanthrobot/config.json" ] && SRC_CONFIG="$HOME/.config/philanthrobot/config.json"
    sudo install -m 600 -o "$MONITOR_USER" -g "$MONITOR_GROUP" "$SRC_CONFIG" "$CONFIG_DIR/config.json"
    echo "Wrote config to $CONFIG_DIR/config.json (from $SRC_CONFIG)"
fi

# Fix ownership/permissions on upgrade from a root-owned install
sudo chown -R "$MONITOR_USER:$MONITOR_GROUP" "$CONFIG_DIR"
sudo chmod 700 "$CONFIG_DIR"
sudo chmod 600 "$CONFIG_DIR/config.json"
[ -f "$CONFIG_DIR/state.json" ] && sudo chmod 600 "$CONFIG_DIR/state.json" || true

# Pre-create log files the unprivileged daemon can append to
for f in "$LOG_DIR/philanthrobot-monitor.log" "$LOG_DIR/philanthrobot.jsonl"; do
    sudo touch "$f"
    sudo chown "$MONITOR_USER:$MONITOR_GROUP" "$f"
    sudo chmod 600 "$f"
done

sudo install -m 644 "$SCRIPT_DIR/com.evens.philanthrobot.plist" "$PLIST_DEST"

sudo launchctl bootout system "$PLIST_DEST" 2>/dev/null || true
sudo launchctl bootstrap system "$PLIST_DEST"
sudo launchctl kickstart -k "system/$LABEL"

echo "Installed and started $LABEL (running as $MONITOR_USER)"
echo "Logs: $LOG_DIR/philanthrobot-monitor.log"
