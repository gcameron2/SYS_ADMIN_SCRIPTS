#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  system-health-report.sh — Snapshot current system health
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

Snapshot current system health: CPU load, memory, disk, failed services,
top processes, and uptime. Safe to run on-demand or via daily cron.

Options:
  -o, --output FILE   Write report to file
  -q, --quiet         No color output (cron-safe)
  -h, --help          Show this help message

Examples:
  sudo $(basename "$0")
  sudo $(basename "$0") --output /var/log/health-report.txt
  sudo $(basename "$0") --quiet --output /tmp/health.txt

Cron example (daily at 07:00):
  0 7 * * * root $(basename "$0") --quiet --output /var/log/health-report.txt
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
REQUIRED_CMDS=(awk grep free df ps uptime who nproc)
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

echo -e "\n${BOLD}System Health Report — $(hostname) — $(date)${RESET}"

# ──────────────────────────────────────────────
#  Section 1: CPU Load Averages
#  Load > core count means the run queue is saturated.
# ──────────────────────────────────────────────
header "Section 1 — CPU Load"

cpu_cores=$(nproc)
read -r load1 load5 load15 _ < /proc/loadavg
log "CPU cores: $cpu_cores"
log "Load averages: 1m=$load1  5m=$load5  15m=$load15"

# awk handles float comparisons that bash can't do natively
if awk -v l="$load1" -v c="$cpu_cores" 'BEGIN { exit !(l > c) }'; then
  alert "1-minute load ($load1) exceeds core count ($cpu_cores) — system is overloaded"
elif awk -v l="$load5" -v c="$cpu_cores" 'BEGIN { exit !(l > c) }'; then
  warn "5-minute load ($load5) exceeds core count ($cpu_cores) — sustained pressure"
elif awk -v l="$load15" -v c="$cpu_cores" 'BEGIN { exit !(l > c) }'; then
  warn "15-minute load ($load15) exceeds core count ($cpu_cores) — recovering from load spike"
else
  ok "Load averages are within normal range (cores: $cpu_cores)"
fi

# ──────────────────────────────────────────────
#  Section 2: Memory Usage
# ──────────────────────────────────────────────
header "Section 2 — Memory Usage"

mem_total=$(free -m | awk 'NR==2 {print $2}')
mem_used=$(free  -m | awk 'NR==2 {print $3}')
mem_free=$(free  -m | awk 'NR==2 {print $4}')
mem_avail=$(free -m | awk 'NR==2 {print $7}')
mem_pct=$(awk -v u="$mem_used" -v t="$mem_total" 'BEGIN { printf "%.0f", (u / t) * 100 }')

swap_total=$(free -m | awk 'NR==3 {print $2}')
swap_used=$(free  -m | awk 'NR==3 {print $3}')

log "RAM  — Total: ${mem_total}MB  Used: ${mem_used}MB  Free: ${mem_free}MB  Available: ${mem_avail}MB  (${mem_pct}% used)"

if [[ $swap_total -gt 0 ]]; then
  swap_pct=$(awk -v u="$swap_used" -v t="$swap_total" 'BEGIN { printf "%.0f", (u / t) * 100 }')
  log "Swap — Total: ${swap_total}MB  Used: ${swap_used}MB  (${swap_pct}% used)"
  # Heavy swap use signals the kernel is compensating for RAM exhaustion
  if [[ $swap_pct -gt 50 ]]; then
    warn "Swap usage is high (${swap_pct}%) — memory pressure may be degrading performance"
  else
    ok "Swap usage is normal (${swap_pct}%)"
  fi
else
  log "Swap — not configured"
fi

if [[ $mem_pct -ge 90 ]]; then
  alert "Memory usage critical: ${mem_pct}% used"
elif [[ $mem_pct -ge 75 ]]; then
  warn "Memory usage elevated: ${mem_pct}% used"
else
  ok "Memory usage is normal: ${mem_pct}% used"
fi

# ──────────────────────────────────────────────
#  Section 3: Disk Usage
#  Warn at 80%, alert at 90%. Skip pseudo-filesystems.
# ──────────────────────────────────────────────
header "Section 3 — Disk Usage"

DISK_WARN=80
DISK_ALERT=90
disk_issues=0

while IFS= read -r line; do
  filesystem=$(echo "$line" | awk '{print $1}')
  usage_pct=$(echo "$line"  | awk '{print $5}' | tr -d '%')
  mountpoint=$(echo "$line" | awk '{print $6}')
  size=$(echo "$line"       | awk '{print $2}')
  used=$(echo "$line"       | awk '{print $3}')
  avail=$(echo "$line"      | awk '{print $4}')

  # Skip pseudo-filesystems — they don't reflect real storage
  case "$filesystem" in
    tmpfs|devtmpfs|udev|none|overlay|shm|cgroupfs|cgroup*) continue ;;
  esac

  if [[ $usage_pct -ge $DISK_ALERT ]]; then
    alert "${mountpoint} (${filesystem}) is ${usage_pct}% full — ${avail} free of ${size}"
    (( disk_issues++ )) || true
  elif [[ $usage_pct -ge $DISK_WARN ]]; then
    warn "${mountpoint} (${filesystem}) is ${usage_pct}% full — ${avail} free of ${size}"
    (( disk_issues++ )) || true
  else
    ok "${mountpoint} — ${usage_pct}% used, ${avail} free of ${size}"
  fi
done < <(df -h | tail -n +2)

[[ $disk_issues -eq 0 ]] && ok "All filesystems are within normal thresholds."

# ──────────────────────────────────────────────
#  Section 4: Failed systemd Services
# ──────────────────────────────────────────────
header "Section 4 — Failed systemd Services"

if ! command -v systemctl &>/dev/null; then
  log "systemctl not found — skipping (non-systemd system)"
else
  # --no-legend strips the header/footer lines so we get only service names
  failed_services=$(systemctl --failed --no-legend 2>/dev/null | awk '{print $1}' || true)

  if [[ -z "$failed_services" ]]; then
    ok "No failed systemd services."
  else
    while IFS= read -r svc; do
      [[ -z "$svc" ]] && continue
      alert "Service '$svc' is in a FAILED state"
    done <<< "$failed_services"
  fi
fi

# ──────────────────────────────────────────────
#  Section 5: Top 5 Processes by Memory
# ──────────────────────────────────────────────
header "Section 5 — Top 5 Processes by Memory"

printf "  %-8s %-40s %s\n" "PID" "PROCESS" "%MEM"
printf "  %-8s %-40s %s\n" "───────" "───────────────────────────────────────" "────"
ps aux --sort=-%mem 2>/dev/null | awk 'NR>1 && NR<=6 { printf "  %-8s %-40s %s\n", $2, $11, $4 }'

# ──────────────────────────────────────────────
#  Section 6: Top 5 Processes by CPU
# ──────────────────────────────────────────────
header "Section 6 — Top 5 Processes by CPU"

printf "  %-8s %-40s %s\n" "PID" "PROCESS" "%CPU"
printf "  %-8s %-40s %s\n" "───────" "───────────────────────────────────────" "────"
ps aux --sort=-%cpu 2>/dev/null | awk 'NR>1 && NR<=6 { printf "  %-8s %-40s %s\n", $2, $11, $3 }'

# ──────────────────────────────────────────────
#  Section 7: Uptime & Last Reboot
# ──────────────────────────────────────────────
header "Section 7 — Uptime & Last Reboot"

uptime_str=$(uptime -p 2>/dev/null || uptime)
log "Uptime: $uptime_str"

# who -b is the most portable way to get last boot time across distros
last_reboot=$(who -b 2>/dev/null | awk '{print $3, $4}' || true)
if [[ -n "$last_reboot" ]]; then
  log "Last reboot: $last_reboot"
else
  log "Last reboot: unavailable"
fi

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
  ok "System health looks good. No issues found."
  exit 0
fi
