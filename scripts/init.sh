#!/bin/bash
# init.sh - bootstrap Ubuntu host with baseline configs, Docker, and base commands
set -euo pipefail

DEBUG_FLAG="${DEBUG_FLAG:-0}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_DIR="/opt/ubuntu-autoconfig"
MANAGED_USER="kynetra"
USER_CREATED=false
LIB_DEST="/usr/local/lib/ubuntu-base"
CMD_DEST="/usr/local/bin"
ORIG_USER="${SUDO_USER:-ubuntu}"
ORIG_HOME="/home/$ORIG_USER"
INSTALL_PBS="${INSTALL_PBS:-}"   # empty=ask interactively, "yes"=install, "no"=skip
NEW_HOSTNAME="${NEW_HOSTNAME:-}"  # empty=ask interactively, set=apply directly

# Logging helpers
if [ -f "$REPO_ROOT/lib/logging.sh" ]; then
  # shellcheck disable=SC1091
  source "$REPO_ROOT/lib/logging.sh"
else
  log()      { echo -e "[INFO] $*"; }
  warn()     { echo -e "[WARN] $*"; }
  fail()     { echo -e "[ERROR] $*" >&2; exit 1; }
  complete() { echo -e "[COMPLETE] $*"; }
fi

while [[ ${1:-} ]]; do
  case "$1" in
    --debug)    DEBUG_FLAG=1 ;;
    --with-pbs)  INSTALL_PBS="yes" ;;
    --no-pbs)    INSTALL_PBS="no" ;;
    --hostname)  shift; NEW_HOSTNAME="${1:-}"; [ -z "$NEW_HOSTNAME" ] && fail "--hostname requires a value" ;;
    *)           fail "Unknown option: $1" ;;
  esac
  shift
done

if [ "$DEBUG_FLAG" = "1" ]; then
  set -x
  log "Debug mode enabled."
fi

as_root() {
  if [ "$EUID" -eq 0 ]; then
    "$@"
  else
    sudo -E "$@"
  fi
}

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
trap 'fail "init.sh failed at line $LINENO"' ERR

log "Running from $REPO_ROOT (recommended: $INSTALL_DIR)"
log "Running as user: $(whoami) (EUID=$EUID)${RUN_AS_MANAGED:+; RUN_AS_MANAGED set}"

set_hostname() {
  if [ -z "$NEW_HOSTNAME" ]; then
    local current
    current="$(hostname)"
    read -rp "Enter hostname for this server [keep current: $current]: " NEW_HOSTNAME
    if [ -z "$NEW_HOSTNAME" ]; then
      log "No hostname entered; keeping current hostname ($current)."
      return
    fi
  fi

  if [[ ! "$NEW_HOSTNAME" =~ ^[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9-]*[a-zA-Z0-9])?)*$ ]]; then
    fail "Invalid hostname '$NEW_HOSTNAME'. Use only letters, digits, hyphens, and dots (RFC 1123)."
  fi

  log "Setting hostname to $NEW_HOSTNAME."
  as_root hostnamectl set-hostname "$NEW_HOSTNAME"

  if as_root grep -q "^127\.0\.1\.1" /etc/hosts; then
    as_root sed -i "s|^127\.0\.1\.1.*|127.0.1.1 $NEW_HOSTNAME|" /etc/hosts
  else
    echo "127.0.1.1 $NEW_HOSTNAME" | as_root tee -a /etc/hosts >/dev/null
  fi

  log "Hostname set to $NEW_HOSTNAME (hostnamectl + /etc/hosts updated)."
}

ensure_user() {
  if id "$MANAGED_USER" >/dev/null 2>&1; then
    log "User $MANAGED_USER already exists."
  else
    log "Creating user $MANAGED_USER (disabled password)."
    as_root adduser --disabled-password --gecos "Server Administrator" "$MANAGED_USER"
    USER_CREATED=true
  fi
}

copy_netrc_if_present() {
  local src="$ORIG_HOME/.netrc"
  local dst="/home/$MANAGED_USER/.netrc"

  # Skip if source and destination are the same
  if [ "$src" = "$dst" ]; then
    log ".netrc already in place for $MANAGED_USER; skipping copy."
    return
  fi

  if [ -f "$src" ]; then
    as_root cp "$src" "$dst"
    as_root chown "$MANAGED_USER:$MANAGED_USER" "$dst"
    as_root chmod 600 "$dst"
    log "Copied .netrc from $ORIG_USER to $MANAGED_USER."
  else
    warn "No .netrc found for $ORIG_USER; skipping copy."
  fi
}

switch_to_managed_home() {
  export HOME="/home/$MANAGED_USER"
  if ! cd "$HOME"; then
    warn "Failed to change directory to $HOME"
  fi
}

set_user_password_if_new() {
  if ! $USER_CREATED; then
    return
  fi
  local pw1 pw2
  while true; do
    read -rsp "Enter password for $MANAGED_USER: " pw1; echo
    read -rsp "Confirm password for $MANAGED_USER: " pw2; echo
    if [ -z "$pw1" ]; then
      warn "Password cannot be empty."
      continue
    fi
    if [ "$pw1" != "$pw2" ]; then
      warn "Passwords do not match. Try again."
      continue
    fi
    echo "$MANAGED_USER:$pw1" | as_root chpasswd
    log "Password set for $MANAGED_USER."
    break
  done
}

apply_configs() {
  if [ -f "$REPO_ROOT/configs/sudoers" ]; then
    as_root cp "$REPO_ROOT/configs/sudoers" /etc/sudoers
    as_root chmod 0440 /etc/sudoers
    log "Applied sudoers."
  else
    warn "configs/sudoers not found; skipping."
  fi

  if [ -f "$REPO_ROOT/configs/sshd_config" ]; then
    as_root cp "$REPO_ROOT/configs/sshd_config" /etc/ssh/sshd_config
    as_root systemctl reload ssh || as_root systemctl reload sshd || true
    log "Applied sshd_config."
  else
    warn "configs/sshd_config not found; skipping."
  fi

  if [ -f "$REPO_ROOT/configs/authorized_keys" ]; then
    as_root mkdir -p "/home/$MANAGED_USER/.ssh"
    as_root cp "$REPO_ROOT/configs/authorized_keys" "/home/$MANAGED_USER/.ssh/authorized_keys"
    as_root chown -R "$MANAGED_USER:$MANAGED_USER" "/home/$MANAGED_USER/.ssh"
    as_root chmod 700 "/home/$MANAGED_USER/.ssh"
    as_root chmod 600 "/home/$MANAGED_USER/.ssh/authorized_keys"
    log "Applied authorized_keys for $MANAGED_USER."
  else
    warn "configs/authorized_keys not found; skipping."
  fi
}

install_baseline_packages() {
  log "Refreshing package lists."
  echo "iperf3 iperf3/server boolean false" | as_root debconf-set-selections
  as_root apt-get update -y
  log "Installing baseline packages: curl iperf3 traceroute tree dos2unix glances speedtest-cli systemd"
  as_root apt-get install -y curl iperf3 traceroute tree dos2unix glances speedtest-cli systemd
}

install_docker() {
  log "Installing Docker CE and Compose plugin."
  log "Refreshing Docker GPG key (handles key rotations)."
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | as_root gpg --dearmor --yes -o /usr/share/keyrings/docker-archive-keyring.gpg
  if [[ -f /etc/apt/sources.list.d/docker.list ]]; then
    log "Docker repo already configured at /etc/apt/sources.list.d/docker.list; skipping."
  else
    log "Adding Docker repo."
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
      | as_root tee /etc/apt/sources.list.d/docker.list >/dev/null
  fi
  as_root apt-get update -y
  log "Installing docker-ce, docker-ce-cli, containerd.io, docker-compose-plugin."
  as_root apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
  as_root usermod -aG docker "$MANAGED_USER" || warn "Failed to add $MANAGED_USER to docker group"
}

install_qemu_ga() {
  log "Installing QEMU guest agent."
  as_root apt-get install -y qemu-guest-agent
  as_root systemctl enable --now qemu-guest-agent || warn "Failed to enable qemu-guest-agent"
}

install_pbs_client() {
  if [ -z "$INSTALL_PBS" ]; then
    local answer
    read -rp "Install Proxmox Backup Server client? [y/N]: " answer
    case "${answer,,}" in
      y|yes) INSTALL_PBS="yes" ;;
      *)     INSTALL_PBS="no" ;;
    esac
  fi

  if [ "$INSTALL_PBS" != "yes" ]; then
    log "Skipping PBS client installation."
    return
  fi

  log "Installing Proxmox Backup Server client."

  log "Downloading Proxmox GPG key."
  curl -fsSL http://download.proxmox.com/debian/proxmox-release-bookworm.gpg \
    | as_root tee /usr/share/keyrings/proxmox-archive-keyring.gpg >/dev/null

  if [ -f /etc/apt/sources.list.d/pbs-client.list ]; then
    log "PBS client repo already configured; skipping."
  else
    log "Adding PBS client APT repo."
    echo "deb [signed-by=/usr/share/keyrings/proxmox-archive-keyring.gpg] http://download.proxmox.com/debian/pbs-client bookworm main" \
      | as_root tee /etc/apt/sources.list.d/pbs-client.list >/dev/null
  fi

  as_root apt-get update -y
  as_root apt-get install -y proxmox-backup-client

  if [ -f "$REPO_ROOT/configs/pbs-backup.env" ]; then
    as_root cp "$REPO_ROOT/configs/pbs-backup.env" /etc/pbs-backup.env
    as_root chmod 600 /etc/pbs-backup.env
    as_root chown root:root /etc/pbs-backup.env
    # Encrypt sensitive values in deployed env file
    if [ -f "$REPO_ROOT/lib/pbs-crypt.sh" ]; then
      # shellcheck source=/dev/null
      source "$REPO_ROOT/lib/pbs-crypt.sh"
      pbs_encrypt_env_file /etc/pbs-backup.env /etc/pbs-backup.env
      log "Encrypted PBS credentials in /etc/pbs-backup.env."
    fi
    log "Deployed /etc/pbs-backup.env (edit with real PBS server details before use)."
  else
    warn "configs/pbs-backup.env not found; skipping config deployment."
  fi

  # Generate encryption key if not already present
  # Source the repo copy (deployed copy is 600 root:root, unreadable by kynetra in Phase 2)
  # shellcheck source=/dev/null
  source "$REPO_ROOT/configs/pbs-backup.env"
  local keyfile="${PBS_KEYFILE:-/etc/pbs/encryption-key.json}"
  if [ -f "$keyfile" ]; then
    log "PBS encryption key already exists at $keyfile; skipping generation."
  else
    local keydir
    keydir="$(dirname "$keyfile")"
    as_root mkdir -p "$keydir"
    if [ -n "${PBS_ENCRYPTION_PASSWORD:-}" ] && [ "$PBS_ENCRYPTION_PASSWORD" != "CHANGE-ME-to-a-strong-passphrase" ]; then
      log "Generating PBS encryption key at $keyfile (password-protected, scrypt KDF)."
      PBS_ENCRYPTION_PASSWORD="$PBS_ENCRYPTION_PASSWORD" \
        as_root proxmox-backup-client key create "$keyfile" --kdf scrypt
    else
      warn "PBS_ENCRYPTION_PASSWORD not configured — generating key WITHOUT password (kdf=none)."
      warn "Data is still encrypted at rest (AES-256-GCM). To add key password, regenerate later."
      as_root proxmox-backup-client key create "$keyfile" --kdf none
    fi
    as_root chmod 600 "$keyfile"
    as_root chown root:root "$keyfile"
    log "PBS encryption key created at $keyfile."
    warn "CRITICAL: Back up this key file separately. Without it, encrypted backups cannot be restored."
  fi

  log "Installing PBS backup cron job (nightly at 2 AM)."
  as_root tee /etc/cron.d/pbs-backup >/dev/null <<'EOF_CRON'
# Proxmox Backup Server - nightly backup
0 2 * * * root /usr/local/bin/pbs-backup >> /var/log/pbs-backup.log 2>&1
EOF_CRON
  as_root chmod 644 /etc/cron.d/pbs-backup

  if [ -f "$REPO_ROOT/configs/pbs-backup-logrotate" ]; then
    as_root cp "$REPO_ROOT/configs/pbs-backup-logrotate" /etc/logrotate.d/pbs-backup
    as_root chmod 644 /etc/logrotate.d/pbs-backup
    log "Deployed logrotate config for pbs-backup."
  fi

  log "PBS client installed and configured."
}

install_base_commands() {
  as_root mkdir -p "$LIB_DEST" "$CMD_DEST"
  for lib in "$REPO_ROOT"/lib/*.sh; do
    [ -f "$lib" ] || continue
    lib_name=$(basename "$lib")
    as_root cp "$lib" "$LIB_DEST/$lib_name"
    as_root chmod 644 "$LIB_DEST/$lib_name"
  done

  for cmd in "$REPO_ROOT"/commands/*; do
    [ -f "$cmd" ] || continue
    cmd_name=$(basename "$cmd")
    if [ -f "$CMD_DEST/$cmd_name" ]; then
      as_root cp "$CMD_DEST/$cmd_name" "$CMD_DEST/$cmd_name.bak.$(date +%Y%m%d%H%M%S)"
    fi
    as_root cp "$cmd" "$CMD_DEST/$cmd_name"
    as_root chmod +x "$CMD_DEST/$cmd_name"
  done
  log "Installed base commands to $CMD_DEST and libs to $LIB_DEST."
}

run_system_update_with_reboot() {
  local updater
  if [ -x "$REPO_ROOT/commands/system-update-with-reboot" ]; then
    updater="$REPO_ROOT/commands/system-update-with-reboot"
  else
    updater="$CMD_DEST/system-update-with-reboot"
  fi
  if [ -x "$updater" ]; then
    log "Running system update with reboot (final step) via $updater."
    as_root bash "$updater"
  else
    warn "system-update-with-reboot not found or not executable; skipping."
  fi
}

main() {
  if [ -z "${RUN_AS_MANAGED:-}" ] && [ "$EUID" -eq 0 ]; then
    set_hostname
    ensure_user
    set_user_password_if_new
    copy_netrc_if_present
    switch_to_managed_home
    apply_configs
    log "Handing off to $MANAGED_USER for remaining steps."
    export RUN_AS_MANAGED=1
    exec sudo -u "$MANAGED_USER" -H \
      RUN_AS_MANAGED=1 \
      REPO_ROOT="$REPO_ROOT" \
      MANAGED_USER="$MANAGED_USER" \
      LIB_DEST="$LIB_DEST" \
      CMD_DEST="$CMD_DEST" \
      DEBUG_FLAG="$DEBUG_FLAG" \
      INSTALL_PBS="$INSTALL_PBS" \
      NEW_HOSTNAME="$NEW_HOSTNAME" \
      HOME="/home/$MANAGED_USER" \
      bash "$REPO_ROOT/scripts/init.sh" "$@"
  fi

  switch_to_managed_home
  ensure_user
  apply_configs
  install_baseline_packages
  install_docker
  install_qemu_ga
  install_pbs_client
  install_base_commands
  run_system_update_with_reboot
  complete "Baseline configuration applied."
}

main "$@"
