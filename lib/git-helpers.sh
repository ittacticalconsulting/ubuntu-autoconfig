#!/bin/bash
# lib/git-helpers.sh - Shared Git helper functions
#
# Provides consistent Git operations across all scripts.
#
# Usage:
#   source "$(dirname "$0")/../lib/git-helpers.sh"
#   ensure_git_safe_directory "/path/to/repo"
#   detect_current_branch

# Ensure a directory is marked as a Git safe directory
# Usage: ensure_git_safe_directory "/path/to/repo"
ensure_git_safe_directory() {
    local dir="$1"
    
    if [ -z "$dir" ]; then
        echo "[ERROR] ensure_git_safe_directory: directory path required" >&2
        return 1
    fi
    
    if sudo -E git config --global --get-all safe.directory | grep -qx "$dir"; then
        return 0  # Already added
    fi
    
    if ! sudo -E git config --global --add safe.directory "$dir"; then
        echo "[ERROR] Failed to add $dir to Git safe directories" >&2
        return 1
    fi
    
    # Verify it was added
    if sudo -E git config --global --get-all safe.directory | grep -qx "$dir"; then
        return 0
    else
        echo "[ERROR] Tried to add $dir, but it is NOT listed as a safe Git directory!" >&2
        return 1
    fi
}

# Detect and return the current Git branch
# Usage: BRANCH=$(detect_current_branch)
detect_current_branch() {
    git rev-parse --abbrev-ref HEAD 2>/dev/null
}

# Pull latest changes from the current branch
# Usage: git_pull_current_branch
git_pull_current_branch() {
    local branch
    branch=$(detect_current_branch)
    
    if [ -z "$branch" ]; then
        echo "[ERROR] Not in a Git repository or unable to detect branch" >&2
        return 1
    fi
    
    echo "[INFO] Detected current Git branch: '$branch'"
    echo "[INFO] Pulling latest changes from branch '$branch'..."
    
    if ! sudo HOME=/home/kynetra -E git pull origin "$branch"; then
        echo "[ERROR] Git pull failed for branch '$branch'" >&2
        return 1
    fi
    
    return 0
}
