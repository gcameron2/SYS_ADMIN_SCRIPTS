#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  backup-and-verify.sh — Rsync backup with checksum verification and retention
#  Run as: root / sudo
# ─────────────────────────────────────────────

# ── Defaults ──────────────────────────────────
SOURCE=""
BACKUP_ROOT=""
RETAIN_DAYS=30
ALERT_EMAIL=""
LOG_FILE="/var/log/backup-and-verify.log"
OUTPUT_FILE=""
SPOT_SAMPLE=5
QUIET=false
ALERT_COUNT=0
WARN_COUNT=0
BACKUP_STATUS="SUCCESS"
FAIL_REASONS=()
TIMESTAMP=$(date +%Y-%m-%d_%H-%M-%S)
BACKUP_DIR=""

# These are set in Section 3; initialize so set -u doesn't fire if we skip it
bak_count="N/A"
bak_size_hr="N/A"

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
# Logs the event and emails via mailx when an address is configured
send_alert() {
  local subject="$1"
  local body="$2"
  alert "$subject: $body"
  log_entry "ALERT: $subject — $body"
  if [[ -n "$ALERT_EMAIL" ]] && command -v mailx &>/dev/null; then
    echo "$body" | mailx -s "[backup-alert] $subject" "$ALERT_EMAIL" 2>/dev/null || true
    log "Alert email sent to: $ALERT_EMAIL"
  elif [[ -n "$ALERT_EMAIL" ]]; then
    warn "mailx not found — alert email could not be sent to $ALERT_EMAIL"
  fi
}

# ── Usage ─────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") -s SOURCE -d DEST [OPTIONS]

Rsync a source directory to a timestamped backup under DEST, verify file
count and total size, spot-check checksums, apply a retention policy, and
alert on any failure.

Options:
  -s, --source DIR     Source directory to back up (required)
  -d, --dest   DIR     Backup root directory (required)
                       Each run creates DEST/backup_TIMESTAMP/
  -r, --retain DAYS    Delete backups older than N days (default: 30)
  -e, --email  ADDR    Alert email address on failure (requires mailx)
  -l, --log    FILE    Log file path (default: /var/log/backup-and-verify.log)
  -o, --output FILE    Write report to file
  -q, --quiet          No color output (cron-safe)
  -h, --help           Show this help message

Examples:
  sudo $(basename "$0") -s /var/www -d /mnt/nas/backups
  sudo $(basename "$0") -s /home -d /mnt/nas/backups --retain 14 --email ops@example.com
  sudo $(basename "$0") -s /etc  -d /backups --quiet --output /var/log/backup-report.txt

Cron example (nightly at 02:00):
  0 2 * * * root $(basename "$0") -s /var/www -d /mnt/nas/backups -e ops@example.com --quiet
EOF
}

# ── Argument parsing ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s|--source)  SOURCE="$2"; shift 2 ;;
    -d|--dest)    BACKUP_ROOT="$2"; shift 2 ;;
    -r|--retain)  RETAIN_DAYS="$2"; shift 2 ;;
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

# ── Required argument check ───────────────────
if [[ -z "$SOURCE" || -z "$BACKUP_ROOT" ]]; then
  echo "Error: --source and --dest are required." >&2
  usage
  exit 1
fi

# Normalize: strip trailing slashes so path joins are predictable
SOURCE="${SOURCE%/}"
BACKUP_ROOT="${BACKUP_ROOT%/}"

# ── Preflight: validate required commands ─────
REQUIRED_CMDS=(rsync find du df sha256sum awk)
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

BACKUP_DIR="${BACKUP_ROOT}/backup_${TIMESTAMP}"

echo -e "\n${BOLD}Backup Report — $(date)${RESET}"
echo -e "${BOLD}  Source: ${SOURCE}${RESET}"
echo -e "${BOLD}  Dest:   ${BACKUP_DIR}${RESET}"

log_entry "START  source=$SOURCE  dest=$BACKUP_DIR  retain=${RETAIN_DAYS}d"

# ──────────────────────────────────────────────
#  Section 1: Pre-backup Checks
#  Abort immediately if any of these fail — no point running rsync blind.
# ──────────────────────────────────────────────
header "Section 1 — Pre-backup Checks"

PREFLIGHT_OK=true

if [[ ! -d "$SOURCE" ]]; then
  send_alert "Preflight failed" "Source directory does not exist: $SOURCE"
  PREFLIGHT_OK=false
else
  ok "Source exists: $SOURCE"
fi

if [[ "$PREFLIGHT_OK" == true ]]; then
  if ! mkdir -p "$BACKUP_ROOT" 2>/dev/null; then
    send_alert "Preflight failed" "Cannot create or access backup root: $BACKUP_ROOT"
    PREFLIGHT_OK=false
  elif [[ ! -w "$BACKUP_ROOT" ]]; then
    send_alert "Preflight failed" "Backup root is not writable: $BACKUP_ROOT"
    PREFLIGHT_OK=false
  else
    ok "Backup root is writable: $BACKUP_ROOT"
  fi
fi

# Ensure source fits on destination before starting a doomed rsync
if [[ "$PREFLIGHT_OK" == true ]]; then
  src_bytes=$(du -sb "$SOURCE" 2>/dev/null | awk '{print $1}')
  dest_avail_bytes=$(df -B1 "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')
  src_hr=$(du -sh "$SOURCE" 2>/dev/null | awk '{print $1}')
  dest_avail_hr=$(df -h "$BACKUP_ROOT" 2>/dev/null | awk 'NR==2 {print $4}')

  log "Source size:      $src_hr"
  log "Destination free: $dest_avail_hr"

  if [[ $src_bytes -gt $dest_avail_bytes ]]; then
    send_alert "Preflight failed" "Insufficient space: source=$src_hr, available=$dest_avail_hr"
    PREFLIGHT_OK=false
  else
    ok "Sufficient space available ($dest_avail_hr free)"
  fi
fi

if [[ "$PREFLIGHT_OK" == false ]]; then
  log_entry "FAILURE preflight checks failed"
  exit 2
fi

# ──────────────────────────────────────────────
#  Section 2: Backup (rsync)
# ──────────────────────────────────────────────
header "Section 2 — Backup"

log "Starting rsync..."
mkdir -p "$BACKUP_DIR"

# -a  = archive: preserves permissions, timestamps, symlinks, owner, group
# --stats prints a transfer summary without per-file noise
# Trailing slash on SOURCE copies its *contents*, not the directory itself
if rsync -a --stats "${SOURCE}/" "${BACKUP_DIR}/"; then
  ok "rsync completed successfully"
else
  RSYNC_EXIT=$?
  send_alert "Backup failed" "rsync exited $RSYNC_EXIT for source: $SOURCE"
  BACKUP_STATUS="FAILURE"
  FAIL_REASONS+=("rsync failed (exit $RSYNC_EXIT)")
fi

# ──────────────────────────────────────────────
#  Section 3: Verification — file count and total size
# ──────────────────────────────────────────────
header "Section 3 — Verification"

if [[ "$BACKUP_STATUS" == "FAILURE" ]]; then
  warn "Skipping verification — backup step failed"
else
  src_count=$(find "$SOURCE"     -type f | wc -l)
  bak_count=$(find "$BACKUP_DIR" -type f | wc -l)

  src_size=$(du -sb "$SOURCE"     | awk '{print $1}')
  bak_size=$(du -sb "$BACKUP_DIR" | awk '{print $1}')
  src_size_hr=$(du -sh "$SOURCE"     | awk '{print $1}')
  bak_size_hr=$(du -sh "$BACKUP_DIR" | awk '{print $1}')

  log "Source:  $src_count files, $src_size_hr"
  log "Backup:  $bak_count files, $bak_size_hr"

  if [[ $src_count -ne $bak_count ]]; then
    send_alert "Verification failed" "File count mismatch: source=$src_count backup=$bak_count"
    BACKUP_STATUS="FAILURE"
    FAIL_REASONS+=("file count mismatch (source=$src_count backup=$bak_count)")
  else
    ok "File count matches: $src_count files"
  fi

  if [[ $src_size -ne $bak_size ]]; then
    send_alert "Verification failed" "Size mismatch: source=$src_size_hr backup=$bak_size_hr"
    BACKUP_STATUS="FAILURE"
    FAIL_REASONS+=("size mismatch (source=$src_size_hr backup=$bak_size_hr)")
  else
    ok "Total size matches: $src_size_hr"
  fi
fi

# ──────────────────────────────────────────────
#  Section 4: Checksum Spot-check
#  sha256 a random sample to catch silent corruption rsync wouldn't detect.
# ──────────────────────────────────────────────
header "Section 4 — Checksum Spot-check (sample: $SPOT_SAMPLE files)"

if [[ "$BACKUP_STATUS" == "FAILURE" ]]; then
  warn "Skipping spot-check — prior step failed"
elif ! command -v shuf &>/dev/null; then
  warn "shuf not found — skipping random spot-check (install coreutils)"
else
  # Relative paths so the same path can be checked in both source and backup
  mapfile -t sample_files < <(
    find "$SOURCE" -type f | shuf -n "$SPOT_SAMPLE" | sed "s|^${SOURCE}/||" || true
  )

  if [[ ${#sample_files[@]} -eq 0 ]]; then
    warn "No files found in source for spot-check — source may be empty"
  else
    checksum_failures=0

    for rel_path in "${sample_files[@]}"; do
      [[ -z "$rel_path" ]] && continue
      src_file="${SOURCE}/${rel_path}"
      bak_file="${BACKUP_DIR}/${rel_path}"

      if [[ ! -f "$bak_file" ]]; then
        alert "Spot-check: file missing from backup — $rel_path"
        (( checksum_failures++ )) || true
        continue
      fi

      src_hash=$(sha256sum "$src_file" | awk '{print $1}')
      bak_hash=$(sha256sum "$bak_file" | awk '{print $1}')

      if [[ "$src_hash" != "$bak_hash" ]]; then
        alert "Spot-check: hash mismatch — $rel_path"
        (( checksum_failures++ )) || true
      else
        ok "Checksum OK: $rel_path"
      fi
    done

    if [[ $checksum_failures -gt 0 ]]; then
      send_alert "Spot-check failed" "$checksum_failures file(s) failed integrity check"
      BACKUP_STATUS="FAILURE"
      FAIL_REASONS+=("spot-check: $checksum_failures checksum failure(s)")
    else
      ok "All $SPOT_SAMPLE sampled files passed checksum verification"
    fi
  fi
fi

# ──────────────────────────────────────────────
#  Section 5: Retention Policy
#  Prune backup dirs older than RETAIN_DAYS. -maxdepth 1 prevents
#  descending into the backups themselves and deleting files inside them.
# ──────────────────────────────────────────────
header "Section 5 — Retention Policy (keep: ${RETAIN_DAYS} days)"

expired=$(find "$BACKUP_ROOT" -maxdepth 1 -type d -name "backup_*" \
           -mtime +"$RETAIN_DAYS" 2>/dev/null || true)

if [[ -z "$expired" ]]; then
  ok "No expired backups to remove."
else
  while IFS= read -r old_dir; do
    [[ -z "$old_dir" ]] && continue
    log "Removing expired backup: $(basename "$old_dir")"
    rm -rf "$old_dir"
    log_entry "RETENTION removed $old_dir"
    ok "Removed: $(basename "$old_dir")"
  done <<< "$expired"
fi

# ──────────────────────────────────────────────
#  Section 6: Logging
# ──────────────────────────────────────────────
header "Section 6 — Logging"

if [[ "$BACKUP_STATUS" == "SUCCESS" ]]; then
  log_entry "SUCCESS source=$SOURCE  dest=$BACKUP_DIR  files=$bak_count  size=$bak_size_hr"
else
  if [[ ${#FAIL_REASONS[@]} -gt 0 ]]; then
    reason_str=$(printf '%s; ' "${FAIL_REASONS[@]}")
  else
    reason_str="unknown"
  fi
  log_entry "FAILURE source=$SOURCE  dest=$BACKUP_DIR  reasons=$reason_str"
fi

ok "Result written to: $LOG_FILE"

# ──────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────
header "Summary"
echo -e "  ${BOLD}Status:${RESET}   $BACKUP_STATUS"
echo -e "  ${YELLOW}Warnings:${RESET} $WARN_COUNT"
echo -e "  ${RED}Alerts:${RESET}   $ALERT_COUNT"
echo ""

if [[ "$BACKUP_STATUS" == "FAILURE" ]]; then
  alert "Backup failed — check $LOG_FILE for details."
  exit 2
elif [[ $WARN_COUNT -gt 0 ]]; then
  warn "$WARN_COUNT warning(s) — review recommended."
  exit 1
else
  ok "Backup completed successfully: $BACKUP_DIR"
  exit 0
fi
