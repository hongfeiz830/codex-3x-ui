#!/usr/bin/env bash
# ==============================================================================
# 3x-ui One-Click Installer
# One command automatically covers both cases:
#   - New VPS:      auto init system (packages, firewall, BBR, swap) and install
#   - Old VPS:      auto detect and wipe old x-ui/3x-ui/v2-ui/etc. then reinstall
#
# Hard-coded defaults (override via flags):
#   username=admin   password=123456   port=10601   webpath=/xui
#   node-port=443    HTTPS via self-signed cert (Let's Encrypt if -d <domain> given)
#
# Usage:
#   bash install.sh                 # works on new or old VPS automatically
#   bash install.sh -d domain.com   # optional: Let's Encrypt domain cert
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
  -d, --domain DOMAIN     Domain for HTTPS panel (recommended)
  -p, --port PORT         Panel port        (default: $XUI_PORT)
  -u, --username USER     Panel username    (default: $XUI_USERNAME)
  -P, --password PASS     Panel password    (default: $XUI_PASSWORD)
  -b, --basepath PATH     Web base path     (default: $XUI_WEBBASEPATH)
  -n, --nodeport PORT     Node inbound port (default: $XUI_NODEPORT)
  --force-clean           Optional: force wipe even if no old panel is detected
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
# Returns 0 if any old proxy panel is detected on this server.
detect_old_install() {
  local svc d
  for svc in x-ui 3x-ui xray-ui v2-ui s-ui h-ui m-ui marzban marzbanny; do
    if systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\\.service"; then
      return 0
    fi
  done
  for d in /usr/local/x-ui /etc/x-ui /usr/local/3x-ui /etc/3x-ui \
           /usr/local/v2-ui /etc/v2-ui /usr/local/xray-ui /etc/xray-ui \
           /usr/local/s-ui /etc/s-ui /usr/local/h-ui; do
    if [[ -d "$d" ]]; then
      return 0
    fi
  done
  for svc in x-ui 3x-ui xray-ui v2-ui; do
    if command -v "$svc" &>/dev/null; then
      return 0
    fi
  done
  return 1
}

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
  for p in $(hostname -I 2>/dev/null); do
    [[ "$p" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] && SAN="${SAN},IP:${p}"
  done

  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$KEY_FILE" -out "$CRT_FILE" \
    -subj "/CN=$CN" \
    -addext "subjectAltName = ${SAN}" \
    -addext "extendedKeyUsage = serverAuth" \
    >/dev/null 2>&1
  CERT_MODE="selfsigned"
  info "Self-signed cert created in $CERT_DIR (CN=$CN, SAN=$SAN)"
}

issue_letsencrypt() {
  step "Issuing Let's Encrypt certificate for $XUI_DOMAIN"
  mkdir -p "$CERT_DIR"

  # free port 80
  systemctl stop nginx 2>/dev/null || true
  systemctl stop caddy 2>/dev/null || true
  systemctl stop 3x-ui 2>/dev/null || true
  sleep 2

  # install acme.sh if missing
  if [[ ! -d /root/.acme.sh ]]; then
    info "Installing acme.sh..."
    if ! curl -sSL https://get.acme.sh | sh -s email="$EMAIL" >/tmp/acme-install.log 2>&1; then
      warn "acme.sh install failed; falling back to self-signed."
      generate_selfsigned
      systemctl restart 3x-ui 2>/dev/null || true
      return
    fi
  fi

  # shellcheck disable=SC1091
  source /root/.acme.sh/acme.sh
  /root/.acme.sh/acme.sh --set-default-ca --server letsencrypt

  if /root/.acme.sh/acme.sh --issue -d "$XUI_DOMAIN" --standalone --keylength ec-256 \
       --cert-file "$CRT_FILE" --key-file "$KEY_FILE" --fullchain-file "$CRT_FILE" \
       --force >/tmp/acme-issue.log 2>&1; then
    /root/.acme.sh/acme.sh --install-cert -d "$XUI_DOMAIN" --ecc \
      --cert-file "$CRT_FILE" --key-file "$KEY_FILE" --fullchain-file "$CRT_FILE" \
      --reloadcmd "systemctl restart 3x-ui" >/dev/null 2>&1 || true
    CERT_MODE="letsencrypt"
    info "Let's Encrypt cert issued for $XUI_DOMAIN"
  else
    warn "Let's Encrypt failed (DNS or port 80 issue). Falling back to self-signed."
    generate_selfsigned
  fi
  systemctl restart 3x-ui 2>/dev/null || true
}

enable_tls_in_panel() {
  step "Enabling HTTPS in panel"
  [[ -f "$CRT_FILE" && -f "$KEY_FILE" ]] || { error "Certificate files missing"; exit 1; }
  3x-ui setting -cert "$CRT_FILE" -certKey "$KEY_FILE"
  systemctl restart 3x-ui
  sleep 2
}

# ---------- Default VLESS+REALITY inbound ----------
create_default_inbound() {
  step "Creating default VLESS+REALITY inbound on port $XUI_NODEPORT"

  # detect public IP
  local PUBLIC_IP
  PUBLIC_IP="$(get_public_ip)"
  [[ -z "$PUBLIC_IP" ]] && PUBLIC_IP="YOUR_SERVER_IP"
  info "Public IP: $PUBLIC_IP"

  # UUID
  local UUID
  UUID=$(cat /proc/sys/kernel/random/uuid)

  # x25519 keys via bundled xray
  local XRAY_BIN PRIV_KEY PUB_KEY
  XRAY_BIN=$(find /usr/local/x-ui -maxdepth 4 -name 'xray-linux-*' -type f 2>/dev/null | head -1)
  if [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]]; then
    KPS=$("$XRAY_BIN" x25519 2>/dev/null || true)
    PRIV_KEY=$(echo "$KPS" | awk '/Private key:/{print $3}')
    PUB_KEY=$(echo "$KPS" | awk '/Public key:/{print $3}')
  fi

  local SID
  SID=$(openssl rand -hex 8)

  if [[ -z "${PRIV_KEY:-}" || -z "${PUB_KEY:-}" ]]; then
    PRIV_KEY="REPLACE_ME_RERUN_XRAY_X25519"
    PUB_KEY="REPLACE_ME_RERUN_XRAY_X25519"
    warn "Could not generate x25519 keys. Generate them in the panel after install."
  fi

  # Insert into sqlite DB using a heredoc to avoid quoting hell
  local DB="/etc/3x-ui/3x-ui.db"
  if [[ -f "$DB" ]] && command -v sqlite3 &>/dev/null; then
    local TAG="vless-reality-${XUI_NODEPORT}"
    local SETTINGS STREAM SNIFFING ALLOCATE
    SETTINGS=$(jq -cn --arg uuid "$UUID" \
      '{clients:[],decryption:"none",fallbacks:[]}')
    STREAM=$(jq -cn --arg sid "$SID" --arg pk "$PRIV_KEY" \
      '{network:"tcp",security:"reality",
        realitySettings:{show:false,xver:0,dest:"www.microsoft.com:443",
          serverNames:["www.microsoft.com","microsoft.com"],
          privateKey:$pk,minClient:"",maxClient:"",maxTimediff:0,
          shortIds:[$sid],
          settings:{publicKey:"",fingerprint:"chrome",serverName:"",spiderX:"/"}}}')
    SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false}'
    ALLOCATE='{"strategy":"always","refresh":5,"concurrency":3}'

    sqlite3 "$DB" <<SQL
DELETE FROM inbounds WHERE port=${XUI_NODEPORT} OR tag='${TAG}';
INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing,allocate)
VALUES (1,0,0,0,'VLESS-REALITY-${XUI_NODEPORT}',1,0,'',${XUI_NODEPORT},'vless',
  '$(echo "$SETTINGS" | sed "s/'/''/g")',
  '$(echo "$STREAM" | sed "s/'/''/g")',
  '${TAG}',
  '${SNIFFING}',
  '${ALLOCATE}');
SQL
    systemctl restart 3x-ui
    sleep 2
    info "Default inbound created."
  else
    warn "sqlite3 not available or DB missing; skipping default inbound. Add in panel."
  fi

  # Write link file
  local HOST FPATH PANEL_URL
  HOST="${XUI_DOMAIN:-$PUBLIC_IP}"
  FPATH="/${XUI_WEBBASEPATH}"
  [[ "$FPATH" == "/" ]] && FPATH=""
  PANEL_URL="https://${HOST}:${XUI_PORT}${FPATH}/"

  mkdir -p /root
  cat > /root/xui-link.txt <<EOF
==============================================
 3x-ui Panel Information
==============================================
Panel URL : ${PANEL_URL}
Username  : ${XUI_USERNAME}
Password  : ${XUI_PASSWORD}
TLS Mode  : ${CERT_MODE}
----------------------------------------------
Default Inbound: VLESS + REALITY
  Port      : ${XUI_NODEPORT}
  UUID      : ${UUID}
  PublicKey : ${PUB_KEY}
  ShortID   : ${SID}
  Server    : ${HOST}
  SNI       : www.microsoft.com
  Fingerprint: chrome
==============================================
EOF
  chmod 600 /root/xui-link.txt
  info "Saved info to /root/xui-link.txt"
}

# ---------- Banner & main ----------
banner() {
  cat <<'BANNER'

   ____  _____     _
  |___ \|  __ \   (_)
    __) | |  | |_   _
   |__ <| |  | \ \ / /
   ___) | |__| |\ V /
  |____/|_____/  \_/   One-Click Installer

BANNER
}

main() {
  banner
  detect_os

  if [[ $FORCE_CLEAN -eq 1 ]] || detect_old_install; then
    info "Old proxy panel detected (or --force-clean given). Running clean reinstall."
    clean_old_panels
  else
    info "No existing panel found. Running fresh VPS install."
  fi

  if [[ $FRESH_INIT -eq 1 ]]; then
    vps_init
  else
    info "Skipping VPS initialization (--no-init)."
  fi

  install_3xui
  configure_panel

  # Issue certs: Let's Encrypt only if a domain is provided; otherwise self-signed for IP.
  if [[ "$CERT_MODE" == "letsencrypt" && -n "$XUI_DOMAIN" ]]; then
    issue_letsencrypt
  else
    generate_selfsigned
  fi
  enable_tls_in_panel
  create_default_inbound

  step "Installation complete!"
  cat /root/xui-link.txt
  echo
  info "Useful commands:"
  echo "  3x-ui              # open management menu"
  echo "  3x-ui restart      # restart panel"
  echo "  3x-ui status       # status"
  echo "  cat /root/xui-link.txt"
}

main "$@"
