#!/bin/bash
# remove.sh - undo autoconfig applied by init.sh
set -euo pipefail

if [ "$EUID" -ne 0 ]; then
  exec sudo -E bash "$0" "$@"
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MANAGED_USER="commsadmin"
PROXY_URL="http://iris:BEDSIDE-martine-paying@proxy.network.pilkington.net:3128"
NO_PROXY_LIST=".pilkington.net,localhost,127.0.0.1,::1,138.84.0.0/16,10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
APT_PROXY_FILE="/etc/apt/apt.conf.d/90curtin-aptproxy"
PROFILE_PROXY_FILE="/etc/profile.d/proxy.sh"
DOCKER_PROXY_DIR="/etc/systemd/system/docker.service.d"
DOCKER_PROXY_FILE="$DOCKER_PROXY_DIR/http-proxy.conf"
LIB_DEST="/usr/local/lib/ubuntu-base"
CMD_DEST="/usr/local/bin"
REMOVE_USER=false
REMOVE_QEMU=false
REMOVE_PBS=false

while [[ ${1:-} ]]; do
  case "$1" in
    --purge-user)
      REMOVE_USER=true
      ;;
    --remove-qemu)
      REMOVE_QEMU=true
      ;;
    --remove-pbs)
      REMOVE_PBS=true
      ;;
    *)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
  esac
  shift
done

log()      { echo -e "[INFO] $*"; }
warn()     { echo -e "[WARN] $*"; }
fail()     { echo -e "[ERROR] $*" >&2; exit 1; }
complete() { echo -e "[COMPLETE] $*"; }

log "Starting removal." 

remove_proxy() {
  rm -f "$APT_PROXY_FILE" || true
  rm -f "$PROFILE_PROXY_FILE" || true
  rm -f "$DOCKER_PROXY_FILE" || true
  systemctl daemon-reload || true
  if systemctl is-active --quiet docker; then
    systemctl restart docker || warn "Docker restart failed after proxy removal."
  fi
  log "Removed proxy configurations."
}

remove_base_commands() {
  for cmd in system-update-with-reboot system-update-no-reboot update-commands update-commands-base pbs-backup pbs-restore pbs-update; do
    if [ -f "$CMD_DEST/$cmd" ]; then
      rm -f "$CMD_DEST/$cmd"
      log "Removed $CMD_DEST/$cmd"
    fi
  done
  if [ -d "$LIB_DEST" ]; then
    rm -f "$LIB_DEST"/*.sh 2>/dev/null || true
    rmdir "$LIB_DEST" 2>/dev/null || true
    log "Removed libs under $LIB_DEST"
  fi
}

remove_qemu_ga() {
  if $REMOVE_QEMU; then
    if systemctl is-active --quiet qemu-guest-agent; then
      systemctl disable --now qemu-guest-agent || warn "Failed to disable qemu-guest-agent"
    fi
    apt-get purge -y qemu-guest-agent || warn "Failed to purge qemu-guest-agent"
    log "Removed qemu-guest-agent."
  fi
}

remove_pbs_client() {
  if $REMOVE_PBS; then
    apt-get purge -y proxmox-backup-client || warn "Failed to purge proxmox-backup-client"
    rm -f /etc/apt/sources.list.d/pbs-client.list
    rm -f /usr/share/keyrings/proxmox-archive-keyring.gpg
    rm -f /etc/pbs-backup.env
    rm -f /etc/pbs/encryption-key.json
    rmdir /etc/pbs 2>/dev/null || true
    rm -f /etc/cron.d/pbs-backup
    rm -f /etc/logrotate.d/pbs-backup
    apt-get update -y || warn "apt-get update failed after PBS repo removal"
    log "Removed PBS client and configuration."
  fi
}

purge_user() {
  if $REMOVE_USER; then
    if id "$MANAGED_USER" >/dev/null 2>&1; then
      userdel -r "$MANAGED_USER" || warn "Failed to remove user $MANAGED_USER"
      log "Removed user $MANAGED_USER"
    else
      warn "User $MANAGED_USER not present; nothing to purge."
    fi
  fi
}

main() {
  remove_proxy
  remove_base_commands
  remove_qemu_ga
  remove_pbs_client
  purge_user
  complete "Removal routine finished."
}

main "$@"
