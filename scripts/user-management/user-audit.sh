#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  user-audit.sh — Audit local user accounts for security issues
#  Run as: root / sudo
# ─────────────────────────────────────────────

# ── Defaults ──────────────────────────────────
OUTPUT_FILE=""
QUIET=false
ALERT_COUNT=0
WARN_COUNT=0

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

# ── Usage ─────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Audit local user accounts for security issues.

Options:
  -o, --output FILE   Write report to file
  -q, --quiet         No color output (cron-safe)
  -h, --help          Show this help message

Examples:
  sudo $(basename "$0")
  sudo $(basename "$0") --output /var/log/user-audit.txt
  sudo $(basename "$0") --quiet --output /tmp/report.txt
EOF
}

# ── Argument parsing ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output) OUTPUT_FILE="$2"; shift 2 ;;
    -q|--quiet)  QUIET=true; RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''; shift ;;
    -h|--help)   usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Root check ────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

# ── Preflight: validate required commands ─────
REQUIRED_CMDS=(awk grep chage passwd lastlog sort)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '$cmd' not found." >&2
    exit 1
  fi
done

# ── Redirect to file if --output is set ───────
if [[ -n "$OUTPUT_FILE" ]]; then
  # Tee to file; colors already stripped when not a tty
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

# ──────────────────────────────────────────────
#  Section 1: UID 0 accounts (privilege escalation risk)
# ──────────────────────────────────────────────
header "Section 1 — UID 0 Accounts"

uid0_users=$(awk -F: '$3 == 0 {print $1}' /etc/passwd)
uid0_count=0

while IFS= read -r user; do
  if [[ "$user" == "root" ]]; then
    ok "root has UID 0 (expected)"
  else
    alert "Non-root user '$user' has UID 0 — PRIVILEGE ESCALATION RISK"
    (( uid0_count++ )) || true
  fi
done <<< "$uid0_users"

[[ $uid0_count -eq 0 ]] && ok "No unexpected UID 0 accounts found."

# ──────────────────────────────────────────────
#  Section 2: Interactive login users
#  A valid login shell means the account can open a session.
# ──────────────────────────────────────────────
header "Section 2 — Interactive Login Users"

VALID_SHELLS=$(grep -v '^#' /etc/shells 2>/dev/null || echo "/bin/bash /bin/zsh /bin/sh /bin/fish")

log "Users with a valid login shell:"
while IFS=: read -r username _ _ _ _ _ shell; do
  for valid in $VALID_SHELLS; do
    if [[ "$shell" == "$valid" ]]; then
      echo "    ${CYAN}${username}${RESET}  (shell: $shell)"
      break
    fi
  done
done < /etc/passwd

# ──────────────────────────────────────────────
#  Section 3: Password expiry
#  99999 or -1 means "never expires" — flag it.
# ──────────────────────────────────────────────
header "Section 3 — Password Expiry"

while IFS=: read -r username _ uid _ _ _ shell; do
  # Skip system accounts (UID < 1000) and nologin shells
  [[ $uid -lt 1000 ]] && continue
  [[ "$shell" == *nologin* || "$shell" == *false* ]] && continue

  max_days=$(chage -l "$username" 2>/dev/null | awk -F': ' '/Maximum number of days/{print $2}')

  if [[ "$max_days" == "99999" || "$max_days" == "-1" ]]; then
    warn "User '$username' password never expires (max days: $max_days)"
  else
    ok "$username — password expires after $max_days days"
  fi
done < /etc/passwd

# ──────────────────────────────────────────────
#  Section 4: Account lock status
# ──────────────────────────────────────────────
header "Section 4 — Account Lock Status"

while IFS=: read -r username _ uid _ _ _ shell; do
  [[ $uid -lt 1000 ]] && continue
  [[ "$shell" == *nologin* || "$shell" == *false* ]] && continue

  status_line=$(passwd -S "$username" 2>/dev/null || true)
  status_code=$(echo "$status_line" | awk '{print $2}')

  case "$status_code" in
    L|LK) warn  "$username — account is LOCKED ($status_code)" ;;
    NP)   alert "$username — NO PASSWORD SET" ;;
    P|PS) ok    "$username — password set ($status_code)" ;;
    *)    log   "$username — unknown status: '$status_code'" ;;
  esac
done < /etc/passwd

# ──────────────────────────────────────────────
#  Section 5: Last login timestamps
# ──────────────────────────────────────────────
header "Section 5 — Last Login Timestamps"

while IFS=: read -r username _ uid _ _ _ shell; do
  [[ $uid -lt 1000 ]] && continue
  [[ "$shell" == *nologin* || "$shell" == *false* ]] && continue

  lastlog_output=$(lastlog -u "$username" 2>/dev/null | tail -1)

  if echo "$lastlog_output" | grep -q "Never logged in"; then
    warn "$username — Never logged in"
  else
    last_time=$(echo "$lastlog_output" | awk '{$1=""; print $0}' | xargs)
    ok "$username — Last login: $last_time"
  fi
done < /etc/passwd

# ──────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────
header "Summary"
echo -e "  ${YELLOW}Warnings:${RESET} $WARN_COUNT"
echo -e "  ${RED}Alerts:${RESET}   $ALERT_COUNT"
echo ""

if [[ $ALERT_COUNT -gt 0 ]]; then
  alert "Action required — $ALERT_COUNT critical issue(s) found."
  exit 2
elif [[ $WARN_COUNT -gt 0 ]]; then
  warn "$WARN_COUNT warning(s) found — review recommended."
  exit 1
else
  ok "All checks passed. No issues found."
  exit 0
fi
