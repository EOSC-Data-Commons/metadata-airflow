#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="postgres-backup"
SYSTEMD_DIR="/etc/systemd/system"

SERVICE_FILE="$SYSTEMD_DIR/$SERVICE_NAME.service"
TIMER_FILE="$SYSTEMD_DIR/$SERVICE_NAME.timer"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this uninstaller with sudo." >&2
    exit 1
fi

echo "Uninstalling PostgreSQL backup service..."

# Disable and stop the timer.
if systemctl is-enabled --quiet "$SERVICE_NAME.timer" 2>/dev/null; then
    systemctl disable --now "$SERVICE_NAME.timer"
else
    systemctl stop "$SERVICE_NAME.timer" 2>/dev/null || true
fi

# Stop the service if running.
systemctl stop "$SERVICE_NAME.service" 2>/dev/null || true

# Remove systemd unit files.
rm -f "$SERVICE_FILE" "$TIMER_FILE"

# Reload systemd configuration.
systemctl daemon-reload
systemctl reset-failed "$SERVICE_NAME.service" "$SERVICE_NAME.timer" \
    2>/dev/null || true

echo
echo "PostgreSQL backup service uninstalled."
echo
echo "Preserved:"
echo "  /etc/postgres-backup.env"
echo "  Existing database backups"
echo "  scripts/backup-postgres.sh"

