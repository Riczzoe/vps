#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
none='\e[0m'

# -----------------------
# Root check
# -----------------------
if (( EUID != 0 )); then
    echo -e "${red}Please run this script as root.${none}"
    exit 1
fi


# -----------------------
# Configuration
# -----------------------
SS_VERSION="1.25.0"
SS_METHOD="2022-blake3-aes-256-gcm"

SS_CONFIG_DIR="/etc/shadowsocks-rust"
SS_CONFIG="${SS_CONFIG_DIR}/config.json"
SS_BIN="/usr/local/bin/ssserver"
SS_SERVICE="/etc/systemd/system/shadowsocks-rust.service"
SS_NODE="${SS_CONFIG_DIR}/ss2022-node.txt"


# -----------------------
# Dependencies
# -----------------------
apt-get update
apt-get install -y curl tar xz-utils openssl ca-certificates ufw


# -----------------------
# Architecture
# -----------------------
ARCH="$(uname -m)"

case "$ARCH" in
    x86_64|amd64)
        # SS_ARCH="x86_64-unknown-linux-gnu"
        SS_ARCH="x86_64-unknown-linux-musl"
        ;;
    aarch64|arm64)
        # SS_ARCH="aarch64-unknown-linux-gnu"
        SS_ARCH="aarch64-unknown-linux-musl"
        ;;
    *)
        echo -e "${red}Unsupported architecture: ${ARCH}${none}"
        exit 1
        ;;
esac


# -----------------------
# Download shadowsocks-rust
# -----------------------
TMP_DIR="$(mktemp -d)"

cleanup() {
    rm -rf "$TMP_DIR"
}
trap cleanup EXIT

SS_TARBALL="shadowsocks-v${SS_VERSION}.${SS_ARCH}.tar.xz"
SS_URL="https://github.com/shadowsocks/shadowsocks-rust/releases/download/v${SS_VERSION}/${SS_TARBALL}"

echo -e "${green}Downloading shadowsocks-rust v${SS_VERSION}...${none}"

curl -fL "$SS_URL" -o "${TMP_DIR}/${SS_TARBALL}"
tar -xJf "${TMP_DIR}/${SS_TARBALL}" -C "$TMP_DIR"

SSSERVER_PATH="$(find "$TMP_DIR" -type f -name ssserver -print -quit)"

if [[ -z "$SSSERVER_PATH" ]]; then
    echo -e "${red}ssserver binary not found.${none}"
    exit 1
fi

install -m 0755 "$SSSERVER_PATH" "$SS_BIN"


# -----------------------
# Random port
# -----------------------
while true; do
    SS_PORT="$(shuf -i 10000-65535 -n 1)"

    if ! ss -H -lntu | awk '{print $5}' | grep -Eq "(^|:)${SS_PORT}$"; then
        break
    fi
done
echo -e "${green}Generated port: ${SS_PORT}${none}"


# -----------------------
# Generate SS2022 key
# -----------------------
# 2022-blake3-aes-256-gcm requires a 32-byte PSK.
# Base64 representation of 32 random bytes is used as password.
SS_PASSWORD="$(openssl rand -base64 32 | tr -d '\n')"
if [[ -z "$SS_PASSWORD" ]]; then
    echo -e "${red}Failed to generate SS2022 password.${none}"
    exit 1
fi


# -----------------------
# Configuration
# -----------------------
mkdir -p "$SS_CONFIG_DIR"

cat > "$SS_CONFIG" <<EOF
{
    "server": "::",
    "server_port": ${SS_PORT},
    "password": "${SS_PASSWORD}",
    "method": "${SS_METHOD}",
    "mode": "tcp_and_udp"
}
EOF

chmod 600 "$SS_CONFIG"


# -----------------------
# Systemd service
# -----------------------
cat > "$SS_SERVICE" <<EOF
[Unit]
Description=Shadowsocks Rust Server
Documentation=https://github.com/shadowsocks/shadowsocks-rust
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${SS_BIN} -c ${SS_CONFIG}
Restart=on-failure
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

# Start service
systemctl daemon-reload
systemctl enable shadowsocks-rust
systemctl restart shadowsocks-rust

sleep 2


# -----------------------
# Check service
# -----------------------
if ! systemctl is-active --quiet shadowsocks-rust; then
    echo -e "${red}shadowsocks-rust failed to start.${none}"
    echo
    systemctl status shadowsocks-rust --no-pager || true
    exit 1
fi

# -----------------------
# Save Mihomo node
# -----------------------
cat > "$SS_NODE" <<EOF
- name: "SS2022"
  type: ss
  server:
  port: ${SS_PORT}
  cipher: ${SS_METHOD}
  password: "${SS_PASSWORD}"
  udp: true
EOF

chmod 600 "$SS_NODE"


# -----------------------
# UFW
# -----------------------
echo
echo -e "${yellow}The following commands will be executed:${none}"
echo
echo "  ufw allow ${SS_PORT}/tcp"
echo "  ufw allow ${SS_PORT}/udp"
echo

read -r -p "Execute these UFW commands? [y/N]: " UFW_CONFIRM

case "$UFW_CONFIRM" in
    y|Y|yes|YES|Yes)
        ufw allow "${SS_PORT}/tcp"
        ufw allow "${SS_PORT}/udp"

        echo
        echo -e "${green}UFW rules added successfully.${none}"
        ;;
    *)
        echo
        echo -e "${yellow}Skipped UFW configuration.${none}"
        ;;
esac

# -----------------------
# Result
# -----------------------
echo
echo -e "${green}========================================${none}"
echo
echo "Config   : ${SS_CONFIG}"
echo
echo -e "${green}Mihomo configuration:${none}"
echo
cat "$SS_NODE"
echo


