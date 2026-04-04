#!/bin/bash
#
# Shared git helper functions for ubuntu-autoconfig commands
# Usage: source "$(dirname "$0")/lib/git-helpers.sh"
#
# Requires: logging.sh to be sourced first
#

# Ensure a directory is marked as a git safe directory
ensure_safe_directory() {
    local dir="$1"

    log "Checking if $dir is already a safe Git directory..."

    if sudo -E git config --global --get-all safe.directory | grep -qx "$dir"; then
        log "$dir is already marked as a safe Git directory. Skipping."
        return 0
    fi

    log "Marking $dir as a safe Git directory..."
    if sudo -E git config --global --add safe.directory "$dir"; then
        complete "$dir has been added to safe Git directories."
    else
        fail "Failed to add $dir as a safe Git directory."
    fi
}

# Update a git repository with pull operation
update_git_repo_pull() {
    local dir="$1"

    log "Updating repository: $dir"

    cd "$dir" || fail "Failed to change directory to $dir"

    ensure_safe_directory "$dir"

    log "Resetting any local changes..."
    sudo -E git reset --hard HEAD

    # Note: git clean is disabled - can delete important untracked files
    # sudo -E git clean -fd

    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if ! [[ "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        fail "Invalid branch name detected: $BRANCH"
    fi
    log "Detected current Git branch: '$BRANCH'"

    log "Pulling latest changes from Git..."
    sudo HOME=/home/kynetra -E git pull origin "$BRANCH" || fail "Git pull failed for $dir"

    log "Making all .sh files executable..."
    find "$dir" -path "$dir/lost+found" -prune -o -type f -name "*.sh" -exec sudo chmod +x {} +

    complete "Repository $dir updated successfully"
}

# Update a git repository with force operation
update_git_repo_force() {
    local dir="$1"

    log "Force updating repository: $dir"

    cd "$dir" || fail "Failed to change directory to $dir"

    ensure_safe_directory "$dir"

    log "Resetting any local changes..."
    sudo -E git reset --hard HEAD

    BRANCH=$(git rev-parse --abbrev-ref HEAD)
    if ! [[ "$BRANCH" =~ ^[a-zA-Z0-9._/-]+$ ]]; then
        fail "Invalid branch name detected: $BRANCH"
    fi
    log "Detected current Git branch: '$BRANCH'"

    log "Fetching latest changes from remote..."
    sudo -E git fetch origin "$BRANCH" || fail "Git fetch failed for $dir"

    warn "Forcefully resetting $dir to origin/$BRANCH..."
    sudo -E git reset --hard "origin/$BRANCH" || fail "Git reset failed for $dir"

    log "Making all .sh files executable..."
    find "$dir" -path "$dir/lost+found" -prune -o -type f -name "*.sh" -exec sudo chmod +x {} +

    complete "Repository $dir force-updated successfully"
}

# Rollback a git repository by N commits
rollback_git_repo() {
    local dir="$1"
    local commits="${2:-1}"

    log "Rolling back $dir by $commits commit(s)..."

    cd "$dir" || fail "Failed to change directory to $dir"

    ensure_safe_directory "$dir"

    # Show what we're rolling back from
    current_commit=$(git rev-parse --short HEAD)
    target_commit=$(git rev-parse --short HEAD~"$commits" 2>/dev/null) || fail "Cannot rollback $commits commits - not enough history"

    log "Current commit: $current_commit"
    log "Target commit:  $target_commit"

    # Perform rollback
    if sudo -E git reset --hard HEAD~"$commits"; then
        complete "$dir rolled back successfully"

        # Show the commit we rolled back to
        git log -1 --oneline
    else
        fail "Failed to rollback $dir"
    fi
}
