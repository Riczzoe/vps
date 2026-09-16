#!/usr/bin/env bash
set -euo pipefail

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
none='\e[0m'

if (( EUID != 0 )); then
    echo -e "${red}Please run this script as root.${none}"
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# -----------------------
# Configuration
# -----------------------
XRAY_VERSION="v26.3.27"
XRAY_CONFIG="/usr/local/etc/xray/config.json"
CLIENT_CONFIG="/root/vless-reality-node.txt"

server_ip=""
node_name="VLESS_R"
port=443
domain="www.tesla.com"
fingerprint="chrome"
spiderx=""


# -----------------------
# Dependencies
# -----------------------
apt-get update
apt-get install -y curl openssl


# -----------------------
# Install Xray
# -----------------------
echo -e "${yellow}Install Xray-core ${XRAY_VERSION}${none}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install --version "$XRAY_VERSION"


# -----------------------
# Generate credentials
# -----------------------
uuid=$(cat /proc/sys/kernel/random/uuid)
key_output=$(/usr/local/bin/xray x25519)
private_key=$(awk -F': ' '/^PrivateKey:/ {print $2}' <<< "$key_output")
public_key=$(awk -F': ' '/^Password \(PublicKey\):/ {print $2}' <<< "$key_output")
short_id=$(openssl rand -hex 8)


# -----------------------
# Generate config & Backup 
# -----------------------
temp_config="$(mktemp --suffix=.json)"
trap 'rm -f "$temp_config"' EXIT

sed \
    -e "s|__PORT__|$port|g" \
    -e "s|__UUID__|$uuid|g" \
    -e "s|__DOMAIN__|$domain|g" \
    -e "s|__PRIVATE_KEY__|$private_key|g" \
    -e "s|__SHORT_ID__|$short_id|g" \
    "${SCRIPT_DIR}/config.json.template" \
    > "$temp_config"

# Test new config before touching the current config
/usr/local/bin/xray run -test -config "$temp_config"

if [[ -f "$XRAY_CONFIG" ]]; then
    backup_file="${XRAY_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
    cp -a "$XRAY_CONFIG" "$backup_file"

    echo -e "${yellow}Old config backed up to:${none}"
    echo "$backup_file"
fi


# -----------------------
# Restart Xray
# -----------------------
install -m 644 "$temp_config" "$XRAY_CONFIG"
systemctl restart xray


# -----------------------
# VLESS URL
# -----------------------
vless_reality_url="vless://${uuid}@${server_ip}:${port}?flow=xtls-rprx-vision&encryption=none&type=tcp&security=reality&sni=${domain}&fp=${fingerprint}&pbk=${public_key}&sid=${short_id}#${node_name}"


cat > "$CLIENT_CONFIG" <<EOF
VLESS URL
=========

${vless_reality_url}


Mihomo Config
=============

- name: "${node_name}"
  type: vless
  server: ${server_ip}
  port: ${port}
  uuid: ${uuid}
  network: tcp
  tls: true
  udp: true
  flow: xtls-rprx-vision
  servername: ${domain}
  client-fingerprint: ${fingerprint}
  reality-opts:
    public-key: ${public_key}
    short-id: ${short_id}
EOF

chmod 600 "$CLIENT_CONFIG"

echo
echo -e "${green}Client configuration:${none}"
echo
cat "$CLIENT_CONFIG"

echo
echo -e "${green}Saved to:${none} ${CLIENT_CONFIG}"
