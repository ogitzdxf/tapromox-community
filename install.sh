#!/usr/bin/env bash
set -Eeuo pipefail

REPO_OWNER="ogitzdxf"
REPO_NAME="tapromox-community"
BRANCH="main"
APP_DIR="/opt/tapromox-community"
ENV_DIR="/etc/tapromox-community"
ENV_FILE="$ENV_DIR/community.env"
SERVICE_NAME="tapromox-community"
CREDENTIAL_FILE="/root/tapromox-community-credentials.txt"
PORT="${TAPROMOX_PORT:-5000}"

log() { printf '\n[Tapromox] %s\n' "$*"; }
fail() { printf '\n[Tapromox] ERROR: %s\n' "$*" >&2; exit 1; }
trap 'fail "Installation failed on line $LINENO."' ERR

[[ "${EUID}" -eq 0 ]] || fail "Run as root or through sudo."
command -v systemctl >/dev/null || fail "systemd is required."

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
else
  fail "Cannot detect the operating system."
fi
case "${ID:-}" in
  ubuntu|debian) ;;
  *) fail "This installer supports Ubuntu and Debian only." ;;
esac

export DEBIAN_FRONTEND=noninteractive
log "Waiting for the package manager..."
for _ in $(seq 1 60); do
  if ! fuser /var/lib/dpkg/lock-frontend /var/lib/apt/lists/lock /var/cache/apt/archives/lock >/dev/null 2>&1; then break; fi
  sleep 2
done

log "Installing system dependencies..."
apt-get update -y
apt-get install -y --no-install-recommends ca-certificates curl python3 python3-venv python3-pip python3-dev build-essential git

TMP_DIR="$(mktemp -d)"
cleanup() { rm -rf "$TMP_DIR"; }
trap cleanup EXIT
ARCHIVE_URL="https://raw.githubusercontent.com/${REPO_OWNER}/${REPO_NAME}/${BRANCH}/Tapromox-Community-Source.tar.gz"
log "Downloading the Community source bundle from GitHub..."
curl --fail --location --retry 4 --retry-delay 2 --silent --show-error "$ARCHIVE_URL" -o "$TMP_DIR/source.tar.gz"
tar -xzf "$TMP_DIR/source.tar.gz" -C "$TMP_DIR"
SOURCE_DIR="$(dirname "$(find "$TMP_DIR" -type f -name tapromox.py -print -quit)")"
[[ -n "$SOURCE_DIR" && -f "$SOURCE_DIR/tapromox.py" ]] || fail "The GitHub source bundle is missing tapromox.py."

if [[ -d "$APP_DIR" ]]; then
  BACKUP_DIR="${APP_DIR}.backup.$(date -u +%Y%m%d%H%M%S)"
  log "Preserving the existing installation at $BACKUP_DIR..."
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  mv "$APP_DIR" "$BACKUP_DIR"
fi
mkdir -p "$APP_DIR" "$ENV_DIR"
cp -a "$SOURCE_DIR/." "$APP_DIR/"
mkdir -p "$APP_DIR/static/uploads/profiles" "$APP_DIR/static/uploads/settings" "$APP_DIR/static/uploads/os_icons" "$APP_DIR/backups"

log "Creating the Python environment..."
python3 -m venv "$APP_DIR/.venv"
"$APP_DIR/.venv/bin/python" -m pip install --upgrade pip wheel
"$APP_DIR/.venv/bin/pip" install --requirement "$APP_DIR/requirements.txt"

if [[ ! -f "$ENV_FILE" ]]; then
  ADMIN_PASSWORD="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(18))
PY
)"
  SECRET_KEY="$(python3 - <<'PY'
import secrets
print(secrets.token_urlsafe(48))
PY
)"
  cat > "$ENV_FILE" <<EOF
PANEL_NAME=Tapromox
PANEL_VERSION=2.0-community
PANEL_DEVELOPER=ogitzdude | Pratyush
SECRET_KEY=$SECRET_KEY
DATABASE_PATH=$APP_DIR/tapromox.db
HOST=0.0.0.0
PORT=$PORT
MAIN_ADMIN_USERNAME=admin
MAIN_ADMIN_PASSWORD=$ADMIN_PASSWORD
MAIN_ADMIN_EMAIL=admin@localhost
DEBUG_MODE=False
EOF
  chmod 600 "$ENV_FILE"
  cat > "$CREDENTIAL_FILE" <<EOF
Tapromox Community Edition
===========================
Panel: http://SERVER_IP:$PORT
Username: admin
Password: $ADMIN_PASSWORD

Change this password immediately after the first login.
EOF
  chmod 600 "$CREDENTIAL_FILE"
else
  log "Keeping the existing environment file and credentials."
fi

cat > "/etc/systemd/system/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Tapromox Community management panel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$APP_DIR
EnvironmentFile=$ENV_FILE
ExecStart=$APP_DIR/.venv/bin/python $APP_DIR/tapromox.py
Restart=always
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "/etc/systemd/system/${SERVICE_NAME}.service"
chown -R root:root "$APP_DIR" "$ENV_DIR"
chmod 700 "$APP_DIR" "$ENV_DIR"

log "Enabling Tapromox Community service..."
systemctl daemon-reload
systemctl enable --now "$SERVICE_NAME"
sleep 2
systemctl --no-pager --full status "$SERVICE_NAME" || true

log "Installation complete."
printf '%s\n' "Credentials are stored in: $CREDENTIAL_FILE" "Panel port: $PORT" "Logs: sudo journalctl -u $SERVICE_NAME -f"
