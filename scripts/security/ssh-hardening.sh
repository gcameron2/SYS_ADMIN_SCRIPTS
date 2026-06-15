#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  ssh-hardening.sh — Apply SSH hardening to sshd_config with safe rollback
#  Run as: root / sudo
#
#  NOTE: For AWS environments, SSH is typically replaced by SSM Session Manager.
#  This script targets on-prem / hybrid environments.
# ─────────────────────────────────────────────

# ── Defaults ──────────────────────────────────
SSHD_CONFIG="/etc/ssh/sshd_config"
DRY_RUN=false
ALLOW_USERS=""
OUTPUT_FILE=""
LOG_FILE="/var/log/ssh-hardening.log"
QUIET=false
ALERT_COUNT=0
WARN_COUNT=0
CHANGES_APPLIED=0
BACKUP_FILE=""

# ── Color helpers (disabled when --quiet or piped) ────────────────────────────
if [[ "$QUIET" == false && -t 1 ]]; then
  RED='\033[0;31m'
  YELLOW='\033[1;33m'
  GREEN='\033[0;32m'
  CYAN='\033[0;36m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  RED='' YELLOW='' GREEN='' CYAN='' BOLD='' RESET=''
fi

log()   { echo -e "${CYAN}[INFO]${RESET}  $*"; }
ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; (( WARN_COUNT++ )) || true; }
alert() { echo -e "${RED}[ALERT]${RESET} $*"; (( ALERT_COUNT++ )) || true; }
header(){ echo -e "\n${BOLD}══════════════════════════════════════════${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}══════════════════════════════════════════${RESET}"; }

# ── Logging helper ─────────────────────────────
log_entry() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$LOG_FILE" 2>/dev/null || \
    warn "Could not write to log file: $LOG_FILE"
}

# ── Usage ─────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Apply SSH hardening settings to /etc/ssh/sshd_config. Always backs up the
config first and validates with 'sshd -t' before restarting. Restores the
backup automatically if validation fails.

Hardening applied:
  PermitRootLogin no          Disable direct root SSH login
  PasswordAuthentication no   Require key-based authentication
  PubkeyAuthentication yes    Explicitly enable public key auth
  ClientAliveInterval 300     Disconnect idle sessions after 5 minutes
  ClientAliveCountMax 2       Two missed keepalives before disconnect
  MaxAuthTries 3              Limit failed authentication attempts
  PermitEmptyPasswords no     Reject accounts with no password set
  X11Forwarding no            Disable X11 forwarding (attack surface)
  AllowUsers <list>           (optional) Restrict SSH to specific users

Options:
  --dry-run            Preview changes without modifying any files
  --allow-users LIST   Comma-separated users to set in AllowUsers directive
  -o, --output FILE    Write report to file
  -l, --log    FILE    Log file path (default: /var/log/ssh-hardening.log)
  -q, --quiet          No color output
  -h, --help           Show this help message

Examples:
  sudo $(basename "$0") --dry-run
  sudo $(basename "$0") --allow-users "alice,bob,deploy"
  sudo $(basename "$0") --dry-run --allow-users "alice,bob"
  sudo $(basename "$0") --quiet --output /var/log/ssh-hardening-report.txt
EOF
}

# ── Argument parsing ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)       DRY_RUN=true; shift ;;
    --allow-users)   ALLOW_USERS="$2"; shift 2 ;;
    -o|--output)     OUTPUT_FILE="$2"; shift 2 ;;
    -l|--log)        LOG_FILE="$2"; shift 2 ;;
    -q|--quiet)      QUIET=true; RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''; shift ;;
    -h|--help)       usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Root check ────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

# ── Preflight: validate required commands ─────
REQUIRED_CMDS=(sshd sed grep cp systemctl)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '$cmd' not found." >&2
    exit 1
  fi
done

if [[ ! -f "$SSHD_CONFIG" ]]; then
  echo "Error: sshd config not found at $SSHD_CONFIG" >&2
  exit 1
fi

# ── Redirect to file if --output is set ───────
if [[ -n "$OUTPUT_FILE" ]]; then
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

echo -e "\n${BOLD}SSH Hardening — $(hostname) — $(date)${RESET}"
[[ "$DRY_RUN" == true ]] && echo -e "${YELLOW}  DRY RUN — no files will be modified${RESET}"

# ── Core helper: apply_or_show ─────────────────
# For each setting, either previews the change (dry-run) or applies it.
# Handles commented-out, uncommented, and missing directives.
apply_or_show() {
  local key="$1"
  local value="$2"
  local description="$3"
  local target="${key} ${value}"

  # Match commented or uncommented directives, but not directives that merely
  # start with the same prefix (e.g. PermitRootLogin vs PermitRootLoginForwarding).
  # (\s|$) ensures we match the key as a whole word.
  local current
  current=$(grep -E "^\s*#*\s*${key}(\s|$)" "$SSHD_CONFIG" | head -1 \
            | sed 's/^[[:space:]]*//' || echo "")

  if [[ "$DRY_RUN" == true ]]; then
    if [[ -z "$current" ]]; then
      log "  [ADD]    ${BOLD}${target}${RESET}  — $description"
    elif [[ "$current" == "$target" ]]; then
      ok "  [SKIP]   ${target}  — already correct"
    else
      log "  [CHANGE] '${current}' → '${BOLD}${target}${RESET}'  — $description"
    fi
    return
  fi

  # Apply: replace existing directive (commented or not) or append if absent
  if grep -qE "^\s*#*\s*${key}(\s|$)" "$SSHD_CONFIG"; then
    sed -i -E "s|^\s*#*\s*${key}(\s.*)?$|${target}|" "$SSHD_CONFIG"
  else
    echo "$target" >> "$SSHD_CONFIG"
  fi

  (( CHANGES_APPLIED++ )) || true
  ok "Applied: ${target}  — $description"
  log_entry "SET  $target"
}

# ──────────────────────────────────────────────
#  Section 1: Backup
#  Always back up before touching the config. Timestamp in the filename
#  lets multiple backups coexist safely.
# ──────────────────────────────────────────────
header "Section 1 — Backup"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry-run: skipping backup"
else
  BACKUP_FILE="${SSHD_CONFIG}.bak.$(date +%s)"
  cp "$SSHD_CONFIG" "$BACKUP_FILE"
  ok "Config backed up to: $BACKUP_FILE"
  log_entry "BACKUP $BACKUP_FILE"
fi

# ──────────────────────────────────────────────
#  Section 2: Apply / Preview Hardening Settings
# ──────────────────────────────────────────────
if [[ "$DRY_RUN" == true ]]; then
  header "Section 2 — Preview Changes (dry-run)"
else
  header "Section 2 — Applying Hardening Settings"
fi

apply_or_show "PermitRootLogin"        "no"  "no direct root login via SSH"
apply_or_show "PasswordAuthentication" "no"  "key-based auth only"
apply_or_show "PubkeyAuthentication"   "yes" "explicitly enable public key auth"
apply_or_show "ClientAliveInterval"    "300" "disconnect idle sessions after 5 min"
apply_or_show "ClientAliveCountMax"    "2"   "two missed keepalives before disconnect"
apply_or_show "MaxAuthTries"           "3"   "limit failed auth attempts per connection"
apply_or_show "PermitEmptyPasswords"   "no"  "reject accounts with no password"
apply_or_show "X11Forwarding"          "no"  "disable X11 forwarding"

# AllowUsers is optional — only set if --allow-users was passed
if [[ -n "$ALLOW_USERS" ]]; then
  # Convert comma-separated list to space-separated (sshd_config format)
  allow_users_sshd=$(echo "$ALLOW_USERS" | tr ',' ' ')
  apply_or_show "AllowUsers" "$allow_users_sshd" "restrict SSH access to listed users"
fi

# ──────────────────────────────────────────────
#  Section 3: Validate Config
#  sshd -t parses the config without starting the daemon.
#  A failure here restores the backup — never leave sshd with a broken config.
# ──────────────────────────────────────────────
header "Section 3 — Config Validation"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry-run: skipping sshd -t validation"
else
  log "Running: sshd -t"
  if sshd -t 2>&1; then
    ok "sshd -t passed — config is valid"
    log_entry "VALIDATE passed"
  else
    # Restore backup immediately — a broken sshd config can lock everyone out
    alert "sshd -t FAILED — config has errors"
    alert "Restoring backup: $BACKUP_FILE"
    cp "$BACKUP_FILE" "$SSHD_CONFIG"
    ok "Backup restored: $BACKUP_FILE"
    log_entry "VALIDATE FAILED — restored $BACKUP_FILE"
    alert "No changes applied. Fix the config errors and re-run."
    exit 2
  fi
fi

# ──────────────────────────────────────────────
#  Section 4: Restart sshd
#  Only reached if sshd -t passed.
# ──────────────────────────────────────────────
header "Section 4 — Restart sshd"

if [[ "$DRY_RUN" == true ]]; then
  log "Dry-run: skipping sshd restart"
elif [[ $CHANGES_APPLIED -eq 0 ]]; then
  log "No changes were applied — sshd restart not needed"
else
  log "Restarting sshd..."
  if systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null; then
    ok "sshd restarted successfully"
    log_entry "RESTART sshd OK"
  else
    # At this point sshd_config is valid (passed sshd -t) so restart
    # failure is likely a transient systemd issue — warn but don't exit 2
    warn "sshd restart returned non-zero — config is valid but verify sshd is running"
    log_entry "RESTART sshd returned non-zero"
  fi
fi

# ──────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────
header "Summary"

if [[ "$DRY_RUN" == true ]]; then
  echo -e "  ${BOLD}Mode:${RESET}            dry-run (no changes made)"
else
  echo -e "  ${BOLD}Changes applied:${RESET} $CHANGES_APPLIED"
  echo -e "  ${BOLD}Backup:${RESET}          ${BACKUP_FILE:-n/a}"
fi
echo -e "  ${YELLOW}Warnings:${RESET}        $WARN_COUNT"
echo -e "  ${RED}Alerts:${RESET}          $ALERT_COUNT"
echo ""

if [[ $ALERT_COUNT -gt 0 ]]; then
  alert "SSH hardening encountered errors — review output above."
  exit 2
elif [[ "$DRY_RUN" == true ]]; then
  log "Dry-run complete. Re-run without --dry-run to apply changes."
  exit 0
elif [[ $CHANGES_APPLIED -eq 0 ]]; then
  ok "All settings already correct — no changes needed."
  exit 0
else
  ok "SSH hardening applied successfully ($CHANGES_APPLIED change(s))."
  log_entry "COMPLETE $CHANGES_APPLIED changes applied"
  exit 0
fi
