# Ubuntu Autoconfig

AWS-first automation to bootstrap Ubuntu hosts (with Proxmox/other hypervisors as secondary). Creates `commsadmin`, applies sshd/sudoers/authorized_keys, configures proxies, installs baseline tooling, Docker, qemu-guest-agent (non-AWS), optional PBS backup client, and base maintenance commands. A removal script cleans up proxies/commands and optionally the user.

## Contents

- [AWS vs Non-AWS Behavior](#aws-vs-non-aws-behavior)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start-remote-host)
- [Init Flags](#init-flags)
- [Removal](#removal)
- [What Init Does](#what-init-does)
- [Proxmox Backup Server (PBS) Client](#proxmox-backup-server-pbs-client)
  - [What Gets Installed](#what-gets-installed)
  - [Post-Install Setup](#post-install-setup)
  - [Encryption at Rest](#encryption-at-rest)
  - [Running Backups](#running-backups)
  - [Updating PBS Artifacts](#updating-pbs-artifacts)
  - [Restoring Backups](#restoring-backups)
  - [PBS Token Permissions](#pbs-token-permissions)
  - [Rebuilding a Machine from Backup](#rebuilding-a-machine-from-backup)
- [Notes](#notes)

## AWS vs Non-AWS Behavior

Init detects the environment via **IMDSv2** (AWS Instance Metadata Service v2). Behavior differs based on detection:

| Feature | AWS EC2 | Non-AWS (Proxmox, bare metal) |
|---------|---------|-------------------------------|
| User creation | Always creates `commsadmin` | Always creates `commsadmin` |
| QEMU guest agent | Skipped | Installed and enabled |
| PBS backup client | Available (`--with-pbs`) | Available (`--with-pbs`) |

Detection is automatic -- if the IMDSv2 token endpoint (`http://169.254.169.254`) responds, the host is treated as AWS. There are currently no environment variable overrides to force or skip AWS detection.

### Athena integration (FTP/NTP stack on non-AWS)

The companion [athena](https://nsggroup.visualstudio.com/Network-Ops/_git/athena) repo (`init-athena.sh`) uses the same IMDSv2 check. On AWS, the FTP/TFTP/HTTP/NTP stack installs automatically. On non-AWS hosts that need those services, set `FTP=Yes` before running athena init:

```bash
export FTP=Yes
sudo -E ./init-athena.sh
```

The `FTP` variable can also be persisted to `/etc/environment` using athena's `set-ftp-yes.sh` script so it survives reboots and is picked up by `update-athena`.

Key athena environment variables that can be pre-configured on the host:

| Variable | Default | Purpose |
|----------|---------|---------|
| `FTP` | _(empty)_ | Set to `Yes` on non-AWS to enable FTP/NTP stack |
| `AUTO_REGION_NTP` | `true` | Auto-select NTP pools based on AWS region |
| `NTP_UPSTREAM_SERVERS` | North America + Europe pools | Space-separated NTP server FQDNs |
| `NTP_ALLOW_SUBNETS` | `10.0.0.0/8 138.84.0.0/16` | Networks allowed to query NTP |
| `NTP_BIND` | `0.0.0.0` | NTP server bind address |
| `NTP_OPEN_UFW` | `true` | Open UFW firewall for UDP/123 |
| `DEVICE` | _(auto-detect)_ | Block device for FTP storage volume |
| `MOUNT_POINT` | `/mnt/ftp` | FTP storage mount path |
| `OWNER` | `1000:1000` | UID:GID ownership of FTP directory |
| `ATHENA_CRED_HOME` | `/home/commsadmin` | Path to home dir containing `.netrc` for git |

## Prerequisites
- Ubuntu host with sudo access.
- Proxy credentials reachable to Ubuntu mirrors (hardcoded in script per manual guide).
- PAT in `~/.netrc` for cloning/pulling from Azure DevOps.

## Quick Start (remote host)
```bash
nano ~/.netrc
# ensure your Azure DevOps Git PAT is present

sudo -E mkdir -p /opt/ubuntu-autoconfig && cd /opt/ubuntu-autoconfig
sudo -E git init
sudo -E git remote add origin https://nsggroup.visualstudio.com/Network-Ops/_git/ubuntu-autoconfig
sudo -E git config --global --add safe.directory /opt/ubuntu-autoconfig
sudo -E git checkout -b main
sudo -E git reset --hard HEAD
sudo -E git pull origin main --allow-unrelated-histories

# run bootstrap (prompts for commsadmin password; will reboot at end)
sudo -E chmod +x scripts/init.sh
sudo -E ./scripts/init.sh --debug --hostname myserver01   # drop --debug for quieter; --hostname to skip prompt
```

## Init Flags

| Flag | Effect |
|------|--------|
| `--debug` | Enable shell tracing and extra logging |
| `--with-pbs` | Install Proxmox Backup Server client (skip interactive prompt) |
| `--no-pbs` | Skip PBS client installation (skip interactive prompt) |
| `--hostname <name>` | Set the server hostname (skip interactive prompt) |

Without `--with-pbs` or `--no-pbs`, init will prompt interactively. Without `--hostname`, init will prompt for a hostname (press Enter to keep the current one).

## Removal
```bash
sudo -E ./scripts/remove.sh                                          # remove proxies/commands
sudo -E ./scripts/remove.sh --purge-user --remove-qemu               # remove user/home and qemu-guest-agent
sudo -E ./scripts/remove.sh --remove-pbs                             # remove PBS client and config
sudo -E ./scripts/remove.sh --purge-user --remove-qemu --remove-pbs  # full removal
```

## What Init Does
1) Set hostname (interactive prompt or `--hostname` flag); skip if user presses Enter.
2) Ensure `commsadmin` exists; prompt for password if newly created; copy `.netrc` from invoking user.
3) Apply `configs/sudoers`, `configs/sshd_config`, `configs/authorized_keys`.
4) Configure proxies for apt, shell (`.bashrc`), and Docker override.
5) Install baseline packages: curl, iperf3 (preseeded), traceroute, tree, dos2unix, glances, speedtest-cli, systemd.
6) Install Docker CE/Compose from Docker repo; add `commsadmin` to docker group.
7) Install qemu-guest-agent on non-AWS.
8) Optionally install Proxmox Backup Server client (see below).
9) Install base commands (`commands/*`) to `/usr/local/bin` and libs to `/usr/local/lib/ubuntu-base`. Includes `update-commands-base` (pulls autoconfig repo and deploys base commands) and a thin `update-commands` wrapper (overwritten by repo-specific versions on hosts with athena/hyperion/etc).
10) Run `system-update-with-reboot` (will reboot).

## Proxmox Backup Server (PBS) Client

Optional PBS client installation for backing up and restoring hosts to/from a Proxmox Backup Server. Backups are encrypted client-side with AES-256-GCM before leaving the host.

### What gets installed
- `proxmox-backup-client` package (from Proxmox APT repo)
- `/etc/pbs-backup.env` — connection, encryption, and target config (credentials encrypted with machine-id)
- `/etc/pbs/encryption-key.json` — AES-256-GCM encryption key (mode 600, root-only)
- `/usr/local/bin/pbs-backup` — backup command (cron'd nightly at 2 AM)
- `/usr/local/bin/pbs-restore` — restore command
- `/usr/local/bin/pbs-update` — pull latest code and re-deploy PBS artifacts
- `/usr/local/lib/ubuntu-base/pbs-crypt.sh` — credential encryption/decryption helper
- `/etc/cron.d/pbs-backup` — nightly cron job
- `/etc/logrotate.d/pbs-backup` — weekly log rotation (4 copies, compressed)

### Post-install setup
After init completes, edit `/etc/pbs-backup.env` with real PBS server details:
```bash
sudo nano /etc/pbs-backup.env
```

Required fields:
- `PBS_REPOSITORY` — format: `user@realm!tokenname@server:datastore`
- `PBS_PASSWORD` — API token secret
- `PBS_FINGERPRINT` — server fingerprint (optional, for self-signed certs)
- `PBS_BACKUP_TARGETS` — space-separated `label.pxar:/path` pairs

To get password-protected encryption, set `PBS_ENCRYPTION_PASSWORD` in the env file **before** running `init.sh --with-pbs`. If not set, the key is still generated (AES-256-GCM encryption is still applied) but without a key password.

### Encryption at rest

**Backup encryption**: All backups are encrypted client-side with AES-256-GCM. Data is encrypted before leaving the host — the PBS server never sees plaintext data.

The encryption key is generated automatically during `init.sh --with-pbs` and stored at `/etc/pbs/encryption-key.json` (mode 600, root:root).

| Variable | Default | Purpose |
|----------|---------|---------|
| `PBS_KEYFILE` | `/etc/pbs/encryption-key.json` | Path to encryption key |
| `PBS_ENCRYPTION_PASSWORD` | _(placeholder)_ | Password protecting the key file |

> **CRITICAL**: Back up the encryption key and password to a safe location (offline storage or a separate secrets manager). Without the key, encrypted backups are **permanently irrecoverable**.

**Credential encryption**: `PBS_PASSWORD` and `PBS_ENCRYPTION_PASSWORD` are encrypted at rest in the deployed `/etc/pbs-backup.env` using AES-256-CBC keyed from `/etc/machine-id`. This protects credentials if an attacker gains filesystem read access. Encrypted values are stored with an `ENC:` prefix and decrypted transparently at runtime by `pbs-backup`, `pbs-restore`, and `pbs-update`.

The repo copy (`configs/pbs-backup.env`) stays plaintext — encryption happens only at deployment time (during `init.sh --with-pbs` or `pbs-update`). The encryption helper lives at `lib/pbs-crypt.sh` (installed to `/usr/local/lib/ubuntu-base/pbs-crypt.sh`).

**Regenerating the backup encryption key with a password** (if initial setup used kdf=none):
```bash
sudo rm /etc/pbs/encryption-key.json
# Set PBS_ENCRYPTION_PASSWORD in /etc/pbs-backup.env to a strong passphrase
sudo proxmox-backup-client key create /etc/pbs/encryption-key.json --kdf scrypt
sudo chmod 600 /etc/pbs/encryption-key.json
sudo chown root:root /etc/pbs/encryption-key.json
```

Note: a new key means new backups are encrypted with the new key. Old backups still require the old key to restore.

### Running backups

**Automatic**: cron runs `pbs-backup` nightly at 2 AM, logging to `/var/log/pbs-backup.log`.

**Manual**:
```bash
sudo pbs-backup
```

What happens: validates config, decrypts credentials from `/etc/pbs-backup.env`, builds the target list (skips missing paths with a warning), runs `proxmox-backup-client backup` with `--keyfile` if the encryption key exists.

**Log rotation**: The cron job logs to `/var/log/pbs-backup.log`. Logrotate rotates this file weekly, keeping 4 compressed copies. The logrotate config is deployed to `/etc/logrotate.d/pbs-backup` during init.

**Default backup targets:**

| Label | Path | Rationale |
|-------|------|-----------|
| `home.pxar` | `/home/commsadmin` | User data and configs |
| `mnt.pxar` | `/mnt` | Mounted data volumes |
| `docker-volumes.pxar` | `/var/lib/docker/volumes` | Docker named volume storage |

Paths that don't exist at backup time are skipped with a warning.

#### Snapshot retention (server-side prune)

Snapshot pruning is managed **server-side on the PBS datastore**, not by client hosts. This prevents a compromised host from deleting its own backup history.

Configure prune jobs in the PBS web UI: **Datastore > Prune & GC > Prune Jobs**. Recommended retention:

| Tier | Keep |
|------|------|
| Daily | 7 |
| Weekly | 4 |
| Monthly | 3 |

> **Note**: The backup token only needs the **DatastoreBackup** role (not DatastorePowerUser). See [PBS token permissions](#pbs-token-permissions).

### Updating PBS artifacts

Use `pbs-update` to pull the latest code and re-deploy all PBS-related files without running the full `init.sh`:

```bash
sudo pbs-update           # pull latest, re-deploy PBS commands/libs/env/cron
sudo pbs-update --debug   # same, with shell tracing
```

What it deploys:
- PBS commands (`pbs-backup`, `pbs-restore`, `pbs-update`) to `/usr/local/bin`
- Shared libraries (`lib/*.sh`) to `/usr/local/lib/ubuntu-base/`
- `/etc/pbs-backup.env` — merges repo template with existing credentials, encrypts sensitive values
- Cron job at `/etc/cron.d/pbs-backup`
- Logrotate config at `/etc/logrotate.d/pbs-backup`

What it does **not** touch: the encryption key at `/etc/pbs/encryption-key.json`.

### Restoring backups

PBS groups snapshots by hostname (`host/<hostname>/<timestamp>`). The `pbs-restore` command filters by the current machine's hostname when listing or selecting snapshots.

```bash
# List available snapshots for this host
sudo pbs-restore --list

# Interactive restore — pick a snapshot, restore all archives
sudo pbs-restore

# Restore a specific snapshot (all archives)
sudo pbs-restore --snapshot host/myserver01/2024-01-15T02:00:00Z

# Restore a single archive to a specific directory
sudo pbs-restore --snapshot host/myserver01/2024-01-15T02:00:00Z \
  --archive home.pxar --target /tmp/restore-home

# Full usage
sudo pbs-restore --help
```

| Flag | Purpose |
|------|---------|
| `--list` | List snapshots for this host and exit |
| `--snapshot <snap>` | Restore from this snapshot (skip interactive picker) |
| `--archive <name>` | Restore only this archive (e.g., `home.pxar`) |
| `--target <path>` | Restore to this directory (default: `/mnt/restore/<timestamp>`) |

**Important notes:**
- Default restore location is `/mnt/restore/<timestamp>` — each restore gets a unique directory
- If the hostname has changed since the backup was taken, use `--snapshot` with the full path (find it with `proxmox-backup-client snapshot list`)
- The encryption key must be present at the path in `PBS_KEYFILE` to restore encrypted backups

### PBS token permissions

The current token `AWSbackup@pbs!AWSClients` needs:
- **DatastoreBackup** — create backups and restore own backups

For restore of other hosts' snapshots, the token also needs:
- **DatastoreReader** — read/inspect snapshot contents and perform restores

Pruning is handled server-side; the client token does **not** need prune permissions. This limits the blast radius if a host is compromised — an attacker cannot delete backup history.

Configure in the PBS web UI: **Configuration > Access Control > Permissions**. Add a new ACL entry for the token with path `/datastore/BCK01_scsi1` and the appropriate role.

**PBS datastore roles reference:**

| Role | Can Backup | Can Restore | Can Prune | Can Admin |
|------|-----------|-------------|-----------|-----------|
| DatastoreBackup | Yes | Own only | No | No |
| DatastoreReader | No | Yes | No | No |
| DatastorePowerUser | Yes | Yes | Own only | No |
| DatastoreAdmin | Yes | Yes | Yes | Yes |

### Rebuilding a machine from backup

```bash
# 1. Run init.sh on the fresh host (creates user, installs tooling, PBS client)
sudo -E ./scripts/init.sh --debug --with-pbs --hostname myserver01

# 2. Copy the encryption key from your offline backup
sudo mkdir -p /etc/pbs
sudo cp /path/to/backup/encryption-key.json /etc/pbs/encryption-key.json
sudo chmod 600 /etc/pbs/encryption-key.json
sudo chown root:root /etc/pbs/encryption-key.json

# 3. Edit /etc/pbs-backup.env with PBS server credentials (if not already correct)
sudo nano /etc/pbs-backup.env

# 4. Find and restore the snapshot you need
sudo pbs-restore --list                                    # find the snapshot
sudo pbs-restore --snapshot host/oldhost/2024-01-15T02:00:00Z  # use old hostname if it changed
```

## Notes
- Hardcoded proxy per manual deploy: `http://iris:BEDSIDE-martine-paying@proxy.network.pilkington.net:3128`; `no_proxy` includes internal ranges.
- AWS detection via IMDSv2; QEMU GA only on non-AWS.
- Debug: `--debug` enables tracing and extra logging.
- Config files live in `configs/`; update them as needed before running.
