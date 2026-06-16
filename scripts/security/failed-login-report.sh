#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  failed-login-report.sh — Parse auth logs for failed SSH attempts, flag and
#  optionally block offending IPs
#  Run as: root / sudo
#
#  NOTE: In AWS environments this maps to CloudTrail + GuardDuty.
#  This script targets on-prem / hybrid servers with local auth logs.
# ─────────────────────────────────────────────

# ── Defaults ──────────────────────────────────
THRESHOLD=10
BLOCK=false
FIREWALL_TOOL=""
LINES=0          # 0 = all lines
OUTPUT_FILE=""
QUIET=false
ALERT_COUNT=0
WARN_COUNT=0
TOTAL_ATTEMPTS=0
TOTAL_IPS=0
FLAGGED_COUNT=0
BLOCKED_COUNT=0

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

Parse SSH auth logs for failed login attempts. Summarize by IP, flag
IPs that exceed a threshold, and optionally block them via ufw.

Auto-detects log source:
  /var/log/auth.log   Debian / Ubuntu
  /var/log/secure     RHEL / CentOS / Fedora
  journalctl          systemd fallback (any distro)

Options:
  -t, --threshold N    Flag IPs with >= N failed attempts (default: 10)
  -b, --block          Block flagged IPs via firewall-cmd (RHEL/CentOS) or ufw (Debian/Ubuntu)
  -l, --lines   N      Only analyze the last N lines of the log (default: all)
  -o, --output  FILE   Write report to file
  -q, --quiet          No color output (cron-safe)
  -h, --help           Show this help message

Examples:
  sudo $(basename "$0")
  sudo $(basename "$0") --threshold 5 --lines 10000
  sudo $(basename "$0") --threshold 20 --block
  sudo $(basename "$0") --quiet --output /var/log/failed-logins.txt
EOF
}

# ── Argument parsing ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -t|--threshold)  THRESHOLD="$2"; shift 2 ;;
    -b|--block)      BLOCK=true; shift ;;
    -l|--lines)      LINES="$2"; shift 2 ;;
    -o|--output)     OUTPUT_FILE="$2"; shift 2 ;;
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
REQUIRED_CMDS=(grep awk sort uniq)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '$cmd' not found." >&2
    exit 1
  fi
done

if [[ "$BLOCK" == true ]]; then
  if command -v firewall-cmd &>/dev/null; then
    FIREWALL_TOOL="firewall-cmd"
  elif command -v ufw &>/dev/null; then
    FIREWALL_TOOL="ufw"
  else
    echo "Error: --block requires firewall-cmd (firewalld) or ufw, but neither was found." >&2
    exit 1
  fi
fi

# ── Redirect to file if --output is set ───────
if [[ -n "$OUTPUT_FILE" ]]; then
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

echo -e "\n${BOLD}Failed Login Report — $(hostname) — $(date)${RESET}"
echo -e "${BOLD}  Threshold: ${THRESHOLD} attempts  Block: ${BLOCK}${RESET}"

# ──────────────────────────────────────────────
#  Section 1: Log Source Detection
# ──────────────────────────────────────────────
header "Section 1 — Log Source Detection"

LOG_SOURCE=""
LOG_LABEL=""

if [[ -f /var/log/auth.log ]]; then
  LOG_SOURCE="file"
  LOG_FILE_PATH="/var/log/auth.log"
  LOG_LABEL="/var/log/auth.log (Debian/Ubuntu)"
elif [[ -f /var/log/secure ]]; then
  LOG_SOURCE="file"
  LOG_FILE_PATH="/var/log/secure"
  LOG_LABEL="/var/log/secure (RHEL/CentOS/Fedora)"
elif command -v journalctl &>/dev/null; then
  LOG_SOURCE="journalctl"
  LOG_LABEL="journalctl -u sshd (systemd)"
else
  alert "No auth log source found — checked /var/log/auth.log, /var/log/secure, and journalctl"
  exit 2
fi

ok "Log source: $LOG_LABEL"
[[ $LINES -gt 0 ]] && log "Analyzing last $LINES lines only"

# ──────────────────────────────────────────────
#  Section 2: Failed Attempt Extraction
#  Both patterns end with "from <ip> port <N>" so we extract the IP
#  by grepping for the word "from" followed by a dotted-quad address.
# ──────────────────────────────────────────────
header "Section 2 — Extracting Failed Login Attempts"

# Pull raw log data into a variable
raw_log=""
if [[ "$LOG_SOURCE" == "file" ]]; then
  if [[ $LINES -gt 0 ]]; then
    raw_log=$(tail -n "$LINES" "$LOG_FILE_PATH" 2>/dev/null || true)
  else
    raw_log=$(cat "$LOG_FILE_PATH" 2>/dev/null || true)
  fi
else
  # journalctl: -q suppresses header, --no-pager prevents interactive output
  if [[ $LINES -gt 0 ]]; then
    raw_log=$(journalctl -u sshd -u ssh --no-pager -q 2>/dev/null \
              | tail -n "$LINES" || true)
  else
    raw_log=$(journalctl -u sshd -u ssh --no-pager -q 2>/dev/null || true)
  fi
fi

if [[ -z "$raw_log" ]]; then
  warn "Log source returned no data — log may be empty or rotated"
fi

# Extract only lines matching failed patterns, then pull the IP after "from"
failed_lines=$(echo "$raw_log" \
  | grep -E "(Failed password|Invalid user)" || true)

TOTAL_ATTEMPTS=$(echo "$failed_lines" | grep -c . || true)
log "Total failed attempt lines found: $TOTAL_ATTEMPTS"

if [[ $TOTAL_ATTEMPTS -eq 0 ]]; then
  ok "No failed login attempts found in the selected log range."
  echo -e "\n  ${GREEN}All clear — no failed SSH login attempts detected.${RESET}"
  exit 0
fi

# Extract IPs: both patterns use "from <ip>" so this regex covers both
ip_list=$(echo "$failed_lines" \
  | grep -oE 'from [0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' \
  | awk '{print $2}' || true)

# Count per IP, sorted descending
ip_counts=$(echo "$ip_list" | sort | uniq -c | sort -rn || true)
TOTAL_IPS=$(echo "$ip_counts" | grep -c . || true)

log "Unique source IPs:     $TOTAL_IPS"

# ──────────────────────────────────────────────
#  Section 3 & 4: IP Summary Table with Threshold Flagging
# ──────────────────────────────────────────────
header "Section 3 — IP Summary (threshold: ${THRESHOLD} attempts)"

printf "\n  %-10s  %-20s  %s\n" "ATTEMPTS" "IP ADDRESS" "STATUS"
printf "  %-10s  %-20s  %s\n"  "─────────" "───────────────────" "──────────────"

# Collect rows for flagged IPs so we can block them after the table
FLAGGED_IPS=()

while read -r count ip; do
  [[ -z "${count:-}" || -z "${ip:-}" ]] && continue
  (( TOTAL_IPS++ )) || true

  if [[ $count -ge $THRESHOLD ]]; then
    status="${YELLOW}FLAGGED${RESET}"
    FLAGGED_IPS+=("$ip")
    (( FLAGGED_COUNT++ )) || true
  else
    status="${GREEN}OK${RESET}"
  fi

  printf "  %-10s  %-20s  " "$count" "$ip"
  echo -e "$status"
done <<< "$ip_counts"

echo ""

# ──────────────────────────────────────────────
#  Section 5: Optional Blocking
#  Only runs when --block is passed. Checks each flagged IP and adds
#  a ufw deny rule if one doesn't already exist.
# ──────────────────────────────────────────────
header "Section 5 — Blocking"

if [[ "$BLOCK" == false ]]; then
  log "Skipping — pass --block to enable automatic IP blocking via firewall-cmd or ufw"
elif [[ ${#FLAGGED_IPS[@]} -eq 0 ]]; then
  ok "No flagged IPs to block."
elif [[ "$FIREWALL_TOOL" == "firewall-cmd" ]]; then
  if ! firewall-cmd --state &>/dev/null; then
    warn "firewalld is not running — rules will be added but not enforced until firewalld starts"
  fi

  for ip in "${FLAGGED_IPS[@]}"; do
    if firewall-cmd --list-rich-rules --permanent 2>/dev/null | grep -q "source address='${ip}'"; then
      ok "Already blocked: $ip"
      continue
    fi

    if firewall-cmd --permanent \
         --add-rich-rule="rule family='ipv4' source address='${ip}' reject" &>/dev/null \
       && firewall-cmd --reload &>/dev/null; then
      ok "Blocked: $ip"
      (( BLOCKED_COUNT++ )) || true
    else
      warn "Failed to block: $ip — check firewall-cmd status manually"
    fi
  done
else
  # ufw fallback (Debian/Ubuntu)
  ufw_status=$(ufw status 2>/dev/null | head -1 || true)
  if ! echo "$ufw_status" | grep -qi "active"; then
    warn "ufw is not active — rules will be added but not enforced until ufw is enabled"
  fi

  for ip in "${FLAGGED_IPS[@]}"; do
    if ufw status 2>/dev/null | grep -q "DENY.*${ip}"; then
      ok "Already blocked: $ip"
      continue
    fi

    if ufw deny from "$ip" to any &>/dev/null; then
      ok "Blocked: $ip"
      (( BLOCKED_COUNT++ )) || true
    else
      warn "Failed to block: $ip — check ufw status manually"
    fi
  done
fi

# ──────────────────────────────────────────────
#  Section 6: Report Summary
# ──────────────────────────────────────────────
header "Section 6 — Summary"

echo -e "  ${BOLD}Log source:${RESET}       $LOG_LABEL"
echo -e "  ${BOLD}Total attempts:${RESET}   $TOTAL_ATTEMPTS"
echo -e "  ${BOLD}Unique IPs:${RESET}       $TOTAL_IPS"
echo -e "  ${YELLOW}Flagged IPs:${RESET}      $FLAGGED_COUNT  (>= ${THRESHOLD} attempts)"
[[ "$BLOCK" == true ]] && \
  echo -e "  ${RED}Blocked IPs:${RESET}      $BLOCKED_COUNT"
echo -e "  ${YELLOW}Warnings:${RESET}         $WARN_COUNT"
echo -e "  ${RED}Alerts:${RESET}           $ALERT_COUNT"
echo ""

if [[ $FLAGGED_COUNT -gt 0 && "$BLOCK" == false ]]; then
  warn "$FLAGGED_COUNT IP(s) exceeded the threshold. Re-run with --block to deny them via firewall-cmd or ufw."
fi

if [[ $ALERT_COUNT -gt 0 ]]; then
  alert "Errors encountered — review output above."
  exit 2
elif [[ $FLAGGED_COUNT -gt 0 ]]; then
  warn "$FLAGGED_COUNT IP(s) flagged."
  exit 1
else
  ok "No IPs exceeded the threshold of $THRESHOLD attempts."
  exit 0
fi
