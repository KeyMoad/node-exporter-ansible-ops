#!/usr/bin/env bash
set -euo pipefail

# =========================
# Node Exporter installer/updater (Bash)
# =========================

# ---------- Defaults (override via CLI args or env) ----------
ACTION="${ACTION:-install}"              # install | update
DRY_RUN="${DRY_RUN:-false}"              # true | false
NODE_EXPORTER_VERSION="${NODE_EXPORTER_VERSION:-}"   # e.g., 1.9.1
NODE_EXPORTER_FLAGS="${NODE_EXPORTER_FLAGS:---collector.systemd --collector.textfile.directory=/var/log/value_monitor}"

INSTALL_DIR="${INSTALL_DIR:-/opt/node_exporter}"
BINARY_DIR="${BINARY_DIR:-/usr/local/bin}"
BINARY_PATH="${BINARY_PATH:-$BINARY_DIR/node_exporter}"
SERVICE_NAME="${SERVICE_NAME:-node_exporter}"

NODE_USER="${NODE_USER:-node_exporter}"
NODE_GROUP="${NODE_GROUP:-node_exporter}"

BACKUP_DIR="${BACKUP_DIR:-$INSTALL_DIR/backups}"
TS="$(date +%s)"
BACKUP_BINARY_PATH="$BACKUP_DIR/node_exporter-$TS"
BACKUP_UNIT_PATH="$BACKUP_DIR/${SERVICE_NAME}.service-$TS"

TMP_BASE="${TMP_BASE:-/tmp}"
WORK_DIR="$TMP_BASE"

# Will be set during runtime for cleanup
TGZ_FILE=""
EXTRACTED_DIR=""

# ---------- CLI parsing ----------
usage() {
  cat <<EOF
Usage: $0 [--action install|update] [--version X.Y.Z] [--dry-run true|false] [--flags "..."]
          [--install-dir DIR] [--binary-dir DIR] [--user USER] [--group GROUP]
          [--service-name NAME] [--backup-dir DIR]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --action) ACTION="$2"; shift 2 ;;
    --version) NODE_EXPORTER_VERSION="$2"; shift 2 ;;
    --dry-run) DRY_RUN="$2"; shift 2 ;;
    --flags) NODE_EXPORTER_FLAGS="$2"; shift 2 ;;
    --install-dir) INSTALL_DIR="$2"; shift 2 ;;
    --binary-dir) BINARY_DIR="$2"; BINARY_PATH="$2/node_exporter"; shift 2 ;;
    --user) NODE_USER="$2"; shift 2 ;;
    --group) NODE_GROUP="$2"; shift 2 ;;
    --service-name) SERVICE_NAME="$2"; shift 2 ;;
    --backup-dir) BACKUP_DIR="$2"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

# ---------- Helpers ----------
log() { printf '%s %s\n' "$(date -Is)" "$*" >&2; }     # <-- send logs to STDERR
die() { echo "ERROR: $*" >&2; exit 1; }

require_root() {
  if [[ $(id -u) -ne 0 ]]; then
    die "Please run as root (sudo $0 ...)"
  fi
}

run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] $*" >&2
  else
    eval "$@"
  fi
}

detect_arch() {
  local m; m="$(uname -m)"
  case "$m" in
    x86_64) echo "amd64" ;;
    aarch64) echo "arm64" ;;
    armv7l) echo "armv7" ;;
    ppc64le) echo "ppc64le" ;;
    *) echo "amd64" ;;
  esac
}

version_of_installed() {
  if [[ -x "$BINARY_PATH" ]]; then
    "$BINARY_PATH" --version 2>/dev/null | head -n1 | sed -nE 's/.*version[[:space:]]+([0-9.]+).*/\1/p'
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_tools() {
  local need=()
  have_cmd curl || need+=(curl)
  have_cmd tar  || need+=(tar)
  if ((${#need[@]})); then
    log "Installing missing tools: ${need[*]}"
    if have_cmd apt-get; then
      run "apt-get update"
      run "apt-get install -y ${need[*]}"
    elif have_cmd dnf; then
      run "dnf install -y ${need[*]}"
    elif have_cmd yum; then
      run "yum install -y ${need[*]}"
    else
      die "Package manager not found to install: ${need[*]}"
    fi
  fi
}

ensure_group_user() {
  if ! getent group "$NODE_GROUP" >/dev/null; then
    run "groupadd --system $NODE_GROUP"
  fi
  if ! id -u "$NODE_USER" >/dev/null 2>&1; then
    # Find a nologin shell path
    local nologin="/usr/sbin/nologin"
    [[ -x /sbin/nologin ]] && nologin="/sbin/nologin"
    run "useradd --system --no-create-home --gid $NODE_GROUP --shell $nologin $NODE_USER"
  fi
}

ensure_dirs() {
  run "mkdir -p '$INSTALL_DIR' '$BACKUP_DIR'"
  run "chown -R $NODE_USER:$NODE_GROUP '$INSTALL_DIR'"
}

download_and_extract() {
  local ver="$1" arch="$2"
  local base="https://github.com/prometheus/node_exporter/releases/download/v${ver}"
  local filename="node_exporter-${ver}.linux-${arch}"
  local tgz="${filename}.tar.gz"
  local url="${base}/${tgz}"

  TGZ_FILE="$WORK_DIR/$tgz"
  log "Downloading $url"
  run "curl -fsSL -o '$TGZ_FILE' '$url'"

  log "Extracting $tgz"
  EXTRACTED_DIR="$WORK_DIR/$filename"
  run "tar -xzf '$TGZ_FILE' -C '$WORK_DIR'"

  # Return the extracted dir path on STDOUT (no logs here)
  echo "$EXTRACTED_DIR"
}

deploy_binary() {
  local src_dir="$1"
  local src_bin="$src_dir/node_exporter"
  [[ -f "$src_bin" ]] || die "Extracted binary not found at $src_bin"
  run "install -o $NODE_USER -g $NODE_GROUP -m 0755 '$src_bin' '$BINARY_PATH'"
}

backup_existing() {
  if [[ -x "$BINARY_PATH" ]]; then
    log "Backing up existing binary to $BACKUP_BINARY_PATH"
    run "cp -a '$BINARY_PATH' '$BACKUP_BINARY_PATH'"
  fi
  if [[ -f "/etc/systemd/system/${SERVICE_NAME}.service" ]]; then
    log "Backing up existing unit to $BACKUP_UNIT_PATH"
    run "cp -a '/etc/systemd/system/${SERVICE_NAME}.service' '$BACKUP_UNIT_PATH'"
  fi
}

restore_backup_on_error() {
  log "Attempting rollback…"
  if [[ -f "$BACKUP_BINARY_PATH" ]]; then
    run "install -m 0755 -o $NODE_USER -g $NODE_GROUP '$BACKUP_BINARY_PATH' '$BINARY_PATH'"
  fi
  if [[ -f "$BACKUP_UNIT_PATH" ]]; then
    run "install -m 0644 '$BACKUP_UNIT_PATH' '/etc/systemd/system/${SERVICE_NAME}.service'"
    run "systemctl daemon-reload"
  fi
  run "systemctl enable --now ${SERVICE_NAME}" || true
  die "Update failed; rollback attempted. Backups are under $BACKUP_DIR (timestamp $TS)."
}

deploy_unit() {
  local unit="/etc/systemd/system/${SERVICE_NAME}.service"
  cat >"$WORK_DIR/${SERVICE_NAME}.service" <<EOF
[Unit]
Description=Node Exporter
Wants=network-online.target
After=network-online.target

[Service]
User=${NODE_USER}
Group=${NODE_GROUP}
Type=simple
ExecStart=${BINARY_PATH} ${NODE_EXPORTER_FLAGS}
Restart=on-failure
RestartSec=2s
NoNewPrivileges=yes

[Install]
WantedBy=multi-user.target
EOF
  run "install -m 0644 '$WORK_DIR/${SERVICE_NAME}.service' '$unit'"
  run "systemctl daemon-reload"
}

start_enable_service() {
  run "systemctl enable --now ${SERVICE_NAME}"
}

stop_service_if_running() {
  if systemctl is-active --quiet "${SERVICE_NAME}"; then
    run "systemctl stop ${SERVICE_NAME}"
  fi
}

cleanup_tmp() {
  if [[ -n "$EXTRACTED_DIR" && -d "$EXTRACTED_DIR" ]]; then
    run "rm -rf '$EXTRACTED_DIR'"
  fi
  if [[ -n "$TGZ_FILE" && -f "$TGZ_FILE" ]]; then
    run "rm -f '$TGZ_FILE'"
  fi
}

preflight_summary() {
  echo "---------------- Preflight ----------------"
  echo "Action:             $ACTION"
  echo "Dry run:            $DRY_RUN"
  echo "Target version:     ${NODE_EXPORTER_VERSION:-<unset>}"
  echo "Installed version:  ${INSTALLED_VERSION:-none}"
  echo "Binary present:     $([[ -x "$BINARY_PATH" ]] && echo true || echo false)"
  echo "Install dir:        $INSTALL_DIR"
  echo "Binary path:        $BINARY_PATH"
  echo "Service name:       $SERVICE_NAME"
  echo "User:Group:         $NODE_USER:$NODE_GROUP"
  echo "Backup dir:         $BACKUP_DIR"
  echo "-------------------------------------------"
}

# ---------- Main ----------
trap 'cleanup_tmp' EXIT
require_root

[[ "$ACTION" == "install" || "$ACTION" == "update" ]] || die "Invalid --action: $ACTION (use install|update)"
[[ -n "${NODE_EXPORTER_VERSION:-}" ]] || die "--version / NODE_EXPORTER_VERSION is required"

ARCH="$(detect_arch)"
INSTALLED_VERSION="$(version_of_installed || true)"

NEED_INSTALL=false
NEED_UPDATE=false
if [[ ! -x "$BINARY_PATH" ]]; then
  NEED_INSTALL=true
elif [[ "${INSTALLED_VERSION:-}" != "$NODE_EXPORTER_VERSION" ]]; then
  NEED_INSTALL=true
  NEED_UPDATE=true
fi

preflight_summary

# DRY-RUN report and exit
if [[ "$DRY_RUN" == "true" ]]; then
  echo "[DRY-RUN] $( [[ "$ACTION" == "install" && "$NEED_INSTALL" == "true" ]] && echo "Would install" || echo "Install skipped")"
  echo "[DRY-RUN] $( [[ "$ACTION" == "update" && "$NEED_INSTALL" == "true" ]] && echo "Would update to $NODE_EXPORTER_VERSION" || echo "Update skipped")"
  echo "[DRY-RUN] $( [[ "$ACTION" == "update" && "$NEED_UPDATE" == "true" ]] && echo "Would stop service before update" || echo "No service stop required")"
  echo "[DRY-RUN] Would create backups under $BACKUP_DIR if updating"
  echo "[DRY-RUN] Would ensure user/group $NODE_USER:$NODE_GROUP"
  echo "[DRY-RUN] Would (re)deploy unit and enable+start ${SERVICE_NAME}"
  exit 0
fi

ensure_tools
ensure_group_user
ensure_dirs

if [[ "$ACTION" == "update" && "$NEED_UPDATE" == "true" ]]; then
  stop_service_if_running
  backup_existing
fi

if [[ "$ACTION" == "install" && "$NEED_INSTALL" != "true" ]]; then
  log "Install requested but binary already present with same version ($INSTALLED_VERSION). Nothing to do."
else
  EXTRACTED_DIR="$(download_and_extract "$NODE_EXPORTER_VERSION" "$ARCH")" || restore_backup_on_error
  deploy_binary "$EXTRACTED_DIR" || restore_backup_on_error
fi

deploy_unit || restore_backup_on_error
start_enable_service || restore_backup_on_error

log "Done. node_exporter version target: $NODE_EXPORTER_VERSION (installed: $(version_of_installed || echo '?'))"