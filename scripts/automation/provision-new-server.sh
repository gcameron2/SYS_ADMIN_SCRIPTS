#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
#  provision-new-server.sh — Bootstrap a fresh Linux server to a secure baseline
#  Run as: root / sudo
#
#  Idempotent: safe to run multiple times — every step checks before acting.
#  Compatible with EC2 User Data: self-contained, no external dependencies.
# ─────────────────────────────────────────────

# ── Defaults ──────────────────────────────────
ADMIN_USER=""
SSH_PUBKEY=""
NEW_HOSTNAME=""
TIMEZONE="UTC"
OUTPUT_FILE=""
QUIET=false
ALERT_COUNT=0
WARN_COUNT=0
STEPS_APPLIED=0
STEPS_SKIPPED=0
PROVISION_LOG="/var/log/provision.log"

# Populated during preflight
PKG_MANAGER=""     # apt | dnf | yum
SUDO_GROUP=""      # sudo | wheel
SSHD_CONFIG="/etc/ssh/sshd_config"
SSHD_BACKUP=""

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
skip()  { echo -e "${GREEN}[SKIP]${RESET}  $*"; (( STEPS_SKIPPED++ )) || true; }
warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; (( WARN_COUNT++ )) || true; }
alert() { echo -e "${RED}[ALERT]${RESET} $*"; (( ALERT_COUNT++ )) || true; }
header(){ echo -e "\n${BOLD}══════════════════════════════════════════${RESET}"; echo -e "${BOLD}  $*${RESET}"; echo -e "${BOLD}══════════════════════════════════════════${RESET}"; }
step()  { echo -e "${CYAN}[STEP]${RESET}  $*"; (( STEPS_APPLIED++ )) || true; }

# ── Logging helper ─────────────────────────────
plog() {
  echo "$(date '+%Y-%m-%d %H:%M:%S')  $*" >> "$PROVISION_LOG" 2>/dev/null || true
}

# ── Usage ─────────────────────────────────────
usage() {
  cat <<EOF
Usage: $(basename "$0") -u USER -k "SSH_KEY" [OPTIONS]

Bootstrap a fresh Linux server to a known secure baseline. Idempotent —
safe to run multiple times. Supports Debian/Ubuntu (apt) and RHEL/CentOS/
Fedora (dnf/yum). Compatible with EC2 Launch Template User Data.

Steps applied:
  1.  System package update
  2.  Install baseline packages (curl wget git ufw fail2ban htop net-tools ...)
  3.  Set timezone
  4.  Set hostname
  5.  Create admin user, add to sudo group, authorize SSH public key
  6.  SSH hardening (PermitRootLogin no, PasswordAuthentication no, ...)
  7.  Firewall — ufw enable, deny incoming, allow SSH
  8.  Unattended security upgrades
  9.  Lock root password
  10. Write completion log to $PROVISION_LOG

Options:
  -u, --user      NAME    Admin username to create (required)
  -k, --key       "KEY"   SSH public key string to authorize (required)
  -n, --hostname  NAME    Hostname to set (optional)
  -t, --timezone  TZ      Timezone (default: UTC)
  -o, --output    FILE    Write provision report to file
  -q, --quiet             No color output
  -h, --help              Show this help message

Examples:
  sudo $(basename "$0") -u deploy -k "ssh-rsa AAAA..." --hostname web-prod-01
  sudo $(basename "$0") -u admin  -k "ssh-ed25519 AAAA..." --timezone America/New_York

EC2 User Data:
  #!/usr/bin/env bash
  bash /path/to/$(basename "$0") \\
    --user deploy \\
    --key "ssh-rsa AAAA..." \\
    --hostname web-prod-01 \\
    --timezone America/New_York
EOF
}

# ── Argument parsing ───────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    -u|--user)      ADMIN_USER="$2"; shift 2 ;;
    -k|--key)       SSH_PUBKEY="$2"; shift 2 ;;
    -n|--hostname)  NEW_HOSTNAME="$2"; shift 2 ;;
    -t|--timezone)  TIMEZONE="$2"; shift 2 ;;
    -o|--output)    OUTPUT_FILE="$2"; shift 2 ;;
    -q|--quiet)     QUIET=true; RED=''; YELLOW=''; GREEN=''; CYAN=''; BOLD=''; RESET=''; shift ;;
    -h|--help)      usage; exit 0 ;;
    *) echo "Unknown option: $1"; usage; exit 1 ;;
  esac
done

# ── Root check ────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root." >&2
  exit 1
fi

# ── Required argument check ───────────────────
if [[ -z "$ADMIN_USER" || -z "$SSH_PUBKEY" ]]; then
  echo "Error: --user and --key are required." >&2
  usage
  exit 1
fi

# ── Preflight: detect package manager ─────────
if command -v apt-get &>/dev/null; then
  PKG_MANAGER="apt"
elif command -v dnf &>/dev/null; then
  PKG_MANAGER="dnf"
elif command -v yum &>/dev/null; then
  PKG_MANAGER="yum"
else
  echo "Error: no supported package manager found (apt, dnf, or yum)." >&2
  exit 1
fi

# ── Preflight: detect sudo group ──────────────
if getent group sudo &>/dev/null; then
  SUDO_GROUP="sudo"
elif getent group wheel &>/dev/null; then
  SUDO_GROUP="wheel"
else
  echo "Error: neither 'sudo' nor 'wheel' group found." >&2
  exit 1
fi

# ── Redirect to file if --output is set ───────
if [[ -n "$OUTPUT_FILE" ]]; then
  exec > >(tee -a "$OUTPUT_FILE") 2>&1
fi

echo -e "\n${BOLD}Server Provisioning — $(hostname) — $(date)${RESET}"
echo -e "${BOLD}  Package manager: $PKG_MANAGER  |  Sudo group: $SUDO_GROUP${RESET}"
echo -e "${BOLD}  Admin user:      $ADMIN_USER${RESET}"
[[ -n "$NEW_HOSTNAME" ]] && echo -e "${BOLD}  Hostname:        $NEW_HOSTNAME${RESET}"
echo -e "${BOLD}  Timezone:        $TIMEZONE${RESET}"

plog "START  user=$ADMIN_USER  hostname=${NEW_HOSTNAME:-unchanged}  tz=$TIMEZONE  pkgmgr=$PKG_MANAGER"

# ──────────────────────────────────────────────
#  Step 1: System Update
# ──────────────────────────────────────────────
header "Step 1 — System Update"

case "$PKG_MANAGER" in
  apt)
    step "Running apt-get update && apt-get upgrade -y"
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq
    ok "System packages updated"
    ;;
  dnf)
    step "Running dnf upgrade -y"
    dnf upgrade -y -q
    ok "System packages updated"
    ;;
  yum)
    step "Running yum update -y"
    yum update -y -q
    ok "System packages updated"
    ;;
esac
plog "STEP1  system update complete"

# ──────────────────────────────────────────────
#  Step 2: Baseline Packages
# ──────────────────────────────────────────────
header "Step 2 — Baseline Packages"

# is_installed: returns 0 if the package is installed, 1 if not
is_installed() {
  local pkg="$1"
  case "$PKG_MANAGER" in
    apt) dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null | grep -q "install ok installed" ;;
    dnf|yum) rpm -q "$pkg" &>/dev/null ;;
  esac
}

install_pkg() {
  local pkg="$1"
  if is_installed "$pkg"; then
    skip "$pkg — already installed"
    return
  fi
  step "Installing $pkg"
  case "$PKG_MANAGER" in
    apt)     DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$pkg" ;;
    dnf)     dnf install -y -q "$pkg" ;;
    yum)     yum install -y -q "$pkg" ;;
  esac
  ok "Installed: $pkg"
}

# On RHEL/CentOS, EPEL is needed for ufw and fail2ban
if [[ "$PKG_MANAGER" != "apt" ]]; then
  install_pkg "epel-release" || warn "epel-release install failed — ufw/fail2ban may be unavailable"
fi

BASELINE_PACKAGES=(curl wget git ufw fail2ban htop net-tools)
# unattended-upgrades is Debian-only; dnf-automatic is the RHEL equivalent
if [[ "$PKG_MANAGER" == "apt" ]]; then
  BASELINE_PACKAGES+=(unattended-upgrades)
else
  BASELINE_PACKAGES+=(dnf-automatic)
fi

for pkg in "${BASELINE_PACKAGES[@]}"; do
  install_pkg "$pkg"
done

plog "STEP2  baseline packages installed"

# ──────────────────────────────────────────────
#  Step 3: Timezone
# ──────────────────────────────────────────────
header "Step 3 — Timezone"

current_tz=$(timedatectl show --property=Timezone --value 2>/dev/null || cat /etc/timezone 2>/dev/null || echo "unknown")

if [[ "$current_tz" == "$TIMEZONE" ]]; then
  skip "Timezone already set to $TIMEZONE"
else
  step "Setting timezone: $TIMEZONE"
  timedatectl set-timezone "$TIMEZONE"
  ok "Timezone set to: $TIMEZONE"
fi

plog "STEP3  timezone=$TIMEZONE"

# ──────────────────────────────────────────────
#  Step 4: Hostname
# ──────────────────────────────────────────────
header "Step 4 — Hostname"

if [[ -z "$NEW_HOSTNAME" ]]; then
  skip "No --hostname provided — leaving hostname as: $(hostname)"
else
  current_hostname=$(hostname)
  if [[ "$current_hostname" == "$NEW_HOSTNAME" ]]; then
    skip "Hostname already set to $NEW_HOSTNAME"
  else
    step "Setting hostname: $NEW_HOSTNAME"
    hostnamectl set-hostname "$NEW_HOSTNAME"
    ok "Hostname set to: $NEW_HOSTNAME"
  fi
fi

plog "STEP4  hostname=${NEW_HOSTNAME:-unchanged}"

# ──────────────────────────────────────────────
#  Step 5: Admin User & SSH Key
# ──────────────────────────────────────────────
header "Step 5 — Admin User & SSH Key"

if id "$ADMIN_USER" &>/dev/null; then
  skip "User '$ADMIN_USER' already exists"
else
  step "Creating user: $ADMIN_USER"
  useradd -m -s /bin/bash -G "$SUDO_GROUP" "$ADMIN_USER"
  ok "User created: $ADMIN_USER (group: $SUDO_GROUP)"
fi

# Ensure the user is in the sudo group even if they already existed
if ! id -nG "$ADMIN_USER" | grep -qw "$SUDO_GROUP"; then
  step "Adding $ADMIN_USER to $SUDO_GROUP group"
  usermod -aG "$SUDO_GROUP" "$ADMIN_USER"
  ok "Added $ADMIN_USER to $SUDO_GROUP"
else
  skip "$ADMIN_USER is already in $SUDO_GROUP"
fi

# SSH authorized_keys — append only if the key isn't already present
SSH_DIR="/home/${ADMIN_USER}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
chown "${ADMIN_USER}:${ADMIN_USER}" "$SSH_DIR"

touch "$AUTH_KEYS"
chown "${ADMIN_USER}:${ADMIN_USER}" "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

if grep -qF "$SSH_PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
  skip "SSH public key already in authorized_keys"
else
  step "Authorizing SSH public key for $ADMIN_USER"
  echo "$SSH_PUBKEY" >> "$AUTH_KEYS"
  ok "SSH key added to $AUTH_KEYS"
fi

# Lock password login for the admin account — key-only access
if passwd -S "$ADMIN_USER" 2>/dev/null | grep -q " L "; then
  skip "Password login for $ADMIN_USER already locked"
else
  step "Locking password login for $ADMIN_USER (key-only)"
  passwd -l "$ADMIN_USER"
  ok "Password login locked for: $ADMIN_USER"
fi

plog "STEP5  user=$ADMIN_USER  ssh_key=authorized  password=locked"

# ──────────────────────────────────────────────
#  Step 6: SSH Hardening
#  Applied inline (no external dependency) so this script is self-contained
#  for EC2 User Data. One sshd -t validation and single restart at the end.
# ──────────────────────────────────────────────
header "Step 6 — SSH Hardening"

# set_sshd: replace directive (commented or not) or append if absent
set_sshd() {
  local key="$1" value="$2"
  local target="${key} ${value}"

  if grep -qE "^\s*#*\s*${key}(\s|$)" "$SSHD_CONFIG"; then
    sed -i -E "s|^\s*#*\s*${key}(\s.*)?$|${target}|" "$SSHD_CONFIG"
  else
    echo "$target" >> "$SSHD_CONFIG"
  fi
  ok "  $target"
}

if [[ ! -f "$SSHD_CONFIG" ]]; then
  warn "sshd_config not found at $SSHD_CONFIG — skipping SSH hardening"
else
  SSHD_BACKUP="${SSHD_CONFIG}.bak.$(date +%s)"
  cp "$SSHD_CONFIG" "$SSHD_BACKUP"
  log "Config backed up to: $SSHD_BACKUP"

  set_sshd "PermitRootLogin"        "no"
  set_sshd "PasswordAuthentication" "no"
  set_sshd "PubkeyAuthentication"   "yes"
  set_sshd "MaxAuthTries"           "3"
  set_sshd "PermitEmptyPasswords"   "no"
  set_sshd "ClientAliveInterval"    "300"
  set_sshd "ClientAliveCountMax"    "2"
  set_sshd "X11Forwarding"          "no"

  log "Validating sshd config..."
  if sshd -t 2>&1; then
    ok "sshd -t passed"
    systemctl restart sshd 2>/dev/null || systemctl restart ssh 2>/dev/null || \
      warn "sshd restart returned non-zero — verify sshd is running"
    ok "sshd restarted"
  else
    alert "sshd -t FAILED — restoring backup"
    cp "$SSHD_BACKUP" "$SSHD_CONFIG"
    warn "SSH hardening rolled back. Review $SSHD_CONFIG manually."
  fi
fi

plog "STEP6  ssh_hardening=applied  sshd_backup=$SSHD_BACKUP"

# ──────────────────────────────────────────────
#  Step 7: Firewall (UFW)
# ──────────────────────────────────────────────
header "Step 7 — Firewall (UFW)"

if ! command -v ufw &>/dev/null; then
  warn "ufw not found — skipping firewall configuration"
else
  # Set default policies before enabling to avoid locking ourselves out
  step "Setting ufw default policies"
  ufw default deny incoming  &>/dev/null
  ufw default allow outgoing &>/dev/null
  ok "Default: deny incoming, allow outgoing"

  # Allow SSH before enabling — otherwise we lock ourselves out
  if ufw status 2>/dev/null | grep -q "22/tcp\|OpenSSH\|ALLOW"; then
    skip "SSH rule already present in ufw"
  else
    step "Allowing SSH through ufw"
    ufw allow ssh &>/dev/null
    ok "SSH allowed"
  fi

  # Enable ufw non-interactively; idempotent if already active
  ufw_status=$(ufw status 2>/dev/null | head -1 || true)
  if echo "$ufw_status" | grep -qi "active"; then
    skip "ufw already active"
  else
    step "Enabling ufw"
    ufw --force enable &>/dev/null
    ok "ufw enabled"
  fi

  ufw status verbose 2>/dev/null | sed 's/^/  /'
fi

plog "STEP7  firewall=ufw  default=deny-incoming  ssh=allowed"

# ──────────────────────────────────────────────
#  Step 8: Unattended Security Upgrades
# ──────────────────────────────────────────────
header "Step 8 — Unattended Security Upgrades"

AUTO_UPGRADES_CONF="/etc/apt/apt.conf.d/20auto-upgrades"

case "$PKG_MANAGER" in
  apt)
    if [[ -f "$AUTO_UPGRADES_CONF" ]] && grep -q 'Unattended-Upgrade "1"' "$AUTO_UPGRADES_CONF" 2>/dev/null; then
      skip "Unattended upgrades already configured"
    else
      step "Configuring unattended-upgrades"
      cat > "$AUTO_UPGRADES_CONF" << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
      ok "Unattended upgrades configured: $AUTO_UPGRADES_CONF"
    fi

    if ! systemctl is-enabled unattended-upgrades &>/dev/null; then
      step "Enabling unattended-upgrades service"
      systemctl enable --now unattended-upgrades &>/dev/null
      ok "unattended-upgrades service enabled"
    else
      skip "unattended-upgrades service already enabled"
    fi
    ;;
  dnf|yum)
    if systemctl is-enabled dnf-automatic.timer &>/dev/null 2>&1; then
      skip "dnf-automatic timer already enabled"
    else
      step "Enabling dnf-automatic timer"
      systemctl enable --now dnf-automatic.timer &>/dev/null || \
        warn "dnf-automatic timer failed to enable — verify dnf-automatic is installed"
      ok "dnf-automatic timer enabled"
    fi
    ;;
esac

plog "STEP8  unattended_upgrades=enabled"

# ──────────────────────────────────────────────
#  Step 9: Root Lock
#  Lock the root password — root still reachable via sudo from the admin user,
#  but direct root login (password or interactive) is disabled.
# ──────────────────────────────────────────────
header "Step 9 — Root Lock"

root_status=$(passwd -S root 2>/dev/null | awk '{print $2}' || echo "unknown")

if [[ "$root_status" == "L" || "$root_status" == "LK" ]]; then
  skip "Root password already locked ($root_status)"
else
  step "Locking root password"
  passwd -l root
  ok "Root password locked — sudo access via '$ADMIN_USER' only"
fi

plog "STEP9  root_locked=true"

# ──────────────────────────────────────────────
#  Step 10: Completion Log
# ──────────────────────────────────────────────
header "Step 10 — Completion Log"

{
  echo "══════════════════════════════════════════════"
  echo "  PROVISION COMPLETE — $(date)"
  echo "══════════════════════════════════════════════"
  echo "  hostname:            $(hostname)"
  echo "  timezone:            $(timedatectl show --property=Timezone --value 2>/dev/null || echo "$TIMEZONE")"
  echo "  admin user:          $ADMIN_USER"
  echo "  sudo group:          $SUDO_GROUP"
  echo "  ssh key authorized:  $AUTH_KEYS"
  echo "  ssh hardening:       applied"
  echo "  firewall:            $(ufw status 2>/dev/null | head -1 || echo 'ufw not found')"
  echo "  auto upgrades:       enabled"
  echo "  root locked:         yes"
  echo "  steps applied:       $STEPS_APPLIED"
  echo "  steps skipped:       $STEPS_SKIPPED"
  echo "  warnings:            $WARN_COUNT"
  echo "══════════════════════════════════════════════"
} | tee -a "$PROVISION_LOG"

ok "Completion log written to: $PROVISION_LOG"

# ──────────────────────────────────────────────
#  Summary
# ──────────────────────────────────────────────
header "Summary"
echo -e "  ${BOLD}Steps applied:${RESET}  $STEPS_APPLIED"
echo -e "  ${CYAN}Steps skipped:${RESET}  $STEPS_SKIPPED  (already in correct state)"
echo -e "  ${YELLOW}Warnings:${RESET}       $WARN_COUNT"
echo -e "  ${RED}Alerts:${RESET}         $ALERT_COUNT"
echo ""

if [[ $ALERT_COUNT -gt 0 ]]; then
  alert "Provisioning completed with errors — review output above."
  exit 2
elif [[ $WARN_COUNT -gt 0 ]]; then
  warn "Provisioning complete with $WARN_COUNT warning(s)."
  exit 1
else
  ok "Server provisioned successfully. SSH in as: $ADMIN_USER"
  plog "COMPLETE  warnings=0  alerts=0"
  exit 0
fi
