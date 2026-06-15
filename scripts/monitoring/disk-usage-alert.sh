#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  disk-usage-alert.sh — Filesystem and inode usage check with top-dir scan
#  Run as: root / sudo
# ─────────────────────────────────────────────

# ── Defaults ──────────────────────────────────
SCAN_PATH="/"
WARN_PCT=80
ALERT_PCT=90
ALERT_EMAIL=""
LOG_FILE="/var/log/disk-usage-alert.log"
OUTPUT_FILE=""
TOP_N=10
QUIET=false
ALERT_COUNT=0
WARN_COUNT=0
FLAGGED_FS=()      # filesystems that crossed ALERT_PCT (triggers email)

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

Check all mounted filesystems for space and inode usage. Warn at a
configurable threshold, alert at a higher one, and scan a directory for
the top space consumers to identify the culprit.

Options:
  -p, --path   DIR     Directory to scan for top usage (default: /)
  -w, --warn   PCT     Warn threshold percentage (default: 80)
  -a, --alert  PCT     Alert threshold percentage (default: 90)
  -n, --top    N       Number of top directories to show (default: 10)
  -e, --email  ADDR    Send alert email when threshold is exceeded (requires mailx)
  -l, --log    FILE    Log file path (default: /var/log/disk-usage-alert.log)
  -o, --output FILE    Write report to file
  -q, --quiet          No color output (cron-safe)
  -h, --help           Show this help message

Examples:
  sudo $(basename "$0")
  sudo $(basename "$0") --warn 70 --alert 85 --path /var
  sudo $(basename "$0") --email ops@example.com --output /var/log/disk-report.txt

Cron example (daily at 06:00):
  0 6 * * * root $(basename "$0") --email ops@example.com --quiet
EOF
}

# ── Argument parsing ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--path)    SCAN_PATH="$2"; shift 2 ;;
    -w|--warn)    WARN_PCT="$2"; shift 2 ;;
    -a|--alert)   ALERT_PCT="$2"; shift 2 ;;
    -n|--top)     TOP_N="$2"; shift 2 ;;
    -e|--email)   ALERT_EMAIL="$2"; shift 2 ;;
    -l|--log)     LOG_FILE="$2"; shift 2 ;;
    -o|--output)  OUTPUT_FILE="$2"; shift 2 ;;
    -q|--quiet)   QUIET=true; RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Root check ────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

# ── Validate thresholds ───────────────────────
if [[ $WARN_PCT -ge $ALERT_PCT ]]; then
  echo "Error: --warn ($WARN_PCT) must be less than --alert ($ALERT_PCT)." >&2
  exit 1
fi

# ── Preflight: validate required commands ─────
REQUIRED_CMDS=(df du awk sort)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '$cmd' not found." >&2
    exit 1
  fi
done

# ── Redirect to file if --output is set ───────
if [[ -n "$OUTPUT_FILE" ]]; then
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

echo -e "\n${BOLD}Disk Usage Report — $(hostname) — $(date)${RESET}"
echo -e "${BOLD}  Thresholds: warn=${WARN_PCT}%  alert=${ALERT_PCT}%${RESET}"
log_entry "START  warn=${WARN_PCT}%  alert=${ALERT_PCT}%  scan=$SCAN_PATH"

# ──────────────────────────────────────────────
#  Section 1 & 2: Filesystem Space Usage
#  -P (POSIX) prevents long filesystem names from wrapping to the next line.
# ──────────────────────────────────────────────
header "Section 1 — Filesystem Space Usage (warn: ${WARN_PCT}%  alert: ${ALERT_PCT}%)"

space_issues=0

while IFS= read -r line; do
  filesystem=$(echo "$line" | awk '{print $1}')
  size=$(echo "$line"       | awk '{print $2}')
  used=$(echo "$line"       | awk '{print $3}')
  avail=$(echo "$line"      | awk '{print $4}')
  pct=$(echo "$line"        | awk '{print $5}' | tr -d '%')
  mountpoint=$(echo "$line" | awk '{print $6}')

  # Skip pseudo-filesystems — they consume no real disk
  case "$filesystem" in
    tmpfs|devtmpfs|udev|none|overlay|shm|cgroupfs|cgroup*|squashfs*) continue ;;
  esac
  # Also skip if pct is not a number (headers or unusual entries)
  [[ "$pct" =~ ^[0-9]+$ ]] || continue

  if [[ $pct -ge $ALERT_PCT ]]; then
    alert "${mountpoint} (${filesystem}) — ${pct}% used, ${avail} free of ${size}"
    FLAGGED_FS+=("${mountpoint}=${pct}%")
    log_entry "ALERT  space  ${mountpoint} ${pct}% used"
    (( space_issues++ )) || true
  elif [[ $pct -ge $WARN_PCT ]]; then
    warn "${mountpoint} (${filesystem}) — ${pct}% used, ${avail} free of ${size}"
    log_entry "WARN   space  ${mountpoint} ${pct}% used"
    (( space_issues++ )) || true
  else
    ok "${mountpoint} — ${pct}% used, ${avail} free of ${size}"
  fi
done < <(df -hP | tail -n +2)

[[ $space_issues -eq 0 ]] && ok "All filesystems are below ${WARN_PCT}% usage."

# ──────────────────────────────────────────────
#  Section 3: Top Directory Sizes
#  --max-depth=1 scans only direct children — fast enough for any path
#  including /. A full recursive du on / can take minutes on busy servers.
# ──────────────────────────────────────────────
header "Section 3 — Top ${TOP_N} Directories by Size under: ${SCAN_PATH}"

if [[ ! -d "$SCAN_PATH" ]]; then
  warn "Scan path does not exist: $SCAN_PATH — skipping top-directory scan"
else
  log "Scanning $SCAN_PATH (depth 1)..."
  printf "  %-12s %s\n" "SIZE" "PATH"
  printf "  %-12s %s\n" "────────────" "──────────────────────────────────────────"

  # 2>/dev/null suppresses "permission denied" noise on directories we can't read
  du -h --max-depth=1 "$SCAN_PATH" 2>/dev/null \
    | sort -rh \
    | tail -n +2 \
    | head -n "$TOP_N" \
    | awk '{printf "  %-12s %s\n", $1, $2}'
fi

# ──────────────────────────────────────────────
#  Section 4: Inode Usage
#  A filesystem can run out of inodes before running out of space,
#  which prevents new files from being created even when df -h shows free space.
# ──────────────────────────────────────────────
header "Section 4 — Inode Usage (warn: ${WARN_PCT}%  alert: ${ALERT_PCT}%)"

inode_issues=0

while IFS= read -r line; do
  filesystem=$(echo "$line" | awk '{print $1}')
  inodes=$(echo "$line"     | awk '{print $2}')
  iused=$(echo "$line"      | awk '{print $3}')
  ifree=$(echo "$line"      | awk '{print $4}')
  pct=$(echo "$line"        | awk '{print $5}' | tr -d '%')
  mountpoint=$(echo "$line" | awk '{print $6}')

  case "$filesystem" in
    tmpfs|devtmpfs|udev|none|overlay|shm|cgroupfs|cgroup*|squashfs*) continue ;;
  esac
  [[ "$pct" =~ ^[0-9]+$ ]] || continue

  # Some filesystems report "-" for inode counts (e.g. fat32, some network FS)
  [[ "$inodes" == "-" ]] && continue

  if [[ $pct -ge $ALERT_PCT ]]; then
    alert "${mountpoint} inodes — ${pct}% used (${iused}/${inodes}, ${ifree} free)"
    FLAGGED_FS+=("${mountpoint}-inodes=${pct}%")
    log_entry "ALERT  inodes ${mountpoint} ${pct}% used"
    (( inode_issues++ )) || true
  elif [[ $pct -ge $WARN_PCT ]]; then
    warn "${mountpoint} inodes — ${pct}% used (${iused}/${inodes}, ${ifree} free)"
    log_entry "WARN   inodes ${mountpoint} ${pct}% used"
    (( inode_issues++ )) || true
  else
    ok "${mountpoint} inodes — ${pct}% used (${ifree} free)"
  fi
done < <(df -iP | tail -n +2)

[[ $inode_issues -eq 0 ]] && ok "All filesystems are below ${WARN_PCT}% inode usage."

# ──────────────────────────────────────────────
#  Section 5: Alert
#  One consolidated email covers all flagged filesystems — avoids alert spam
#  when multiple mounts breach the threshold at the same time.
# ──────────────────────────────────────────────
header "Section 5 — Alert"

if [[ ${#FLAGGED_FS[@]} -gt 0 ]]; then
  flagged_str="${FLAGGED_FS[*]}"
  log_entry "FLAGGED $flagged_str"

  if [[ -n "$ALERT_EMAIL" ]]; then
    if command -v mailx &>/dev/null; then
      {
        echo "Host: $(hostname)"
        echo "Date: $(date)"
        echo ""
        echo "The following filesystems exceeded the ${ALERT_PCT}% alert threshold:"
        printf '  %s\n' "${FLAGGED_FS[@]}"
        echo ""
        echo "Run: df -h && df -i  for current state."
      } | mailx -s "[disk-alert] $(hostname) — ${#FLAGGED_FS[@]} filesystem(s) critical" \
            "$ALERT_EMAIL" 2>/dev/null || warn "Failed to send alert email"
      log "Alert email sent to: $ALERT_EMAIL"
    else
      warn "mailx not found — alert email could not be sent to $ALERT_EMAIL"
    fi
  else
    log "No --email configured — skipping email alert"
  fi
else
  ok "No filesystems exceeded the ${ALERT_PCT}% alert threshold — no email sent"
fi

# ──────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────
header "Summary"
echo -e "  ${YELLOW}Warnings:${RESET}           $WARN_COUNT"
echo -e "  ${RED}Alerts:${RESET}             $ALERT_COUNT"
echo -e "  ${RED}Critical filesystems:${RESET} ${#FLAGGED_FS[@]}"
echo ""

if [[ $ALERT_COUNT -gt 0 ]]; then
  log_entry "RESULT alerts=$ALERT_COUNT warnings=$WARN_COUNT flagged=${flagged_str:-none}"
  alert "$ALERT_COUNT critical issue(s) found — immediate attention required."
  exit 2
elif [[ $WARN_COUNT -gt 0 ]]; then
  log_entry "RESULT alerts=0 warnings=$WARN_COUNT"
  warn "$WARN_COUNT warning(s) — monitor closely."
  exit 1
else
  log_entry "RESULT all_clean=true"
  ok "All checks passed. No disk issues found."
  exit 0
fi
