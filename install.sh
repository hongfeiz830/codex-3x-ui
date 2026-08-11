#!/usr/bin/env bash
# ==============================================================================
# 3x-ui (x-ui) One-Click Installer
#
# One command covers both cases automatically:
#   - New VPS: init system (packages, firewall, BBR, swap) then install
#   - Old VPS: detect and wipe old x-ui/3x-ui/v2-ui/etc. then reinstall
#
# This script drives the OFFICIAL mhsanaei/3x-ui installer in non-interactive
# mode via environment variables, so all requested settings are applied during
# installation:
#   username=admin  password=123456  port=10601  webPath=/xui
#   node port=443   HTTPS: Let's Encrypt IP certificate (auto-renew, valid
#                   ~6 days), with self-signed fallback if issuance fails.
#
# Usage (single command, works on new or old VPS):
#   bash install.sh
# ==============================================================================
set -euo pipefail

# ---------- Defaults ----------
XUI_USERNAME="${XUI_USERNAME:-admin}"
XUI_PASSWORD="${XUI_PASSWORD:-123456}"
XUI_PORT="${XUI_PORT:-10601}"
XUI_WEBBASEPATH="${XUI_WEBBASEPATH:-xui}"
XUI_NODEPORT="${XUI_NODEPORT:-443}"
FORCE_CLEAN=0
FRESH_INIT=1

RED=$'\033[0;31m'; GRN=$'\033[0;32m'; YEL=$'\033[1;33m'; BLU=$'\033[0;34m'; RST=$'\033[0m'
info()  { echo -e "${GRN}[INFO]${RST}  $*"; }
warn()  { echo -e "${YEL}[WARN]${RST}  $*"; }
error() { echo -e "${RED}[ERR ]${RST}  $*"; }
step()  { echo -e "\n${BLU}==> $*${RST}"; }

usage() {
  cat <<EOF
Usage: $0 [options]
  -p, --port PORT         Panel port        (default: $XUI_PORT)
  -u, --username USER     Panel username    (default: $XUI_USERNAME)
  -P, --password PASS     Panel password    (default: $XUI_PASSWORD)
  -b, --basepath PATH     Web base path     (default: $XUI_WEBBASEPATH)
  -n, --nodeport PORT     Node inbound port (default: $XUI_NODEPORT)
  --force-clean           Force wipe even if no old panel is detected
  --no-init               Skip VPS initialization
  -h, --help              Show help
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -p|--port)      XUI_PORT="$2"; shift 2;;
    -u|--username)  XUI_USERNAME="$2"; shift 2;;
    -P|--password)  XUI_PASSWORD="$2"; shift 2;;
    -b|--basepath)  XUI_WEBBASEPATH="$2"; shift 2;;
    -n|--nodeport)  XUI_NODEPORT="$2"; shift 2;;
    --force-clean)  FORCE_CLEAN=1; shift;;
    --no-init)      FRESH_INIT=0; shift;;
    -h|--help)      usage;;
    *) error "Unknown option: $1"; usage;;
  esac
done

XUI_WEBBASEPATH="${XUI_WEBBASEPATH#/}"
XUI_WEBBASEPATH="${XUI_WEBBASEPATH%/}"
[[ -z "$XUI_WEBBASEPATH" ]] && XUI_WEBBASEPATH="/"

[[ $EUID -ne 0 ]] && { error "Run as root: sudo bash $0"; exit 1; }
command -v systemctl &>/dev/null || { error "systemd is required."; exit 1; }

# ---------- OS ----------
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

# ---------- Old panel detection / cleanup ----------
detect_old_install() {
  local svc d
  for svc in x-ui 3x-ui xray-ui v2-ui s-ui h-ui m-ui marzban marzbanny; do
    systemctl list-unit-files 2>/dev/null | grep -q "^${svc}\\.service" && return 0
  done
  for d in /usr/local/x-ui /etc/x-ui /usr/local/3x-ui /etc/3x-ui \
           /usr/local/v2-ui /etc/v2-ui /usr/local/xray-ui /etc/xray-ui \
           /usr/local/s-ui /etc/s-ui /usr/local/h-ui; do
    [[ -d "$d" ]] && return 0
  done
  for svc in x-ui 3x-ui xray-ui v2-ui; do
    command -v "$svc" &>/dev/null && return 0
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
    pgrep -x "$proc" &>/dev/null && { info "Killing $proc"; pkill -9 -x "$proc" 2>/dev/null || true; }
  done
  sleep 2
  for d in /usr/local/x-ui /etc/x-ui /usr/local/3x-ui /etc/3x-ui \
           /usr/local/v2-ui /etc/v2-ui /usr/local/xray-ui /etc/xray-ui \
           /usr/local/s-ui /etc/s-ui /usr/local/h-ui; do
    [[ -d "$d" ]] && { info "Removing $d"; rm -rf "$d"; }
  done
  rm -f /usr/local/bin/x-ui /usr/local/bin/3x-ui /usr/bin/x-ui /usr/bin/3x-ui 2>/dev/null || true
  crontab -l 2>/dev/null | grep -vE 'x-ui|3x-ui|v2-ui|xray' | crontab - 2>/dev/null || true
  for cf in /etc/cron.d/x-ui /etc/cron.d/3x-ui /etc/cron.d/v2-ui; do rm -f "$cf"; done
  rm -f /etc/nginx/conf.d/*xui*.conf /etc/nginx/conf.d/*x-ui*.conf \
        /etc/nginx/sites-enabled/*xui* /etc/nginx/sites-available/*xui* 2>/dev/null || true
  rm -rf /etc/x-ui/cert /etc/3x-ui/cert /root/cert 2>/dev/null || true
  systemctl daemon-reload
  info "Cleanup complete."
}

# ---------- VPS init ----------
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
  timedatectl set-timezone Asia/Shanghai 2>/dev/null || \
    ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime

  mkdir -p /etc/security/limits.d
  cat > /etc/security/limits.d/99-xui.conf <<'EOF'
* soft nofile 1048576
* hard nofile 1048576
root soft nofile 1048576
root hard nofile 1048576
EOF

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
    for p in 22 80 443 "$XUI_PORT" "$XUI_NODEPORT"; do
      iptables -I INPUT -p tcp --dport "$p" -j ACCEPT 2>/dev/null || true
    done
    iptables -I INPUT -p udp --dport "$XUI_NODEPORT" -j ACCEPT 2>/dev/null || true
  fi

  if [[ ! -f /swapfile ]] && [[ $(free -m | awk '/^Swap:/{print $2}') -lt 1024 ]]; then
    info "Creating 2G swapfile"
    (fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none) 2>/dev/null
    chmod 600 /swapfile
    mkswap /swapfile &>/dev/null && swapon /swapfile
    grep -q swapfile /etc/fstab || echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
  info "VPS initialization done."
}

# ---------- Install (official installer, non-interactive) ----------
install_3xui() {
  step "Installing x-ui via official installer (non-interactive)"
  local INSTALLER="/tmp/3x-ui-install.sh"
  local OFFICIAL="https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh"
  if ! curl -fsSL --max-time 20 "$OFFICIAL" -o "$INSTALLER"; then
    warn "Direct download failed, trying mirror..."
    curl -fsSL --max-time 30 "https://ghproxy.net/${OFFICIAL}" -o "$INSTALLER" \
      || curl -fsSL --max-time 30 "https://ghfast.top/${OFFICIAL}" -o "$INSTALLER" \
      || { error "Cannot download official installer (network to GitHub blocked)."; exit 1; }
  fi

  # Official non-interactive env vars: installs panel AND applies
  # username/password/port/webPath/IP SSL certificate in one shot.
  XUI_NONINTERACTIVE=1 \
  XUI_USERNAME="$XUI_USERNAME" \
  XUI_PASSWORD="$XUI_PASSWORD" \
  XUI_PANEL_PORT="$XUI_PORT" \
  XUI_WEB_BASE_PATH="$XUI_WEBBASEPATH" \
  XUI_SSL_MODE="ip" \
  bash "$INSTALLER" || warn "Official installer returned an error; checking installation state..."

  sleep 3
  hash -r
  command -v x-ui &>/dev/null || { error "x-ui command not found after install."; exit 1; }
  systemctl enable --now x-ui
  info "x-ui installed and configured."
}

# ---------- TLS fallback (self-signed if Let's Encrypt IP cert failed) ----------
ensure_tls() {
  step "Checking panel TLS configuration"
  local cert_info
  cert_info=$(x-ui setting -getCert true 2>/dev/null || true)
  if echo "$cert_info" | grep -qi "cert:" && echo "$cert_info" | grep -qi "key:"; then
    info "TLS certificate already configured by official installer."
    return
  fi

  warn "IP certificate not configured. Generating self-signed fallback..."
  mkdir -p /etc/x-ui/cert
  local IP
  IP=$(curl -4 -s --max-time 5 https://api.ipify.org || hostname -I 2>/dev/null | awk '{print $1}' || echo server)
  openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout /etc/x-ui/cert/private.key -out /etc/x-ui/cert/fullchain.cer \
    -subj "/CN=$IP" \
    -addext "subjectAltName = IP:$IP" \
    -addext "extendedKeyUsage = serverAuth" >/dev/null 2>&1 || {
      error "Self-signed cert generation failed."; exit 1; }
  x-ui cert -webCert /etc/x-ui/cert/fullchain.cer -webCertKey /etc/x-ui/cert/private.key
  systemctl restart x-ui
  info "Self-signed TLS fallback enabled."
}

# ---------- Default VLESS+REALITY inbound ----------
create_default_inbound() {
  step "Creating default VLESS+REALITY inbound on port $XUI_NODEPORT"
  local DB="/etc/x-ui/x-ui.db"
  if [[ ! -f "$DB" ]] || ! command -v sqlite3 &>/dev/null; then
    warn "DB/sqlite3 unavailable; add inbound manually in the panel."
    return
  fi

  local PUBLIC_IP UUID PRIV_KEY PUB_KEY SID XRAY_BIN KPS
  PUBLIC_IP=$(curl -4 -s --max-time 5 https://api.ipify.org || hostname -I 2>/dev/null | awk '{print $1}' || echo "YOUR_SERVER_IP")
  UUID=$(cat /proc/sys/kernel/random/uuid)
  XRAY_BIN=$(find /usr/local/x-ui -maxdepth 4 -name 'xray-linux-*' -type f 2>/dev/null | head -1)
  if [[ -n "$XRAY_BIN" && -x "$XRAY_BIN" ]]; then
    KPS=$("$XRAY_BIN" x25519 2>/dev/null || true)
    PRIV_KEY=$(echo "$KPS" | awk '/Private key:/{print $3}')
    PUB_KEY=$(echo "$KPS" | awk '/Public key:/{print $3}')
  fi
  SID=$(openssl rand -hex 8)
  if [[ -z "${PRIV_KEY:-}" || -z "${PUB_KEY:-}" ]]; then
    PRIV_KEY="REPLACE_ME_RERUN_XRAY_X25519"
    PUB_KEY="REPLACE_ME_RERUN_XRAY_X25519"
    warn "x25519 keys not generated; set them in the panel after install."
  fi

  local TAG="vless-reality-${XUI_NODEPORT}"
  local SETTINGS STREAM SNIFFING ALLOCATE
  SETTINGS=$(jq -cn --arg uuid "$UUID" \
    '{clients:[{id:$uuid,flow:"xtls-rprx-vision",email:"default",limitIp:0,totalGB:0,expiryTime:0,enable:true,tgId:"",subId:""}],decryption:"none",fallbacks:[]}')
  STREAM=$(jq -cn --arg sid "$SID" --arg pk "$PRIV_KEY" --arg pub "$PUB_KEY" \
    '{network:"tcp",security:"reality",
      realitySettings:{show:false,xver:0,dest:"www.microsoft.com:443",
        serverNames:["www.microsoft.com","microsoft.com"],
        privateKey:$pk,minClient:"",maxClient:"",maxTimediff:0,
        shortIds:[$sid],
        settings:{publicKey:$pub,fingerprint:"chrome",serverName:"",spiderX:"/"}}}')
  SNIFFING='{"enabled":true,"destOverride":["http","tls","quic","fakedns"],"metadataOnly":false}'
  ALLOCATE='{"strategy":"always","refresh":5,"concurrency":3}'

  if sqlite3 "$DB" <<SQL
DELETE FROM inbounds WHERE port=${XUI_NODEPORT} OR tag='${TAG}';
INSERT INTO inbounds (user_id,up,down,total,remark,enable,expiry_time,listen,port,protocol,settings,stream_settings,tag,sniffing,allocate)
VALUES (1,0,0,0,'VLESS-REALITY-${XUI_NODEPORT}',1,0,'',${XUI_NODEPORT},'vless',
  '$(echo "$SETTINGS" | sed "s/'/''/g")',
  '$(echo "$STREAM" | sed "s/'/''/g")',
  '${TAG}','${SNIFFING}','${ALLOCATE}');
SQL
  then
    systemctl restart x-ui
    sleep 2
    info "Default inbound created."
  else
    warn "Failed to write default inbound; add it manually in the panel."
  fi

  # Write access info
  local HOST FPATH PANEL_URL
  HOST="$PUBLIC_IP"
  FPATH="/${XUI_WEBBASEPATH}"
  [[ "$FPATH" == "/" ]] && FPATH=""
  PANEL_URL="https://${HOST}:${XUI_PORT}${FPATH}/"
  cat > /root/xui-link.txt <<EOF
==============================================
 x-ui Panel Information
==============================================
Panel URL : ${PANEL_URL}
Username  : ${XUI_USERNAME}
Password  : ${XUI_PASSWORD}
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

# ---------- Verification ----------
verify_install() {
  step "Verifying installation"
  if systemctl is-active --quiet x-ui; then info "x-ui service: active"; else warn "x-ui service: NOT active"; fi
  if ss -tln 2>/dev/null | grep -q ":$XUI_PORT "; then info "Panel port ${XUI_PORT}: listening"; else warn "Panel port ${XUI_PORT}: NOT listening"; fi
  local FPATH="/${XUI_WEBBASEPATH}"
  [[ "$FPATH" == "/" ]] && FPATH=""
  local CODE
  CODE=$(curl -k -s -o /dev/null -w "%{http_code}" --max-time 5 "https://127.0.0.1:${XUI_PORT}${FPATH}/" 2>/dev/null || true)
  info "HTTPS check (localhost): HTTP $CODE  (200/302/401 = panel reachable over HTTPS)"
}

# ---------- Main ----------
main() {
  step "3x-ui One-Click Installer"
  detect_os

  if [[ $FORCE_CLEAN -eq 1 ]] || detect_old_install; then
    info "Old proxy panel detected (or --force-clean). Running clean reinstall."
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
  ensure_tls
  create_default_inbound
  verify_install

  step "Installation complete!"
  cat /root/xui-link.txt
  echo
  info "Management: x-ui   (interactive menu)"
  echo "  x-ui restart"
  echo "  x-ui status"
  echo "  cat /root/xui-link.txt"
}

main "$@"
