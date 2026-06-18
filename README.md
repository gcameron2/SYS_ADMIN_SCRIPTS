# Linux SysAdmin Scripts

A portfolio of production-quality Bash scripts covering user auditing, system monitoring, security hardening, backup, and server provisioning.

Each script follows a consistent standard: `set -euo pipefail`, root check, preflight validation, colored output, `--quiet` for cron, and `--help` with usage examples.

---

## Structure

```
scripts/
├── user-management/
│   └── user-audit.sh             # Audit local accounts for security issues
├── monitoring/
│   ├── system-health-report.sh   # CPU, memory, disk, services, top processes
│   └── service-watchdog.sh       # Monitor services, restart on failure, alert
├── security/
│   ├── ssh-hardening.sh          # Harden sshd_config with dry-run and rollback
│   └── failed-login-report.sh    # Parse auth logs, flag IPs, optional firewall block
└── automation/
    └── backup-and-verify.sh      # Rsync backup with checksum verification
```

---

## Requirements

- **OS:** Debian/Ubuntu, RHEL/CentOS/Fedora, or CentOS Stream 10
- **Shell:** Bash 4.x+
- **Run as:** root / sudo (all scripts enforce this)
- **Optional:** `mailx` for email alerts, `firewall-cmd` (RHEL/CentOS) or `ufw` (Debian/Ubuntu) for IP blocking, `shuf` for checksum spot-checks

---

## Scripts

### `user-audit.sh`
Audits local user accounts for common security issues.

**Checks:** UID 0 accounts, users with interactive login shells, passwords that never expire, account lock status, last login timestamps.

```bash
sudo ./scripts/user-management/user-audit.sh
sudo ./scripts/user-management/user-audit.sh --output /var/log/user-audit.txt
sudo ./scripts/user-management/user-audit.sh --quiet  # cron-safe
```

**Exit codes:** `0` clean, `1` warnings, `2` alerts requiring action

---

### `system-health-report.sh`
Snapshots current system health. Suitable for on-demand checks or a daily cron digest.

**Checks:** CPU load vs core count, RAM and swap usage, disk usage per filesystem, failed systemd services, top 5 processes by memory and CPU, uptime and last reboot.

```bash
sudo ./scripts/monitoring/system-health-report.sh
sudo ./scripts/monitoring/system-health-report.sh --output /var/log/health-report.txt

# Daily cron at 07:00
0 7 * * * root /opt/scripts/system-health-report.sh --quiet --output /var/log/health-report.txt
```

---

### `service-watchdog.sh`
Monitors a list of systemd services. Restarts any that are inactive, logs every event, and alerts if a service fails to recover after a restart attempt.

```bash
sudo ./scripts/monitoring/service-watchdog.sh nginx mysql sshd
sudo ./scripts/monitoring/service-watchdog.sh --config /etc/watchdog.conf --email ops@example.com

# Every 5 minutes via cron
*/5 * * * * root /opt/scripts/service-watchdog.sh nginx mysql sshd --quiet --email ops@example.com
```

**Config file format** (one service per line, `#` comments supported):
```
# critical services
nginx
mysql
sshd
```

**Exit codes:** `0` all active, `1` restarted and recovered (investigate root cause), `2` service still down

---

### `ssh-hardening.sh`
Applies SSH hardening settings to `/etc/ssh/sshd_config`. Always backs up the config first and validates with `sshd -t` before restarting. Restores the backup automatically if validation fails.

**Settings applied:** `PermitRootLogin no`, `PasswordAuthentication no`, `PubkeyAuthentication yes`, `ClientAliveInterval 300`, `ClientAliveCountMax 2`, `MaxAuthTries 3`, `PermitEmptyPasswords no`, `X11Forwarding no`, optional `AllowUsers`.

```bash
# Preview changes without touching any files
sudo ./scripts/security/ssh-hardening.sh --dry-run

# Apply
sudo ./scripts/security/ssh-hardening.sh

# Restrict SSH to specific users
sudo ./scripts/security/ssh-hardening.sh --allow-users "alice,bob,deploy"
```

> **Note:** For AWS environments, SSH is typically replaced by SSM Session Manager. This script targets on-prem / hybrid servers.

---

### `failed-login-report.sh`
Parses SSH auth logs for failed login attempts. Summarizes by IP, flags IPs above a threshold, and optionally blocks them via `firewall-cmd` (RHEL/CentOS) or `ufw` (Debian/Ubuntu).

**Auto-detects log source:** `/var/log/auth.log` (Debian/Ubuntu), `/var/log/secure` (RHEL), or `journalctl` fallback.

```bash
sudo ./scripts/security/failed-login-report.sh
sudo ./scripts/security/failed-login-report.sh --threshold 5 --lines 10000
sudo ./scripts/security/failed-login-report.sh --threshold 20 --block
sudo ./scripts/security/failed-login-report.sh --quiet --output /var/log/failed-logins.txt
```

> **Note:** In AWS environments this maps to CloudTrail + GuardDuty.

---

### `backup-and-verify.sh`
Rsyncs a source directory to a timestamped backup, verifies file count and byte size match, spot-checks a random sample of files with `sha256sum`, applies a retention policy, and alerts on any failure.

```bash
sudo ./scripts/automation/backup-and-verify.sh -s /var/www -d /mnt/nas/backups
sudo ./scripts/automation/backup-and-verify.sh -s /home -d /mnt/nas/backups --retain 14 --email ops@example.com

# Nightly cron at 02:00
0 2 * * * root /opt/scripts/backup-and-verify.sh -s /var/www -d /mnt/nas/backups --email ops@example.com --quiet
```

**Backup structure:**
```
/mnt/nas/backups/
  backup_2024-01-14_02-00-00/   ← previous (pruned after --retain days)
  backup_2024-01-15_02-00-00/   ← today's run
```

---

## Script Standards

Every script in this repo follows the same conventions:

| Standard | Implementation |
|---|---|
| Strict mode | `set -euo pipefail` on line 2 |
| Root enforcement | `$EUID -ne 0` check before any action |
| Preflight | Validates all required commands exist before running |
| Color output | `log` / `ok` / `warn` / `alert` helpers; auto-disabled when piped |
| Cron-safe | `--quiet` flag strips all color and decorators |
| File output | `--output FILE` writes a clean copy via `tee` |
| Exit codes | `0` success, `1` warnings, `2` errors requiring action |
| Idempotency | Provisioning and hardening scripts check state before acting |

---

## Running on a Fresh VM

```bash
git clone https://github.com/<you>/homelab.git
cd homelab

# Scripts are already executable (chmod set in git)
sudo ./scripts/monitoring/system-health-report.sh
```
