#!/bin/bash
#
# Shared logging functions for ubuntu-autoconfig commands
# Usage: source "$(dirname "$0")/lib/logging.sh"
#

log() {
    echo -e "\033[1;34m[INFO]\033[0m $*"
}

fail() {
    echo -e "\033[1;31m[ERROR]\033[0m $*" >&2
    exit 1
}

complete() {
    echo -e "\033[1;32m[COMPLETE]\033[0m $*"
}

warn() {
    echo -e "\033[1;33m[WARNING]\033[0m $*"
}
