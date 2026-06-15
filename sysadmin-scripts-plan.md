# SysAdmin Bash Scripts — Build Plan
> Portfolio project for Linux/SysAdmin job applications.
> Each script should be production-quality: `set -euo pipefail`, root check, `--help` flag, colored output, logging.

---

## Repo Structure

```
homelab/
└── scripts/
    ├── user-management/
    │   └── user-audit.sh
    ├── monitoring/
    │   ├── system-health-report.sh
    │   ├── disk-usage-alert.sh
    │   └── service-watchdog.sh
    ├── security/
    │   ├── ssh-hardening.sh
    │   └── failed-login-report.sh
    └── automation/
        ├── backup-and-verify.sh
        └── provision-new-server.sh
```

---

## Script Standards (apply to every script)

Every script must include:

```bash
#!/usr/bin/env bash
set -euo pipefail
```

- `--help` / `-h` flag with usage and examples
- `$EUID -ne 0` root check where required
- Color output via a `log()` / `warn()` / `alert()` / `ok()` helper
- Colors auto-disable when `--quiet` flag is passed or output is piped to file
- `-o / --output FILE` flag to write report to a file
- Argument parsing via `while [[ $# -gt 0 ]]; do case "$1" in ...`
- Preflight check validating required commands exist before running
- Inline comments explaining *why*, not just *what*

---

## Script 1 — `user-audit.sh`
**Path:** `scripts/user-management/user-audit.sh`
**Run as:** root/sudo

### Purpose
Audit local user accounts for security issues.

### Sections
1. **UID 0 accounts** — flag any non-root user with UID 0 (privilege escalation risk)
2. **Interactive login users** — list all users with a valid login shell (`/bin/bash`, `/bin/zsh`, etc.)
3. **Password expiry** — flag accounts where max days = 99999 or -1 (never expires)
4. **Account lock status** — show locked / unlocked / no-password state via `passwd -S`
5. **Last login timestamps** — show last login or "Never logged in" via `lastlog`
6. **Summary** — count of alerts and warnings

### Key Commands
```bash
awk -F: '$3 == 0' /etc/passwd          # UID 0 check
chage -l "$username"                    # password expiry info
passwd -S "$username"                   # lock status
lastlog -u "$username"                  # last login
```

### Flags
```
-o, --output FILE    Write report to file
-q, --quiet          No color output (cron-safe)
-h, --help           Usage
```

---

## Script 2 — `system-health-report.sh`
**Path:** `scripts/monitoring/system-health-report.sh`
**Run as:** root/sudo

### Purpose
Snapshot the current health state of a Linux system. Meant to be run on-demand or via cron for a daily digest.

### Sections
1. **CPU load** — 1/5/15 min load averages vs CPU core count; warn if load > core count
2. **Memory usage** — total, used, free, swap usage percentage
3. **Disk usage** — all mounted filesystems; warn at 80%, alert at 90%
4. **Failed systemd services** — list any services in `failed` state
5. **Top 5 memory processes** — process name, PID, and % memory
6. **Top 5 CPU processes** — process name, PID, and % CPU
7. **System uptime** — uptime and last reboot time
8. **Summary** — total warnings and alerts found

### Key Commands
```bash
uptime                                  # load averages
free -m                                 # memory
df -h                                   # disk
systemctl --failed                      # failed services
ps aux --sort=-%mem | head -6           # top memory processes
ps aux --sort=-%cpu | head -6           # top CPU processes
who -b                                  # last reboot
```

### Flags
```
-o, --output FILE    Write report to file
-q, --quiet          No color output
-h, --help           Usage
```

---

## Script 3 — `backup-and-verify.sh`
**Path:** `scripts/automation/backup-and-verify.sh`
**Run as:** root/sudo

### Purpose
Back up a source directory to a target (local NAS mount or S3), verify the backup succeeded, apply retention policy, and alert on failure.

### Sections
1. **Pre-backup checks** — source exists, target is mounted/writable, enough space
2. **Backup** — rsync source to timestamped backup directory
3. **Verification** — compare file count and total size between source and backup
4. **Checksum spot-check** — sha256 a random sample of files to confirm integrity
5. **Retention policy** — delete backups older than N days (default: 30)
6. **Logging** — append result (SUCCESS/FAILURE) to a log file
7. **Alert** — send email via `mailx` if backup or verify fails

### Key Commands
```bash
rsync -av --progress "$SRC" "$DEST"    # backup
find "$DEST" -type f | wc -l           # file count verify
sha256sum "$file"                       # checksum spot-check
find "$BACKUP_ROOT" -maxdepth 1 -mtime +$RETENTION_DAYS -exec rm -rf {} \;  # retention
echo "FAILED" | mailx -s "Backup Alert" "$ALERT_EMAIL"  # alert
```

### Flags
```
-s, --source DIR     Source directory to back up (required)
-d, --dest DIR       Destination/target directory (required)
-r, --retain DAYS    Days to keep backups (default: 30)
-e, --email ADDR     Alert email address
-q, --quiet          No color output
-h, --help           Usage
```

---

## Script 4 — `service-watchdog.sh`
**Path:** `scripts/monitoring/service-watchdog.sh`
**Run as:** root/sudo

### Purpose
Monitor a list of critical services. If any are down, attempt a restart, log the event, and alert if the restart fails. Designed to run via cron every 5 minutes.

### Sections
1. **Service list** — accepts services as arguments or reads from a config file
2. **Status check** — `systemctl is-active` for each service
3. **Restart attempt** — if inactive, attempt `systemctl restart`, wait, re-check
4. **Logging** — log every check, restart attempt, and result with timestamp
5. **Alert** — send alert if service is still down after restart attempt
6. **Summary** — services checked, restarted, and failed counts

### Key Commands
```bash
systemctl is-active "$service"          # status check
systemctl restart "$service"            # restart attempt
systemctl is-active "$service"          # post-restart verify
echo "DOWN" | mailx -s "Watchdog Alert" "$ALERT_EMAIL"
```

### Cron Example
```
*/5 * * * * /opt/scripts/service-watchdog.sh nginx mysql sshd >> /var/log/watchdog.log 2>&1
```

### Flags
```
-c, --config FILE    Read service list from file (one per line)
-e, --email ADDR     Alert email on failure
-l, --log FILE       Log file path (default: /var/log/service-watchdog.log)
-q, --quiet          No color output
-h, --help           Usage
```

---

## Script 5 — `disk-usage-alert.sh`
**Path:** `scripts/monitoring/disk-usage-alert.sh`
**Run as:** root/sudo

### Purpose
Check all mounted filesystems and alert if any exceed a usage threshold. Also identify the top largest directories under a given path to help locate the culprit.

### Sections
1. **Filesystem check** — loop all mounted filesystems, warn at threshold, alert at critical
2. **Threshold config** — warn at 80% (default), alert at 90% (default), both configurable
3. **Top directory sizes** — `du` the top 10 largest directories under a given path
4. **Inode check** — also check inode usage (disks can "fill up" on inodes before space)
5. **Alert** — email/log if any filesystem exceeds alert threshold
6. **Summary** — list clean filesystems and flagged ones

### Key Commands
```bash
df -h                                   # filesystem usage
df -i                                   # inode usage
du -ah "$SCAN_PATH" | sort -rh | head -10  # top dirs by size
awk 'NR>1 {print $5, $6}' <<< "$(df -h)"  # parse usage %
```

### Flags
```
-p, --path DIR       Directory to scan for top usage (default: /)
-w, --warn PCT       Warn threshold % (default: 80)
-a, --alert PCT      Alert threshold % (default: 90)
-e, --email ADDR     Alert email address
-q, --quiet          No color output
-h, --help           Usage
```

---

## Script 6 — `ssh-hardening.sh`
**Path:** `scripts/security/ssh-hardening.sh`
**Run as:** root/sudo

### Purpose
Apply SSH security hardening to `/etc/ssh/sshd_config`. Always validates the config before restarting sshd. Supports dry-run mode to preview changes without applying them.

### Changes Applied
1. Disable root login → `PermitRootLogin no`
2. Disable password authentication → `PasswordAuthentication no`
3. Enable public key authentication → `PubkeyAuthentication yes`
4. Set idle timeout → `ClientAliveInterval 300` + `ClientAliveCountMax 2`
5. Limit auth attempts → `MaxAuthTries 3`
6. Disable empty passwords → `PermitEmptyPasswords no`
7. Disable X11 forwarding → `X11Forwarding no`
8. Restrict login to specific users/groups (optional) → `AllowUsers`

### Safety Steps
- Backup `sshd_config` before any changes → `/etc/ssh/sshd_config.bak.TIMESTAMP`
- Apply changes via `sed` with targeted key replacement
- Run `sshd -t` to validate config — **abort and restore backup if test fails**
- Only restart `sshd` after a clean config test

### Key Commands
```bash
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%s)   # backup
sed -i "s/^#*PermitRootLogin.*/PermitRootLogin no/" /etc/ssh/sshd_config
sshd -t                                 # CRITICAL: validate before restart
systemctl restart sshd                  # only runs if sshd -t passes
```

### Flags
```
--dry-run            Show what would change without applying
--allow-users LIST   Comma-separated users to add to AllowUsers
-q, --quiet          No color output
-h, --help           Usage
```

> **Note:** In AWS environments, SSH is often replaced by SSM Session Manager.
> This script is for on-prem / hybrid environments.

---

## Script 7 — `failed-login-report.sh`
**Path:** `scripts/security/failed-login-report.sh`
**Run as:** root/sudo

### Purpose
Parse auth logs for failed SSH login attempts. Summarize by IP, flag IPs exceeding a threshold, and optionally block them via `ufw` or `hosts.deny`.

### Sections
1. **Log source detection** — auto-detect `/var/log/auth.log` (Debian/Ubuntu) or `journalctl` (RHEL/systemd)
2. **Failed attempt extraction** — grep for "Failed password" or "Invalid user"
3. **IP summary** — count attempts per IP, sort descending
4. **Threshold flagging** — flag IPs with attempts above N (default: 10)
5. **Optional blocking** — add flagged IPs to `ufw deny` or `/etc/hosts.deny`
6. **Report output** — clean formatted table of IPs, attempt counts, and block status

### Key Commands
```bash
grep "Failed password" /var/log/auth.log           # Debian/Ubuntu
journalctl _SYSTEMD_UNIT=sshd.service | grep "Failed"  # RHEL/systemd
awk '{print $NF}' | sort | uniq -c | sort -rn      # count + sort by IP
ufw deny from "$ip"                                 # optional block
```

### Flags
```
-t, --threshold N    Flag IPs with >= N attempts (default: 10)
-b, --block          Add flagged IPs to ufw deny rules
-l, --lines N        Only analyze last N lines of log (default: all)
-o, --output FILE    Write report to file
-q, --quiet          No color output
-h, --help           Usage
```

> **Note:** In AWS, this maps to CloudTrail + GuardDuty for login monitoring.

---

## Script 8 — `provision-new-server.sh`
**Path:** `scripts/automation/provision-new-server.sh`
**Run as:** root/sudo

### Purpose
Bootstrap a fresh Linux server to a known secure baseline. Idempotent — safe to run multiple times without side effects. Compatible with EC2 User Data.

### Steps Applied
1. **System update** — `apt update && apt upgrade -y` (or `dnf`/`yum` on RHEL)
2. **Baseline packages** — install: `curl`, `wget`, `git`, `ufw`, `fail2ban`, `unattended-upgrades`, `htop`, `net-tools`
3. **Timezone** — set timezone via argument (default: UTC)
4. **Hostname** — set system hostname
5. **Admin user** — create user, add to `sudo` group, copy SSH public key, lock password login
6. **SSH hardening** — calls or mirrors `ssh-hardening.sh` logic
7. **Firewall** — enable `ufw`, allow SSH, deny everything else by default
8. **Unattended upgrades** — enable automatic security updates
9. **Root lock** — disable direct root login
10. **Completion log** — write provision summary to `/var/log/provision.log`

### Idempotency Rules
- Check if user already exists before creating
- Check if packages are already installed before installing
- Check if UFW rules already exist before adding
- Never fail on already-applied changes — skip and log

### Key Commands
```bash
id "$ADMIN_USER" &>/dev/null || useradd -m -s /bin/bash -G sudo "$ADMIN_USER"
mkdir -p "/home/$ADMIN_USER/.ssh"
echo "$SSH_PUBKEY" > "/home/$ADMIN_USER/.ssh/authorized_keys"
ufw --force enable
ufw default deny incoming
ufw allow ssh
timedatectl set-timezone "$TIMEZONE"
hostnamectl set-hostname "$NEW_HOSTNAME"
```

### Flags
```
-u, --user NAME      Admin username to create (required)
-k, --key  "KEY"     SSH public key string to authorize (required)
-n, --hostname NAME  Hostname to set
-t, --timezone TZ    Timezone (default: UTC)
-q, --quiet          No color output
-h, --help           Usage
```

### EC2 User Data Usage
```bash
#!/usr/bin/env bash
# Paste this script directly into EC2 Launch Template > User Data
# All logic is self-contained — no external dependencies
bash provision-new-server.sh \
  --user deploy \
  --key "ssh-rsa AAAA..." \
  --hostname web-prod-01 \
  --timezone America/New_York
```

---

## Quality Checklist (before committing each script)

- [ ] `#!/usr/bin/env bash` shebang
- [ ] `set -euo pipefail` on line 2
- [ ] Root check (`$EUID -ne 0`)
- [ ] `--help` flag works and shows usage + examples
- [ ] `--quiet` flag disables color
- [ ] `--output` flag writes clean output to file
- [ ] Preflight check validates required commands
- [ ] Tested on a clean VM or container
- [ ] No hardcoded paths (use variables)
- [ ] Comments explain *why*, not just *what*
- [ ] Committed with a meaningful git message

---

## Git Commit Message Format

```
feat(user-audit): add password expiry and UID 0 checks
fix(backup): restore backup on verify failure
docs(watchdog): add cron setup instructions to README
```
