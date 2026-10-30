#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
none='\e[0m'

# Root check
if (( EUID != 0 )); then
    echo -e "${red}Please run this script as root.${none}"
    exit 1
fi


# Configuration
SING_BOX_VERSION="1.14.4"
SING_BOX_BIN="/usr/local/bin/sing-box-anytls"
ANYTLS_CONFIG_DIR="/etc/sing-box-anytls"
ANYTLS_CONFIG="${ANYTLS_CONFIG_DIR}/config.json"
ANYTLS_NODE="${ANYTLS_CONFIG_DIR}/anytls-node.txt"
ANYTLS_SERVICE="/etc/systemd/system/sing-box-anytls.service"
CERT_HOOK="/etc/letsencrypt/renewal-hooks/deploy/sing-box-anytls"

# Set true to request a Let's Encrypt certificate; false uses a self-signed certificate.
request_cert=false
# For Let's Encrypt, use a domain you own pointing directly to this VPS.
# Self-signed mode also accepts the VPS IPv4 address.
domain=""
email=""
node_name="AnyTLS"
fingerprint="chrome"

# Config check
if [[ -z "$domain" ]]; then
    read -r -p "Domain or VPS IPv4 address: " domain
fi
if [[ "$request_cert" == true && -z "$email" ]]; then
    read -r -p "Email for Let's Encrypt: " email
fi

# -----------------------
# Architecture & dependencies
# -----------------------
case "$(uname -m)" in
    x86_64|amd64) SING_BOX_ARCH="amd64" ;;
    aarch64|arm64) SING_BOX_ARCH="arm64" ;;
    *)
        echo -e "${red}Unsupported architecture: $(uname -m)${none}"
        exit 1
        ;;
esac

apt-get update
apt-get install -y curl tar openssl ca-certificates iproute2 ufw
if [[ "$request_cert" == true ]]; then
    apt-get install -y certbot
    # HTTP-01 validation and future standalone renewals require port 80.
    LISTEN_PORTS="$(ss -H -ltn | awk '{print $4}')"
    if grep -Eq '(^|:)80$' <<< "$LISTEN_PORTS"; then
        echo -e "${red}TCP port 80 is occupied. Standalone certificate issuance/renewal requires it to be free.${none}"
        exit 1
    fi
fi

# Download sing-box
TMP_DIR="$(mktemp -d)"
cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SING_BOX_PACKAGE="sing-box-${SING_BOX_VERSION}-linux-${SING_BOX_ARCH}"
SING_BOX_URL="https://github.com/SagerNet/sing-box/releases/download/v${SING_BOX_VERSION}/${SING_BOX_PACKAGE}.tar.gz"
echo -e "${green}Downloading sing-box v${SING_BOX_VERSION}...${none}"
curl -fL --retry 3 "$SING_BOX_URL" -o "${TMP_DIR}/sing-box.tar.gz"
tar -xzf "${TMP_DIR}/sing-box.tar.gz" -C "$TMP_DIR"
NEW_BIN="${TMP_DIR}/${SING_BOX_PACKAGE}/sing-box"
if [[ ! -f "$NEW_BIN" ]]; then
    echo -e "${red}sing-box binary not found.${none}"
    exit 1
fi
"$NEW_BIN" version


# Random port & password
LISTEN_PORTS="$(ss -H -lntu | awk '{print $5}')"
while true; do
    ANYTLS_PORT="$(shuf -i 10000-65535 -n 1)"
    if ! grep -Eq "(^|:)${ANYTLS_PORT}$" <<< "$LISTEN_PORTS"; then
        break
    fi
done
ANYTLS_PASSWORD="$(openssl rand -hex 32)"
echo -e "${green}Generated port: ${ANYTLS_PORT}${none}"


# UFW
if [[ "$request_cert" == true ]]; then
    echo -e "${yellow}Point all A/AAAA records for ${domain} to this VPS (DNS only, no CDN proxy).${none}"
    echo -e "${yellow}Allow TCP 80 in your cloud security group.${none}"
    echo "  ufw allow 80/tcp"
fi
echo -e "${yellow}Allow TCP ${ANYTLS_PORT} in your cloud security group.${none}"
echo "  ufw allow ${ANYTLS_PORT}/tcp"
if read -r -p "Execute these UFW commands? [y/N]: " UFW_CONFIRM; then
    case "$UFW_CONFIRM" in
        y|Y|yes|YES|Yes)
            if [[ "$request_cert" == true ]]; then
                ufw allow 80/tcp
            fi
            ufw allow "${ANYTLS_PORT}/tcp"
            ;;
        *) echo -e "${yellow}Skipped UFW configuration.${none}" ;;
    esac
else
    echo -e "${yellow}Skipped UFW configuration.${none}"
fi


# Certificate
if [[ "$request_cert" == true ]]; then
    CERT_NAME="sing-box-anytls-${domain}"
    CERT_DIR="/etc/letsencrypt/live/${CERT_NAME}"
    # Running this mode accepts the Let's Encrypt subscriber agreement.
    certbot certonly --standalone --non-interactive --agree-tos \
        --email "$email" --preferred-challenges http \
        --cert-name "$CERT_NAME" -d "$domain" --keep-until-expiring
    CLIENT_INSECURE=0
    SKIP_CERT_VERIFY=false
else
    CERT_DIR="${ANYTLS_CONFIG_DIR}/certs"
    mkdir -p "$CERT_DIR"
    chmod 700 "$ANYTLS_CONFIG_DIR" "$CERT_DIR"
    CERT_SAN="DNS:${domain}"
    if [[ "$domain" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        CERT_SAN="IP:${domain}"
    fi
    openssl req -x509 -nodes -newkey rsa:2048 -sha256 -days 3650 \
        -subj "/CN=${domain}" -addext "subjectAltName=${CERT_SAN}" \
        -keyout "${CERT_DIR}/privkey.pem" -out "${CERT_DIR}/fullchain.pem"
    chmod 600 "${CERT_DIR}/privkey.pem" "${CERT_DIR}/fullchain.pem"
    CLIENT_INSECURE=1
    SKIP_CERT_VERIFY=true
fi


# Generate & test config
cat > "${TMP_DIR}/config.json" <<EOF
{
    "log": {"level": "info", "timestamp": true},
    "inbounds": [
        {
            "type": "anytls",
            "tag": "anytls-in",
            "listen": "0.0.0.0",
            "listen_port": ${ANYTLS_PORT},
            "users": [{"name": "user", "password": "${ANYTLS_PASSWORD}"}],
            "tls": {
                "enabled": true,
                "server_name": "${domain}",
                "certificate_path": "${CERT_DIR}/fullchain.pem",
                "key_path": "${CERT_DIR}/privkey.pem"
            }
        }
    ],
    "outbounds": [{"type": "direct", "tag": "direct"}],
    "route": {"final": "direct"}
}
EOF
"$NEW_BIN" check -c "${TMP_DIR}/config.json"

mkdir -p "$ANYTLS_CONFIG_DIR"
chmod 700 "$ANYTLS_CONFIG_DIR"
for config_file in "$ANYTLS_CONFIG" "$ANYTLS_SERVICE" "$ANYTLS_NODE" "$CERT_HOOK"; do
    if [[ -f "$config_file" ]]; then
        backup_file="${config_file}.bak.$(date +%Y%m%d-%H%M%S)"
        # Certbot executes executable files in deploy/, so store hook backups elsewhere.
        if [[ "$config_file" == "$CERT_HOOK" ]]; then
            backup_file="${ANYTLS_CONFIG_DIR}/renewal-hook.bak.$(date +%Y%m%d-%H%M%S)"
        fi
        cp -a "$config_file" "$backup_file"
        echo -e "${yellow}Old config backed up to: ${backup_file}${none}"
    fi
done
# Use rename so upgrading a running executable does not fail with ETXTBSY.
install -m 0755 "$NEW_BIN" "${SING_BOX_BIN}.new"
mv -f "${SING_BOX_BIN}.new" "$SING_BOX_BIN"
install -m 600 "${TMP_DIR}/config.json" "$ANYTLS_CONFIG"


# -----------------------
# Systemd service
# -----------------------
cat > "$ANYTLS_SERVICE" <<EOF
[Unit]
Description=sing-box AnyTLS Server
Documentation=https://sing-box.sagernet.org/
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SING_BOX_BIN} run -c ${ANYTLS_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$ANYTLS_SERVICE"

systemctl daemon-reload
systemctl enable sing-box-anytls
systemctl restart sing-box-anytls
sleep 2
if ! systemctl is-active --quiet sing-box-anytls; then
    echo -e "${red}sing-box AnyTLS failed to start.${none}"
    systemctl status sing-box-anytls --no-pager || true
    journalctl -u sing-box-anytls -n 30 --no-pager || true
    exit 1
fi


# -----------------------
# Certificate auto-renewal
# -----------------------
if [[ "$request_cert" == true ]]; then
    mkdir -p "$(dirname "$CERT_HOOK")"
    cat > "$CERT_HOOK" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${RENEWED_LINEAGE:-}" == "${CERT_DIR}" ]] && systemctl is-active --quiet sing-box-anytls; then
    ${SING_BOX_BIN} check -c ${ANYTLS_CONFIG}
    systemctl restart sing-box-anytls
fi
EOF
    chmod 700 "$CERT_HOOK"
    systemctl enable --now certbot.timer
elif [[ -f "$CERT_HOOK" ]]; then
    # The old hook has already been backed up above. Leave other Certbot jobs alone.
    rm -f "$CERT_HOOK"
fi


# -----------------------
# Save client configuration
# -----------------------
ANYTLS_URL="anytls://${ANYTLS_PASSWORD}@${domain}:${ANYTLS_PORT}?sni=${domain}&insecure=${CLIENT_INSECURE}#${node_name}"
cat > "$ANYTLS_NODE" <<EOF
AnyTLS URL
==========
${ANYTLS_URL}

Mihomo Config
=============
- name: "${node_name}"
  type: anytls
  server: "${domain}"
  port: ${ANYTLS_PORT}
  password: "${ANYTLS_PASSWORD}"
  client-fingerprint: ${fingerprint}
  udp: true
  sni: "${domain}"
  skip-cert-verify: ${SKIP_CERT_VERIFY}
EOF
chmod 600 "$ANYTLS_NODE"


# -----------------------
# Result
# -----------------------
echo
echo -e "${green}Client configuration:${none}"
cat "$ANYTLS_NODE"
echo
echo "Config      : ${ANYTLS_CONFIG}"
echo "Node        : ${ANYTLS_NODE}"
echo "Certificate : ${CERT_DIR}/fullchain.pem"
echo "Service     : sing-box-anytls"
if [[ "$request_cert" == true ]]; then
    echo -e "${yellow}Keep TCP 80 free and reachable for certificate renewal.${none}"
else
    echo -e "${yellow}Using a self-signed certificate; client certificate verification is disabled.${none}"
fi
# A previous anytls-go installation is independent and is not stopped here.
if systemctl is-active --quiet anytls; then
    echo -e "${yellow}Legacy anytls.service is still running. After testing the new node, disable it with: systemctl disable --now anytls${none}"
fi
