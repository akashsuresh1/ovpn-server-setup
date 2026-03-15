#!/usr/bin/env bash
# =============================================================================
# OpenVPN server setup — Amazon Linux 2023 / EC2
# =============================================================================
set -euo pipefail

# ── Colour helpers ────────────────────────────────────────────────────────────
RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

info()    { echo -e "${CYAN}[info]${RESET}  $*"; }
success() { echo -e "${GREEN}[ok]${RESET}    $*"; }
warn()    { echo -e "${YELLOW}[warn]${RESET}  $*"; }
error()   { echo -e "${RED}[error]${RESET} $*" >&2; }
header()  { echo -e "\n${BOLD}── $* ──${RESET}"; }

# ── Root check ────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
  error "Run this script as root: sudo bash ovpn-server-setup.sh"
  exit 1
fi

# =============================================================================
# 1. USER INPUT
# =============================================================================
header "Configuration"

# ── VPN port ──────────────────────────────────────────────────────────────────
echo
warn "Using the default port 1194 makes your VPN easier to detect and block."
warn "A custom port (e.g. 32030, 443, 8080) is strongly recommended."
echo
read -rp "$(echo -e "${BOLD}VPN port${RESET} [default: 1194]: ")" VPN_PORT
VPN_PORT="${VPN_PORT:-1194}"
if ! [[ "$VPN_PORT" =~ ^[0-9]+$ ]] || (( VPN_PORT < 1 || VPN_PORT > 65535 )); then
  error "Invalid port: $VPN_PORT"
  exit 1
fi
success "Port set to $VPN_PORT"

# ── VPN subnet ────────────────────────────────────────────────────────────────
echo
read -rp "$(echo -e "${BOLD}VPN subnet${RESET} [default: 10.8.0.0]: ")" VPN_SUBNET
VPN_SUBNET="${VPN_SUBNET:-10.8.0.0}"
success "Subnet: $VPN_SUBNET/24"

# ── FreeDNS ───────────────────────────────────────────────────────────────────
echo
info "FreeDNS dynamic DNS keeps your hostname pointing at this instance after"
info "reboots. Leave blank to skip (you can add it manually later — see README)."
echo
read -rp "$(echo -e "${BOLD}FreeDNS update URL${RESET} (or press Enter to skip): ")" FREEDNS_URL
if [[ -n "$FREEDNS_URL" ]]; then
  success "FreeDNS URL recorded."
else
  warn "Skipping FreeDNS setup."
fi

# =============================================================================
# 2. DETECT ENVIRONMENT
# =============================================================================
header "Detecting environment"

WAN_IFACE=$(ip route show default | awk '/default/ {print $5}' | head -1)
if [[ -z "$WAN_IFACE" ]]; then
  error "Could not detect default network interface. Exiting."
  exit 1
fi
success "WAN interface: $WAN_IFACE"

PUBLIC_IP=$(curl -sf --max-time 5 https://checkip.amazonaws.com || \
            curl -sf --max-time 5 https://api.ipify.org || \
            echo "UNKNOWN")
success "Public IP: $PUBLIC_IP"

# =============================================================================
# 3. INSTALL PACKAGES
# =============================================================================
header "Installing packages"

info "Installing openvpn, easy-rsa, iptables-services..."
dnf install -y openvpn easy-rsa iptables-services -q
success "Packages installed."

# =============================================================================
# 4. PKI SETUP
# =============================================================================
header "Initialising PKI"

PKI_DIR=/etc/openvpn/easy-rsa

if [[ ! -d "$PKI_DIR" ]]; then
  mkdir -p "$PKI_DIR"
  cp -r /usr/share/easy-rsa/* "$PKI_DIR"/
fi

cd "$PKI_DIR"

if [[ ! -f pki/ca.crt ]]; then
  info "Initialising PKI..."
  ./easyrsa init-pki

  info "Building CA (no passphrase)..."
  EASYRSA_BATCH=1 ./easyrsa build-ca nopass

  info "Generating DH parameters (this takes a minute)..."
  ./easyrsa gen-dh

  info "Generating server certificate..."
  EASYRSA_BATCH=1 ./easyrsa build-server-full server nopass

  info "Generating TLS auth key..."
  openvpn --genkey secret "$PKI_DIR/ta.key"

  success "PKI initialised."
else
  warn "PKI already exists at $PKI_DIR/pki — skipping reinitialisation."
fi

# =============================================================================
# 5. SERVER CONFIG
# =============================================================================
header "Writing server config"

cat > /etc/openvpn/server/server.conf <<EOF
port ${VPN_PORT}
proto udp
dev tun

ca   ${PKI_DIR}/pki/ca.crt
cert ${PKI_DIR}/pki/issued/server.crt
key  ${PKI_DIR}/pki/private/server.key
dh   ${PKI_DIR}/pki/dh.pem

tls-auth ${PKI_DIR}/ta.key 0
key-direction 0

# AES-256-GCM preferred; CBC kept for older clients
data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
auth SHA256

server ${VPN_SUBNET} 255.255.255.0

push "redirect-gateway def1 bypass-dhcp"
push "dhcp-option DNS 1.1.1.1"
push "dhcp-option DNS 1.0.0.1"

# Reduce MTU to avoid EMSGSIZE drops on Nitro instances
mssfix 1300
tun-mtu 1500

keepalive 10 120
persist-key
persist-tun

user  nobody
group nobody

status /var/log/openvpn-status.log
verb 3

explicit-exit-notify 1
EOF

success "Server config written."

# =============================================================================
# 6. IP FORWARDING
# =============================================================================
header "Enabling IP forwarding"

SYSCTL_FILE=/etc/sysctl.d/99-openvpn.conf
cat > "$SYSCTL_FILE" <<EOF
net.ipv4.ip_forward = 1
EOF
sysctl -p "$SYSCTL_FILE" -q
success "ip_forward enabled and persisted via $SYSCTL_FILE"

# =============================================================================
# 7. IPTABLES
# =============================================================================
header "Configuring iptables"

# Flush existing rules
iptables -F
iptables -t nat -F
iptables -t mangle -F

# ── mangle: TCP MSS clamp (prevents MTU black-hole on tunnelled traffic) ──────
iptables -t mangle -A FORWARD -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu

# ── filter INPUT ──────────────────────────────────────────────────────────────
iptables -A INPUT -p udp --dport "${VPN_PORT}" -j ACCEPT
iptables -A INPUT -m state --state RELATED,ESTABLISHED -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p tcp --dport 22 -m state --state NEW -j ACCEPT
# DNS queries arriving from VPN clients (in case a local resolver is added later)
iptables -A INPUT -i tun0 -p udp --dport 53 -j ACCEPT
iptables -A INPUT -i tun0 -p tcp --dport 53 -j ACCEPT
iptables -A INPUT -j REJECT --reject-with icmp-host-prohibited

# ── filter FORWARD ────────────────────────────────────────────────────────────
iptables -A FORWARD -i tun0 -j ACCEPT
iptables -A FORWARD -o tun0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# ── nat POSTROUTING ───────────────────────────────────────────────────────────
iptables -t nat -A POSTROUTING -s "${VPN_SUBNET}/24" -o "${WAN_IFACE}" -j MASQUERADE

# ── Persist via iptables-services ─────────────────────────────────────────────
service iptables save
systemctl enable iptables
success "iptables rules written and saved."

# =============================================================================
# 8. START OPENVPN
# =============================================================================
header "Starting OpenVPN"

systemctl enable  openvpn-server@server
systemctl restart openvpn-server@server
sleep 2

if systemctl is-active --quiet openvpn-server@server; then
  success "openvpn-server@server is running."
else
  error "OpenVPN failed to start. Check: journalctl -u openvpn-server@server -n 50"
  exit 1
fi

# =============================================================================
# 9. FREEDNS DYNAMIC DNS
# =============================================================================
header "FreeDNS dynamic DNS"

if [[ -n "$FREEDNS_URL" ]]; then
  CRON_LINE="@reboot wget -q -O /tmp/freedns_update.log '${FREEDNS_URL}'"
  # Add only if not already present
  ( crontab -l 2>/dev/null | grep -v 'freedns'; echo "$CRON_LINE" ) | crontab -
  success "FreeDNS @reboot cron entry added."

  info "Running initial FreeDNS update..."
  wget -q -O /tmp/freedns_update.log "${FREEDNS_URL}" && \
    success "FreeDNS update sent. Response: $(cat /tmp/freedns_update.log)" || \
    warn "FreeDNS update request failed — check the URL."
else
  info "FreeDNS skipped."
fi

# =============================================================================
# 10. CLIENT CERTIFICATE GENERATION
# =============================================================================
header "Client certificates"

generate_client() {
  local CLIENT_NAME="$1"
  local OVPN_OUT="/root/${CLIENT_NAME}.ovpn"

  if [[ -f "${PKI_DIR}/pki/issued/${CLIENT_NAME}.crt" ]]; then
    warn "Certificate for '${CLIENT_NAME}' already exists — skipping generation."
  else
    info "Generating certificate for '${CLIENT_NAME}'..."
    cd "$PKI_DIR"
    EASYRSA_BATCH=1 ./easyrsa build-client-full "${CLIENT_NAME}" nopass
    success "Certificate generated."
  fi

  info "Building ${CLIENT_NAME}.ovpn..."
  cat > "$OVPN_OUT" <<OVPN
client
dev tun
proto udp

remote ${PUBLIC_IP} ${VPN_PORT}

resolv-retry infinite
nobind
persist-key
persist-tun

data-ciphers AES-256-GCM:AES-128-GCM:AES-256-CBC
data-ciphers-fallback AES-256-CBC
auth SHA256

remote-cert-tls server
key-direction 1
verb 3

<ca>
$(cat ${PKI_DIR}/pki/ca.crt)
</ca>

<cert>
$(openssl x509 -in ${PKI_DIR}/pki/issued/${CLIENT_NAME}.crt)
</cert>

<key>
$(cat ${PKI_DIR}/pki/private/${CLIENT_NAME}.key)
</key>

<tls-auth>
$(cat ${PKI_DIR}/ta.key)
</tls-auth>
OVPN

  success "Profile saved to: $OVPN_OUT"
}

echo
read -rp "$(echo -e "${BOLD}Generate client certificate(s) now?${RESET} [y/N]: ")" GEN_CLIENTS
GEN_CLIENTS="${GEN_CLIENTS:-n}"

if [[ "${GEN_CLIENTS,,}" == "y" ]]; then
  while true; do
    echo
    read -rp "$(echo -e "${BOLD}Client name${RESET} (e.g. laptop, phone, alice): ")" CLIENT_NAME
    CLIENT_NAME="${CLIENT_NAME// /-}"  # replace spaces with hyphens
    if [[ -z "$CLIENT_NAME" ]]; then
      warn "Name cannot be empty. Try again."
      continue
    fi
    generate_client "$CLIENT_NAME"
    echo
    read -rp "$(echo -e "${BOLD}Generate another client?${RESET} [y/N]: ")" ANOTHER
    ANOTHER="${ANOTHER:-n}"
    [[ "${ANOTHER,,}" == "y" ]] || break
  done
else
  info "Skipping client generation. See README for manual steps."
fi

# =============================================================================
# 11. SUMMARY
# =============================================================================
header "Setup complete"

echo
echo -e "  ${BOLD}Server address${RESET}   ${PUBLIC_IP}"
echo -e "  ${BOLD}Port${RESET}             ${VPN_PORT}/UDP"
echo -e "  ${BOLD}VPN subnet${RESET}       ${VPN_SUBNET}/24"
echo -e "  ${BOLD}WAN interface${RESET}    ${WAN_IFACE}"
echo -e "  ${BOLD}iptables${RESET}         saved, iptables-services enabled"
echo -e "  ${BOLD}OpenVPN${RESET}          running, enabled on boot"
if [[ -n "$FREEDNS_URL" ]]; then
  echo -e "  ${BOLD}FreeDNS${RESET}          @reboot cron set"
fi
echo
info "Client .ovpn profiles (if generated) are in /root/"
info "See README.md for: adding more clients, revoking certs, FreeDNS setup."
echo
warn "Ensure your EC2 security group allows inbound UDP ${VPN_PORT}."
echo
