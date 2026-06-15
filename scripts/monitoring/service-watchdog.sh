#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  service-watchdog.sh — Monitor services, restart on failure, alert if down
#  Run as: root / sudo
# ─────────────────────────────────────────────

# ── Defaults ──────────────────────────────────
SERVICES=()
CONFIG_FILE=""
ALERT_EMAIL=""
LOG_FILE="/var/log/service-watchdog.log"
OUTPUT_FILE=""
RESTART_WAIT=3    # seconds to wait after restart before re-checking
QUIET=false
ALERT_COUNT=0
WARN_COUNT=0
CHECKED=0
RESTARTED=0
RECOVERED=0
FAILED_SERVICES=()

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

# ── Alert helper ───────────────────────────────
send_alert() {
  local subject="$1"
  local body="$2"
  alert "$subject: $body"
  log_entry "ALERT: $subject — $body"
  if [[ -n "$ALERT_EMAIL" ]] && command -v mailx &>/dev/null; then
    echo "$body" | mailx -s "[watchdog-alert] $subject" "$ALERT_EMAIL" 2>/dev/null || true
    log "Alert email sent to: $ALERT_EMAIL"
  elif [[ -n "$ALERT_EMAIL" ]]; then
    warn "mailx not found — alert email could not be sent to $ALERT_EMAIL"
  fi
}

# ── Usage ─────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS] [SERVICE...]

Monitor systemd services. Restarts any that are inactive and alerts if they
fail to recover. Designed to run every 5 minutes via cron.

Services can be passed as arguments or read from a config file (one per line).

Options:
  -c, --config FILE    Read service list from file (one service per line)
  -e, --email  ADDR    Alert email address when a service fails to recover
  -l, --log    FILE    Log file path (default: /var/log/service-watchdog.log)
  -w, --wait   SECS    Seconds to wait after restart before re-checking (default: 3)
  -o, --output FILE    Write report to file
  -q, --quiet          No color output (cron-safe)
  -h, --help           Show this help message

Examples:
  sudo $(basename "$0") nginx mysql sshd
  sudo $(basename "$0") --config /etc/watchdog-services.conf --email ops@example.com
  sudo $(basename "$0") nginx --log /var/log/watchdog.log --quiet

Cron example (every 5 minutes):
  */5 * * * * root $(basename "$0") nginx mysql sshd --quiet --email ops@example.com

Config file format (one service per line, # for comments):
  # critical services
  nginx
  mysql
  sshd
EOF
}

# ── Argument parsing ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--config)  CONFIG_FILE="$2"; shift 2 ;;
    -e|--email)   ALERT_EMAIL="$2"; shift 2 ;;
    -l|--log)     LOG_FILE="$2"; shift 2 ;;
    -w|--wait)    RESTART_WAIT="$2"; shift 2 ;;
    -o|--output)  OUTPUT_FILE="$2"; shift 2 ;;
    -q|--quiet)   QUIET=true; RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''; shift ;;
    -h|--help)    usage; exit 0 ;;
    -*)           echo "Unknown option: $1"; usage; exit 1 ;;
    *)            SERVICES+=("$1"); shift ;;    # positional args are service names
  esac
done

# ── Root check ────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

# ── Preflight: validate required commands ─────
REQUIRED_CMDS=(systemctl)
for cmd in "${REQUIRED_CMDS[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "Error: required command '$cmd' not found — is this a systemd system?" >&2
    exit 1
  fi
done

# ── Load services from config file if provided ─
if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Error: config file not found: $CONFIG_FILE" >&2
    exit 1
  fi
  # Strip blank lines and # comments
  while IFS= read -r line; do
    line="${line%%#*}"    # strip inline comments
    line="${line//[[:space:]]/}"  # strip whitespace
    [[ -n "$line" ]] && SERVICES+=("$line")
  done < "$CONFIG_FILE"
fi

# ── Require at least one service ──────────────
if [[ ${#SERVICES[@]} -eq 0 ]]; then
  echo "Error: no services specified. Pass service names as arguments or use --config." >&2
  usage
  exit 1
fi

# ── Redirect to file if --output is set ───────
if [[ -n "$OUTPUT_FILE" ]]; then
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

echo -e "\n${BOLD}Service Watchdog — $(hostname) — $(date)${RESET}"
log_entry "START  services=${SERVICES[*]}"

# ──────────────────────────────────────────────
#  Section 1: Service List
# ──────────────────────────────────────────────
header "Section 1 — Service List"
log "Monitoring ${#SERVICES[@]} service(s): ${SERVICES[*]}"

# ──────────────────────────────────────────────
#  Sections 2–5: Status Check, Restart, Verify, Alert
#  Processed per-service in a single loop.
# ──────────────────────────────────────────────
header "Section 2 — Status Checks & Restart Attempts"

for svc in "${SERVICES[@]}"; do
  (( CHECKED++ )) || true

  # ── Section 2: Status check ──────────────
  if systemctl is-active --quiet "$svc" 2>/dev/null; then
    ok "$svc — active"
    log_entry "OK      $svc is active"
    continue
  fi

  # ── Service is not active ────────────────
  status=$(systemctl is-active "$svc" 2>/dev/null || true)
  warn "$svc — $status"
  log_entry "DOWN    $svc status=$status — attempting restart"

  # ── Section 3: Restart attempt ──────────
  log "Restarting $svc..."
  if systemctl restart "$svc" 2>/dev/null; then
    (( RESTARTED++ )) || true
    log_entry "RESTART $svc — restart command issued"

    # Wait before re-checking to give the service time to initialize
    sleep "$RESTART_WAIT"

    # ── Section 3: Post-restart verify ──────
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
      ok "$svc — RECOVERED after restart"
      log_entry "RECOVER $svc — now active after restart"
      (( RECOVERED++ )) || true
    else
      # ── Section 5: Alert ──────────────────
      post_status=$(systemctl is-active "$svc" 2>/dev/null || true)
      send_alert "Service DOWN after restart" "$svc is still $post_status after restart attempt"
      FAILED_SERVICES+=("$svc")
      log_entry "FAILED  $svc — still $post_status after restart"
    fi
  else
    # restart command itself failed (unit may be masked or unrecognized)
    send_alert "Restart command failed" "systemctl restart $svc returned non-zero"
    FAILED_SERVICES+=("$svc")
    log_entry "FAILED  $svc — restart command failed"
  fi
done

# ──────────────────────────────────────────────
#  Section 6: Summary
# ──────────────────────────────────────────────
header "Section 6 — Summary"

echo -e "  ${BOLD}Services checked:${RESET}    $CHECKED"
echo -e "  ${CYAN}Restart attempts:${RESET}    $RESTARTED"
echo -e "  ${GREEN}Recovered:${RESET}           $RECOVERED"
echo -e "  ${RED}Failed (still down):${RESET} ${#FAILED_SERVICES[@]}"
echo -e "  ${YELLOW}Warnings:${RESET}            $WARN_COUNT"
echo -e "  ${RED}Alerts:${RESET}              $ALERT_COUNT"
echo ""

if [[ ${#FAILED_SERVICES[@]} -gt 0 ]]; then
  failed_str="${FAILED_SERVICES[*]}"
  log_entry "SUMMARY checked=$CHECKED restarted=$RESTARTED recovered=$RECOVERED failed=$failed_str"
  alert "One or more services could not be recovered: $failed_str"
  exit 2
elif [[ $RESTARTED -gt 0 ]]; then
  log_entry "SUMMARY checked=$CHECKED restarted=$RESTARTED recovered=$RECOVERED failed=none"
  warn "$RESTARTED service(s) were restarted and recovered. Review logs for root cause."
  exit 1
else
  log_entry "SUMMARY checked=$CHECKED all_active=true"
  ok "All $CHECKED service(s) are active. No action taken."
  exit 0
fi
