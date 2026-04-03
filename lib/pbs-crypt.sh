#!/bin/bash
# lib/pbs-crypt.sh - Encrypt/decrypt PBS credentials using machine-id
#
# Uses AES-256-CBC with PBKDF2, keyed from /etc/machine-id.
# Encrypted values are prefixed with "ENC:" in the env file.
#
# Usage:
#   source /usr/local/lib/ubuntu-base/pbs-crypt.sh
#   pbs_source_env /etc/pbs-backup.env   # source + decrypt in one step

pbs_encrypt() {
  local plaintext="$1"
  echo -n "$plaintext" | openssl enc -aes-256-cbc -pbkdf2 -a -A -pass file:/etc/machine-id 2>/dev/null
}

pbs_decrypt() {
  local encrypted="$1"
  echo -n "$encrypted" | openssl enc -aes-256-cbc -pbkdf2 -d -a -A -pass file:/etc/machine-id 2>/dev/null
}

# Source env file and decrypt ENC: prefixed values in-place
pbs_source_env() {
  local env_file="${1:-/etc/pbs-backup.env}"
  [ -f "$env_file" ] || return 1
  # shellcheck source=/dev/null
  source "$env_file"
  # Decrypt any ENC: prefixed values
  for var in PBS_PASSWORD PBS_ENCRYPTION_PASSWORD; do
    local val="${!var:-}"
    if [[ "$val" == ENC:* ]]; then
      local decrypted
      decrypted="$(pbs_decrypt "${val#ENC:}")" || return 1
      eval "export $var=\"\$decrypted\""
    fi
  done
}

# Encrypt sensitive values in an env file (writes in-place or to destination)
pbs_encrypt_env_file() {
  local src="$1" dst="$2"
  if [ "$src" != "$dst" ]; then
    cp "$src" "$dst"
  fi
  for var in PBS_PASSWORD PBS_ENCRYPTION_PASSWORD; do
    local val
    val=$(grep "^${var}=" "$dst" | head -1 | sed "s/^${var}=\"\\(.*\\)\"/\\1/") || continue
    [ -z "$val" ] && continue
    [[ "$val" == ENC:* ]] && continue  # already encrypted
    local encrypted
    encrypted="$(pbs_encrypt "$val")"
    sed -i "s|^${var}=\".*\"|${var}=\"ENC:${encrypted}\"|" "$dst"
  done
}
