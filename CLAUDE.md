# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This repository provides automation to bootstrap personal Ubuntu servers (Proxmox VMs or bare metal). It creates the `kynetra` user, applies hardened SSH/sudo configurations, and installs baseline tooling including Docker.

## IMPORTANT: Development Environment Only

**This repository is located on a development/editing machine that CANNOT run the automation scripts.**

- This is a **code repository and editor environment only**
- Do NOT attempt to execute `init.sh`, `remove.sh`, or any system commands that require actual Ubuntu infrastructure
- Do NOT run apt commands, systemctl commands, or attempt to install packages
- Scripts are meant to be deployed to target Ubuntu hosts (Proxmox VMs or bare metal systems)
- Testing and execution must be done on actual Ubuntu target systems, not in this repository environment

**You can:**
- Edit and review scripts
- Update documentation
- Commit and push changes via git
- Analyze code for bugs or improvements

**You cannot:**
- Test scripts by running them
- Install packages or modify system configurations
- Verify runtime behavior (must be done on target systems)

## Quick Reference Commands

### Bootstrap a Fresh Ubuntu Host
```bash
# From /opt/ubuntu-autoconfig
sudo -E ./scripts/init.sh --debug --hostname myserver01   # drop --debug for quieter; --hostname to skip prompt
```

### Remove Configuration
```bash
sudo -E ./scripts/remove.sh                                  # remove commands only
sudo -E ./scripts/remove.sh --purge-user --remove-qemu       # full removal including user
```

### Update Installed Commands
```bash
update-commands        # wrapper that delegates to update-commands-base (or repo-specific version)
update-commands-base   # pulls autoconfig repo and deploys base commands
```

### System Maintenance Commands (installed to /usr/local/bin)
```bash
system-update-with-reboot    # full apt update/upgrade with automatic reboot
system-update-no-reboot      # full apt update/upgrade without reboot
```

## Architecture Overview

### Two-Phase Execution Model (init.sh)

The init script uses a **privilege handoff pattern**:

1. **Phase 1 (as root)**: Hostname + user/config setup
   - Sets hostname (`--hostname` flag or interactive prompt; Enter to skip)
   - Creates `kynetra` if needed
   - Prompts for password if user was just created
   - Copies `.netrc` from invoking user to `kynetra`
   - Applies sudoers, sshd_config, authorized_keys
   - Re-executes itself as `kynetra`

2. **Phase 2 (as kynetra with sudo)**: System configuration
   - Installs baseline packages and Docker CE
   - Installs QEMU guest agent
   - Optionally installs PBS client
   - Installs base commands to /usr/local/bin
   - Runs system-update-with-reboot (triggers reboot)

The handoff is controlled by the `RUN_AS_MANAGED` environment variable. All interactive-or-flag variables (`INSTALL_PBS`, `NEW_HOSTNAME`) are passed through the exec environment so Phase 2 inherits the resolved values.

### Interactive-or-Flag Pattern

Several init features follow a common pattern: an environment variable is empty by default, which triggers an interactive prompt during Phase 1. A CLI flag can pre-set the variable to skip the prompt (useful for unattended/scripted runs).

| Variable | CLI Flag | Behavior when empty | Behavior when set |
|----------|----------|--------------------|--------------------|
| `NEW_HOSTNAME` | `--hostname <name>` | Prompts for hostname (Enter to keep current) | Applies directly, validated against RFC 1123 |
| `INSTALL_PBS` | `--with-pbs` / `--no-pbs` | Prompts yes/no | `"yes"` installs, anything else skips |

When adding new interactive features, follow this pattern: declare the variable with `${VAR:-}`, add a CLI flag to the argument parser, and gate the interactive prompt on the variable being empty.

### Shared Libraries Pattern

Three core libraries provide reusable functionality across scripts:

- **lib/logging.sh**: Colored logging functions (log, warn, fail, complete)
- **lib/git-helpers.sh**: Git safe.directory management for root operations
- **lib/pbs-crypt.sh**: Encrypt/decrypt PBS credentials using machine-id (AES-256-CBC)

Scripts source from repo first, then fall back to installed location:
```bash
source "$REPO_ROOT/lib/logging.sh" || source "/usr/local/lib/ubuntu-base/logging.sh"
```

Libraries are installed to `/usr/local/lib/ubuntu-base/` during init.

### Configuration Files

Three hardened configuration files in `configs/`:
- `configs/sudoers` - copied to `/etc/sudoers` (mode 0440)
- `configs/sshd_config` - copied to `/etc/ssh/sshd_config` (sshd reloaded)
- `configs/authorized_keys` - copied to `/home/kynetra/.ssh/authorized_keys` (mode 600, owner kynetra)

Applied with strict permissions during Phase 1 of init.sh.

### Base Commands

Scripts in `commands/` are installed to `/usr/local/bin` during init:
- `update-commands-base` - pulls latest autoconfig code from git and reinstalls base commands
- `update-commands` - thin wrapper that delegates to `update-commands-base` (overwritten by repo-specific versions on hosts that have one)
- `system-update-with-reboot` - apt update/upgrade/autoremove + reboot
- `system-update-no-reboot` - apt update/upgrade/autoremove (no reboot)
- `pbs-backup` - backs up configured targets to Proxmox Backup Server (with optional encryption)
- `pbs-restore` - restores backups from PBS (interactive, selective, or direct snapshot modes)
- `pbs-update` - pulls latest code and re-deploys PBS artifacts (commands, libs, env, cron)
- `pbs-setup` - standalone PBS client installation

Existing commands are backed up with timestamp suffix before overwrite.

### Non-Interactive Package Installation

All apt operations use:
```bash
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
```

Debconf is preseeded for packages that prompt (e.g., iperf3):
```bash
echo "iperf3 iperf3/server boolean false" | debconf-set-selections
```

## Development Guidelines

### Testing Changes to init.sh

Test on a disposable VM:
```bash
# Clone to /opt/ubuntu-autoconfig
cd /opt/ubuntu-autoconfig
sudo -E git pull origin main
sudo -E ./scripts/init.sh --debug
```

**Note**: init.sh triggers a system reboot at the end. Plan accordingly.

### Modifying Configuration Files

1. Edit files in `configs/` (sudoers, sshd_config, authorized_keys)
2. Test by running `sudo -E ./scripts/init.sh` on a test VM
3. Verify SSH access and sudo behavior before committing

### Adding New Base Commands

1. Create executable script in `commands/`
2. Include logging functions inline or source from `/usr/local/lib/ubuntu-base/logging.sh`
3. Handle `sudo -E` elevation once at top (see system-update-with-reboot:11-13)
4. Add script name to backup/install logic if it needs update-commands support

### Idempotency Requirements

Scripts must be safely re-runnable:
- Check if user/file/package exists before creating
- Back up existing files before overwriting (with timestamp suffix)
- Use `|| true` for operations that may fail gracefully
- Log skips explicitly when optional assets are missing

### Error Handling Pattern

All scripts use:
```bash
set -euo pipefail
trap 'fail "Script failed at line $LINENO"' ERR
```

Fail fast with clear messages using the `fail` function from logging.sh.

## Repository Structure

```
ubuntu-autoconfig/
├── CLAUDE.md             # This file - guidance for Claude Code
├── README.md             # Repository documentation
├── scripts/
│   ├── init.sh          # Main bootstrap script
│   └── remove.sh        # Removal/cleanup script
├── lib/
│   ├── logging.sh       # Colored logging functions
│   ├── git-helpers.sh   # Git safety helpers
│   └── pbs-crypt.sh     # PBS credential encryption helpers
├── commands/            # Scripts installed to /usr/local/bin
│   ├── update-commands-base
│   ├── update-commands
│   ├── system-update-with-reboot
│   ├── system-update-no-reboot
│   ├── pbs-backup
│   ├── pbs-restore
│   ├── pbs-update
│   └── pbs-setup
├── configs/             # System config files
│   ├── sudoers
│   ├── sshd_config
│   ├── authorized_keys
│   ├── pbs-backup.env
│   └── pbs-backup-logrotate
└── source/              # Upstream reference implementations
    ├── ubuntu-base-commands/
    └── ubuntu-autodeploy-base/
```

## Important Constraints

### Git Operations
- Repository is cloned/operated under sudo (root owns /opt/ubuntu-autoconfig)
- Scripts use `sudo -E` to preserve environment when pulling/resetting
- Git safe.directory is configured for /opt/ubuntu-autoconfig

### Hardcoded Values
- Managed user: `kynetra`
- Library destination: `/usr/local/lib/ubuntu-base`
- Command destination: `/usr/local/bin`
- Install directory: `/opt/ubuntu-autoconfig`
