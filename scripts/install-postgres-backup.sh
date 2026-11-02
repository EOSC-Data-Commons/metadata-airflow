#!/usr/bin/env bash
set -Eeuo pipefail

SERVICE_NAME="postgres-backup"
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$INSTALL_DIR")"
BACKUP_SCRIPT="$INSTALL_DIR/backup-postgres.sh"

ENV_FILE="/etc/postgres-backup.env"
SYSTEMD_DIR="/etc/systemd/system"

if [[ $EUID -ne 0 ]]; then
    echo "ERROR: Run this installer with sudo." >&2
    exit 1
fi

if [[ ! -f "$BACKUP_SCRIPT" ]]; then
    echo "ERROR: Backup script not found: $BACKUP_SCRIPT" >&2
    exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
    echo "ERROR: Missing configuration: $ENV_FILE" >&2
    exit 1
fi

# Load and validate configuration.
set -a
source "$ENV_FILE"
set +a

REQUIRED_VARS=(
    DATABASE_BACKUP_DIR
    DATABASE_BACKUP_USER
    AIRFLOW_DATABASE_USER
    AIRFLOW_DATABASE_NAME
    TOOLMETA_HARVESTER_DATABASE__USER
    TOOLMETA_HARVESTER_DATABASE__NAME
)

for var in "${REQUIRED_VARS[@]}"; do
    if [[ -z "${!var:-}" ]]; then
        echo "ERROR: $var is not defined or is empty." >&2
        exit 1
    fi
done

if [[ "$DATABASE_BACKUP_DIR" != /* || "$DATABASE_BACKUP_DIR" == "/" ]]; then
    echo "ERROR: DATABASE_BACKUP_DIR must be an absolute directory other than /." >&2
    exit 1
fi

if ! id "$DATABASE_BACKUP_USER" &>/dev/null; then
    echo "ERROR: User '$DATABASE_BACKUP_USER' does not exist." >&2
    exit 1
fi

if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: Docker is not installed." >&2
    exit 1
fi

if ! docker compose version >/dev/null 2>&1; then
    echo "ERROR: Docker Compose is unavailable." >&2
    exit 1
fi

echo "Installing PostgreSQL backup service..."
echo "Project: $PROJECT_DIR"
echo "Backups: $DATABASE_BACKUP_DIR"

chmod 750 "$BACKUP_SCRIPT"
chmod 600 "$ENV_FILE"

install -d -m 700 \
    -o "$DATABASE_BACKUP_USER" \
    -g "$(id -gn "$DATABASE_BACKUP_USER")" \
    "$DATABASE_BACKUP_DIR"

cat > "$SYSTEMD_DIR/$SERVICE_NAME.service" <<EOF
[Unit]
Description=PostgreSQL database backup
Wants=docker.service
After=docker.service
RequiresMountsFor=$PROJECT_DIR $DATABASE_BACKUP_DIR

[Service]
Type=oneshot
User=root
WorkingDirectory=$PROJECT_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$BACKUP_SCRIPT
TimeoutStartSec=infinity
EOF

cat > "$SYSTEMD_DIR/$SERVICE_NAME.timer" <<EOF
[Unit]
Description=Daily PostgreSQL backup timer

[Timer]
OnCalendar=*-*-* 03:00:00
Persistent=true
AccuracySec=1min
Unit=$SERVICE_NAME.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME.timer"

echo
echo "Installation completed."
echo
echo "Timer:"
systemctl list-timers "$SERVICE_NAME.timer" --no-pager

echo
echo "Run backup manually:"
echo "  sudo systemctl start $SERVICE_NAME.service"
echo
echo "View logs:"
echo "  journalctl -u $SERVICE_NAME.service -n 100"
