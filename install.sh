#!/usr/bin/env bash
# ==============================================================================
# 3x-ui One-Click Installer
# Supports:
#   1) Fresh VPS deployment  (init system, hardening, BBR, firewall, swap)
#   2) Clean overwrite       (wipes old x-ui / 3x-ui / v2-ui / xray-ui / s-ui)
#
# Hard-coded defaults (override via flags):
#   username=admin   password=123456   port=10601   webpath=/xui
#   node-port=443    HTTPS via self-signed cert (Let's Encrypt if -d <domain> given)
#
# Usage:
#   bash install.sh                       # fresh VPS, IP-only self-signed
#   bash install.sh --force-clean         # clean reinstall on old VPS
#   bash install.sh -d xui.example.com    # with domain + Let's Encrypt
# ==============================================================================
set -euo pipefail

# ---------- Defaults ----------
XUI_USERNAME="${XUI_USERNAME:-admin}"
XUI_PASSWORD="${XUI_PASSWORD:-123456}"
XUI_PORT="${XUI_PORT:-10601}"
XUI_WEBBASEPATH="${XUI_WEBBASEPATH:-xui}"
XUI_NODEPORT="${XUI_NODEPORT:-443}"
XUI_DOMAIN="${XUI_DOMAIN:-}"
FORCE_CLEAN=0
FRESH_INIT=1
CERT_MODE="selfsigned"        # selfsigned (default, IP-only) | letsencrypt (with -d)
EMAIL="${EMAIL:-admin@example.com}"

CERT_DIR="/etc/3x-ui/cert"
CRT_FILE="$CERT_DIR/fullchain.cer"
KEY_FILE="$CERT_DIR/private.key"

# ---------- Colors ----------
RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info()  { echo -e "${GRN}[INFO]${RST}  $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
error() { echo -e "${RED}[ERR ]${RST}  $*"; }
step()  { echo -e "\n${BLU}==> $*${RST}"; }

usage() {
  cat <<EOF
Usage: $0 [options]
  -d, --domain DOMAIN     Domain for HTTPS (Let's Encrypt)
  -p, --port PORT         Panel port        (default: $XUI_PORT)
  -u, --username USER     Panel username    (default: $XUI_USERNAME)
  -P, --password PASS     Panel password    (default: $XUI_PASSWORD)
  -b, --basepath PATH     Web base path     (default: $XUI_WEBBASEPATH)
  -n, --nodeport PORT     Node inbound port (default: $XUI_NODEPORT)
  --force-clean           Wipe old x-ui/3x-ui/v2-ui/etc. before install
  --no-init               Skip VPS initialization
  --selfsigned            Use self-signed certificate (default when no -d)
  -h, --help              Show help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -d|--domain)    XUI_DOMAIN="$2"; shift 2;;
    -p|--port)      XUI_PORT="$2"; shift 2;;
    -u|--username)  XUI_USERNAME="$2"; shift 2;;
    -P|--password)  XUI_PASSWORD="$2"; shift 2;;
    -b|--basepath)  XUI_WEBBASEPATH="$2"; shift 2;;
    -n|--nodeport)  XUI_NODEPORT="$2"; shift 2;;
    --force-clean)  FORCE_CLEAN=1; shift;;
    --no-init)      FRESH_INIT=0; shift;;
    --selfsigned)   CERT_MODE="selfsigned"; shift;;
    -h|--help)      usage;;
    *) error "Unknown option: $1"; usage;;
  esac
done

# normalize basepath
XUI_WEBBASEPATH="${XUI_WEBBASEPATH#/}"
XUI_WEBBASEPATH="${XUI_WEBBASEPATH%/}"
[[ -z "$XUI_WEBBASEPATH" ]] && XUI_WEBBASEPATH="/"

# ---------- Preflight ----------
[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash $0"; exit 1; }
command -v systemctl &>/dev/null || { error "systemd is required."; exit 1; }
# If a domain was provided without --selfsigned, attempt Let's Encrypt
if [[ -n "$XUI_DOMAIN" && "$CERT_MODE" != "selfsigned" ]]; then
  CERT_MODE="letsencrypt"
fi

# ---------- OS detection ----------
detect_os() {
  [[ -f /etc/os-release ]] && . /etc/os-release || { error "Cannot detect OS"; exit 1; }
  OS_ID="${ID,,}"
  case "$OS_ID" in
    ubuntu|debian) PKG="apt";;
    centos|rhel|rocky|almalinux|ol|fedora|amzn)
      PKG="yum"; command -v dnf &>/dev/null && PKG="dnf";;
    *) warn "Untested OS: $OS_ID, trying apt"; PKG="apt";;
  esac
  info "OS: $OS_ID ${VERSION_ID:-} ($PKG)"
}

pkg_install() {
  case "$PKG" in
    apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$@";;
    yum|dnf) $PKG install -y -q "$@";;
  esac
}
pkg_update() {
  case "$PKG" in
    apt)
      DEBIAN_FRONTEND=noninteractive apt-get update -y -qq
      DEBIAN_FRONTEND=noninteractive apt-get upgrade -y -qq \
        -o Dpkg::Options::="--force-confdef" \
        -o Dpkg::Options::="--force-confold"
      ;;
    yum|dnf) $PKG update -y -q;;
  esac
}

# ---------- Clean old panels ----------
clean_old_panels() {
  step "Wiping old proxy panels and residual files"

  for svc in x-ui 3x-ui xray-ui v2-ui s-ui h-ui m-ui marzban marzbanny; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\\.service"; then
      info "Stopping/disabling $svc"
      systemctl stop "$svc" 2>/dev/null || true
      systemctl disable "$svc" 2>/dev/null || true
      rm -f "/etc/systemd/system/${svc}.service" "/usr/lib/systemd/system/${svc}.service"
    fi
  done

  for proc in x-ui 3x-ui xray-ui v2-ui xray v2ray sing-box s-ui h-ui m-ui; do
    if pgrep -x "$proc" &>/dev/null; then
      info "Killing leftover process: $proc"
      pkill -9 -x "$proc" 2>/dev/null || true
    fi
  done
  sleep 2

  for d in /usr/local/x-ui /etc/x-ui /usr/local/3x-ui /etc/3x-ui \
           /usr/local/v2-ui /etc/v2-ui /usr/local/xray-ui /etc/xray-ui \
           /usr/local/s-ui /etc/s-ui /usr/local/h-ui; do
    if [[ -d "$d" ]]; then
      info "Removing $d"
      rm -rf "$d"
    fi
  done

  rm -f /usr/local/bin/x-ui /usr/local/bin/3x-ui \
        /usr/bin/x-ui /usr/bin/3x-ui 2>/dev/null || true

  # Crons
  crontab -l 2>/dev/null | grep -vE 'x-ui|3x-ui|v2-ui|xray' | crontab - 2>/dev/null || true
  for cf in /etc/cron.d/x-ui /etc/cron.d/3x-ui /etc/cron.d/v2-ui; do
    rm -f "$cf"
  done

  # Reverse proxy leftovers
  rm -f /etc/nginx/conf.d/*xui*.conf /etc/nginx/conf.d/*x-ui*.conf \
        /etc/nginx/sites-enabled/*xui* /etc/nginx/sites-available/*xui* 2>/dev/null || true
  rm -f /etc/caddy/conf.d/*xui* 2>/dev/null || true

  # Certs
  rm -rf /etc/3x-ui/cert /root/cert 2>/dev/null || true

  # Official uninstallers
  if [[ -f /usr/local/x-ui/x-ui.sh ]]; then
    info "Running x-ui uninstaller"
    bash /usr/local/x-ui/x-ui.sh uninstall 2>/dev/null || true
  fi
  if command -v x-ui &>/dev/null; then
    x-ui uninstall 2>/dev/null || true
  fi

  systemctl daemon-reload
  info "Cleanup complete."
}

# ---------- VPS initialization ----------
vps_init() {
  step "Initializing VPS (updates, tools, tuning, BBR, firewall, swap)"
  pkg_update || warn "System update had warnings, continuing."

  case "$PKG" in
    apt)
      pkg_install curl wget vim tar unzip gzip openssl ca-certificates socat \
                  lsof ufw cron gnupg lsb-release sudo jq sqlite3 iptables iproute2
      ;;
    yum|dnf)
      pkg_install curl wget vim tar unzip gzip openssl ca-certificates socat \
                  lsof firewalld cronie sudo jq sqlite iptables iproute \
                  policycoreutils-python-utils
      ;;
  esac

  # Timezone
  timedatectl set-timezone Asia/Shanghai 2>/dev/null || \
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

  # File limits
  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-xui.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

  # Sysctl + BBR
  cat > /etc/sysctl.d/99-xui.conf <<'EOF'
fs.file-max = 1048576
net.core.rmem_max = 67108864
net.core.wmem_max = 67108864
net.core.netdev_max_backlog = 250000
net.core.somaxconn = 65535
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF
  sysctl -p /etc/sysctl.d/99-xui.conf &>/dev/null || true
  modprobe tcp_bbr 2>/dev/null || true
  echo "tcp_bbr" > /etc/modules-load.d/bbr.conf

  # Firewall
  info "Configuring firewall"
  if command -v ufw &>/dev/null; then
    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing
    ufw allow 22/tcp
    ufw allow 80/tcp
    ufw allow 443/tcp
    ufw allow "${XUI_PORT}/tcp"
    ufw allow "${XUI_NODEPORT}/tcp"
    ufw allow "${XUI_NODEPORT}/udp"
    echo "y" | ufw enable
  elif command -v firewall-cmd &>/dev/null; then
    systemctl enable --now firewalld
    firewall-cmd --permanent --add-service=ssh
    firewall-cmd --permanent --add-service=http
    firewall-cmd --permanent --add-service=https
    firewall-cmd --permanent --add-port="${XUI_PORT}/tcp"
    firewall-cmd --permanent --add-port="${XUI_NODEPORT}/tcp"
    firewall-cmd --permanent --add-port="${XUI_NODEPORT}/udp"
    firewall-cmd --permanent --add-masquerade
    firewall-cmd --reload
  else
    warn "No ufw/firewalld. Opening ports via iptables."
    for p in 22 80 443 "$XUI_PORT" "$XUI_NODEPORT"; do
      iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    iptables -I INPUT -p udp --dport "$XUI_NODEPORT" -j ACCEPT 2>/dev/null || true
  fi

  # Swap for small VPS
  if [[ ! -f /swapfile ]] && [[ $(free -m | awk '/^Swap:/{print $2}') -lt 1024 ]]; then
    info "Creating 2G swapfile"
    (fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none) 2>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile &>/dev/null && swapon /swapfile
    grep -q swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi

  info "VPS initialization done."
}

# ---------- Install 3x-ui ----------
install_3xui() {
  step "Installing 3x-ui from official source"
  bash <(curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh)
  sleep 3
  hash -r
  command -v 3x-ui &>/dev/null || { error "3x-ui install failed"; exit 1; }
  systemctl enable --now 3x-ui
  info "3x-ui installed."
}

# ---------- Configure panel ----------
configure_panel() {
  step "Applying panel settings"
  info "user=$XUI_USERNAME  port=$XUI_PORT  base=/$XUI_WEBBASEPATH  node=$XUI_NODEPORT"
  3x-ui setting -username "$XUI_USERNAME" \
                -password "$XUI_PASSWORD" \
                -port "$XUI_PORT" \
                -webBasePath "/${XUI_WEBBASEPATH}"
  systemctl restart 3x-ui
  sleep 2
}

# ---------- Certificates ----------
# Get the server's public IPv4 (best-effort)
get_public_ip() {
  curl -4 -s --max-time 5 https://api.ipify.org \
    || curl -4 -s --max-time 5 https://ip.sb \
    || hostname -I 2>/dev/null | awk '{print $1}' \
    || ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -1
}

generate_selfsigned() {
  step "Generating self-signed certificate (IP-only)"
  mkdir -p "$CERT_DIR"
  local IP CN SAN
  IP="$(get_public_ip)"
  CN="${XUI_DOMAIN:-${IP:-server}}"
  # Build SAN list with public IP + common private IPs + localhost
  SAN="IP:127.0.0.1"
  [[ -n "$IP" ]] && SAN="${SAN},IP:${IP}"
  for p in $(hostname -