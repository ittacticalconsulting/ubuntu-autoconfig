# Autoconfig Agents

This repository will host the automation that provisions Ubuntu hosts primarily on AWS and secondarily on Proxmox or other hypervisors. The intent is to keep agents simple, predictable, and aligned with the behavior demonstrated in `ubuntu-autodeploy-base` and `ubuntu-base-commands`.

## Purpose
- Bootstrap a fresh Ubuntu system with baseline users, SSH/sudo hardening, proxy settings, tooling, and (optionally) monitoring.
- Behave safely across environments: AWS (IMDSv2 available) and non-AWS (e.g., Proxmox) with sensible defaults for each.
- Reuse shared logging/AWS helpers so scripts remain consistent and auditable.

## Guiding Principles
- **Detect environment first:** Use IMDSv2 to detect AWS; assume non-AWS when no token is returned (covers Proxmox and other hypervisors).
- **Least surprise user management:** On AWS always ensure `commsadmin` exists; on non-AWS log the absence and only create when explicitly configured.
- **Apply configs deliberately:** Copy vetted `sudoers`, `sshd_config`, and `authorized_keys` from repo to system paths with correct ownership/permissions; never overwrite unknown files silently.
- **Single-elevation runs:** Elevate once (sudo) and keep subsequent operations non-interactive (`DEBIAN_FRONTEND=noninteractive`, `NEEDRESTART_MODE=a`).
- **Deterministic package installs:** Update apt, install a minimal baseline (`curl`, `iperf3`, `traceroute`, `tree`, `dos2unix`, `speedtest-cli`), and seed debconf (e.g., iperf3) to avoid prompts.
- **Container tooling:** Install Docker CE/Compose from the official repo and add the managed user to the `docker` group.
- **Hypervisor-specific extras:** Install and enable QEMU Guest Agent on non-AWS; skip on AWS.
- **Optional integrations:** Support a monitoring stack deployment under `/opt/ubuntu-monitoring` when the source is present; expose hooks for proxy configuration (e.g., `scripts/set-proxy.sh`).
- **Logging and failure clarity:** Use shared colored logging functions; fail fast with clear messages, and mark completion explicitly.
- **Idempotent and recoverable:** Re-runnable without breaking existing hosts; back up any replaced binaries/configs when practical.

## Expected Agent Flow (baseline)
1) Determine `SCRIPT_DIR` and run from it to ensure relative paths resolve.  
2) Detect AWS via IMDSv2 token; branch behavior accordingly (user creation, QEMU agent).  
3) Create/validate `commsadmin` on AWS; on other platforms, only create when configured.  
4) Apply configs: `sudoers`, `sshd_config` (reload `sshd`), and `authorized_keys` for the managed user with strict permissions.  
5) Run proxy automation hook if `scripts/set-proxy.sh` exists and is executable.  
6) Update apt, install baseline packages, and handle debconf preseeding for noninteractive runs.  
7) Install Docker CE/Compose from the Docker apt repository; add managed user to `docker` group.  
8) If non-AWS, install and enable `qemu-guest-agent`.  
9) If monitoring sources are present, copy them to `/opt/ubuntu-monitoring` and bring up the stack via `docker compose`.  
10) Emit a clear completion message.

## Libraries and Reuse
- Source logging helpers (`lib/logging.sh`) for consistent output.  
- Source AWS helpers (`lib/aws.sh`) for IMDSv2 token handling and metadata lookups.  
- Use git safety helpers (`lib/git-helpers.sh`) when interacting with repos as root (safe.directory).  
- Keep shared libs installable under `/usr/local/lib/ubuntu-base` with commands placed in `/usr/local/bin` for system-wide availability.

## Safety and Hardening Notes
- Do not run destructive git resets or cleans on user directories unless explicitly intended.  
- Preserve permissions: `0440` for `sudoers`, `700` for `.ssh`, `600` for `authorized_keys`.  
- Avoid interactive prompts; preseed where needed.  
- Log skips explicitly when optional assets (configs, scripts, monitoring stack) are missing.  
- When adding commands to `/usr/local/bin`, back up existing versions with timestamped suffixes.

## Platform Considerations
- **AWS:** IMDSv2 available; create `commsadmin`; skip QEMU GA.  
- **Proxmox/Other:** IMDSv2 absent; optionally create `commsadmin`; do install QEMU GA; same baseline packages and Docker flow.

## Next Steps
- Flesh out the actual agent scripts in this repo using the above flow.  
- Port or reference configs (`configs/`) and scripts (`scripts/`) from the base repos.  
- Add a README that documents AWS vs Proxmox usage and the installation path for shared libs/commands.

## Codex Governance Reminder
- At session start in Codex, read and adhere to `/home/commsadmin/codex/base/codex-gonvernance.md` alongside this `agents.md` to honor session and git constraints.
