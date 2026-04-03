#!/bin/bash
# lib/logging.sh - Shared logging functions for Ubuntu base commands
#
# Provides consistent colored logging output across all scripts.
#
# Usage:
#   source "$(dirname "$0")/../lib/logging.sh" || source "/usr/local/lib/ubuntu-base/logging.sh"
#   log "Info message"
#   warn "Warning message"
#   fail "Error message"  # This will exit with code 1
#   complete "Success message"

log()      { echo -e "\033[1;34m[INFO]\033[0m $*"; }
fail()     { echo -e "\033[1;31m[ERROR]\033[0m $*" >&2; exit 1; }
complete() { echo -e "\033[1;32m[COMPLETE]\033[0m $*"; }
warn()     { echo -e "\033[1;33m[WARNING]\033[0m $*"; }
