#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
none='\e[0m'

# Root & system check
if (( EUID != 0 )); then
    echo -e "${red}Please run this script as root.${none}"
    exit 1
fi

. /etc/os-release
if [[ "${ID:-}" != debian ]]; then
    echo -e "${red}This script requires Debian.${none}"
    exit 1
fi

# Configuration
# Official documentation: https://github.com/enfein/mieru/blob/v3.39.0/docs/server-install.md
MIERU_VERSION="3.39.0"
MIERU_CONFIG_DIR="/etc/mieru"
install -d -m 700 "$MIERU_CONFIG_DIR"
MIERU_CONFIG="${MIERU_CONFIG_DIR}/server-config.json"
MIERU_NODE="${MIERU_CONFIG_DIR}/mieru-node.txt"
server_address=""
port_start=""
port_end=""
node_name="Mieru"
transport="TCP"

MIERU_PORT_RANGE="${port_start}-${port_end}"
MIERU_ARCH="$(dpkg --print-architecture)"
case "$MIERU_ARCH" in
    amd64|arm64) ;;
    *)
        echo -e "${red}Unsupported architecture: ${MIERU_ARCH}${none}"
        exit 1
        ;;
esac

# Dependencies
apt-get update
apt-get install -y curl ca-certificates openssl jq iproute2 ufw

# Check every port in the selected transport before installing/reconfiguring mita.
if [[ "$transport" == TCP ]]; then
    LISTEN_PORTS="$(ss -H -ltn | awk '{print $4}')"
else
    LISTEN_PORTS="$(ss -H -lun | awk '{print $4}')"
fi
OCCUPIED_PORTS="$(awk -F: -v start="$port_start" -v end="$port_end" '
    $NF >= start && $NF <= end {print $NF}
' <<< "$LISTEN_PORTS" | sort -nu)"
if [[ -n "$OCCUPIED_PORTS" ]]; then
    echo -e "${red}Selected ${transport} range contains occupied ports:${none}"
    echo "$OCCUPIED_PORTS"
    echo "Choose another range, or stop the existing listener before rerunning."
    exit 1
fi

# install
MIERU_PACKAGE="mita_${MIERU_VERSION}_${MIERU_ARCH}.deb"
MIERU_URL="https://github.com/enfein/mieru/releases/download/v${MIERU_VERSION}/${MIERU_PACKAGE}"
echo -e "${green}Downloading mita v${MIERU_VERSION}...${none}"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
curl -fL --retry 3 --connect-timeout 15 --max-time 300 \
    "$MIERU_URL" -o "${TMP_DIR}/${MIERU_PACKAGE}"
dpkg -i "${TMP_DIR}/${MIERU_PACKAGE}"

systemctl daemon-reload
systemctl enable --now mita

# Wait for systemd to report that the mita service is running.
DAEMON_READY=false
for (( attempt=0; attempt<15; attempt++ )); do
    MIERU_STATUS="$(systemctl status mita --no-pager 2>&1)" || true
    if [[ "$MIERU_STATUS" == *'active (running)'* ]]; then
        DAEMON_READY=true
        break
    fi
    sleep 1
done
if [[ "$DAEMON_READY" != true ]]; then
    printf '%s\n' "$MIERU_STATUS"
    echo -e "${red}mita service did not reach active (running) status.${none}"
    exit 1
fi
mita version

# Credentials
MIERU_USERNAME="mieru_$(openssl rand -hex 8)"
MIERU_PASSWORD="$(openssl rand -hex 32)"
echo -e "${green}Selected ${transport} port range: ${MIERU_PORT_RANGE}${none}"

# Generate config & Mihomo node
jq -n --arg port_range "$MIERU_PORT_RANGE" --arg protocol "$transport" \
    --arg user "$MIERU_USERNAME" --arg password "$MIERU_PASSWORD" '
    {
        portBindings: [{portRange: $port_range, protocol: $protocol}],
        users: [{name: $user, password: $password}],
        loggingLevel: "INFO",
        mtu: 1400,
        dns: {dualStack: "PREFER_IPv4"}
    }' > "${TMP_DIR}/server-config.json"

# JSON string quoting is also valid YAML quoting, including special node names.
NODE_NAME_YAML="$(jq -cn --arg value "$node_name" '$value')"
SERVER_YAML="$(jq -cn --arg value "$server_address" '$value')"
cat > "${TMP_DIR}/mieru-node.txt" <<EOF
    - {name: ${NODE_NAME_YAML}, type: mieru, server: ${SERVER_YAML}, port-range: ${MIERU_PORT_RANGE}, transport: ${transport}, username: ${MIERU_USERNAME}, password: ${MIERU_PASSWORD}, multiplexing: MULTIPLEXING_OFF, handshake-mode: HANDSHAKE_NO_WAIT, udp: true}
EOF

# Import & start proxy service
mita replace config "${TMP_DIR}/server-config.json"
# Preserve the new plaintext credentials even if the subsequent startup fails.
install -m 600 "${TMP_DIR}/server-config.json" "$MIERU_CONFIG"
install -m 600 "${TMP_DIR}/mieru-node.txt" "$MIERU_NODE"
mita stop
mita start

# Installation and startup succeed when systemctl reports active (running).
PROXY_READY=false
for (( attempt=0; attempt<15; attempt++ )); do
    MIERU_STATUS="$(systemctl status mita --no-pager 2>&1)" || true
    if [[ "$MIERU_STATUS" == *'active (running)'* ]]; then
        PROXY_READY=true
        break
    fi
    sleep 1
done
if [[ "$PROXY_READY" != true ]]; then
    printf '%s\n' "$MIERU_STATUS"
    echo -e "${red}mita service did not reach active (running) status.${none}"
    exit 1
fi
if [[ "$transport" == TCP ]]; then
    ACTIVE_PORTS="$(ss -H -ltn | awk '{n=split($4, address, ":"); print address[n]}')"
else
    ACTIVE_PORTS="$(ss -H -lun | awk '{n=split($4, address, ":"); print address[n]}')"
fi
MISSING_PORTS="$(awk -v start="$port_start" -v end="$port_end" '
    {listening[$0]=1}
    END {for (port=start; port<=end; port++) if (!(port in listening)) print port}
' <<< "$ACTIVE_PORTS")"
if [[ -n "$MISSING_PORTS" ]]; then
    echo -e "${red}Missing listeners in ${transport} range ${MIERU_PORT_RANGE}:${none}"
    echo "$MISSING_PORTS"
    exit 1
fi


# UFW
FIREWALL_PROTOCOL="${transport,,}"
# UFW uses a colon for ranges; Mita and Mihomo use a hyphen.
UFW_PORT_RANGE="${port_start}:${port_end}"
if (( port_start == port_end )); then
    UFW_PORT_RANGE="$port_start"
fi
echo -e "${yellow}Allow ${transport} ${MIERU_PORT_RANGE} in your cloud security group.${none}"
echo "  sudo ufw allow ${UFW_PORT_RANGE}/${FIREWALL_PROTOCOL}"
if read -r -p "Execute this UFW command? [y/N]: " UFW_CONFIRM; then
    case "$UFW_CONFIRM" in
        y|Y|yes|YES|Yes) ufw allow "${UFW_PORT_RANGE}/${FIREWALL_PROTOCOL}" ;;
        *) echo -e "${yellow}Skipped UFW configuration.${none}" ;;
    esac
else
    echo -e "${yellow}Skipped UFW configuration.${none}"
fi


# Result
echo
echo -e "${green}Mihomo configuration (add to the proxies list):${none}"
cat "$MIERU_NODE"
echo
echo "Config   : ${MIERU_CONFIG} (import source; edit and re-import to change settings)"
echo "Native   : /etc/mita/server.conf.pb (managed by mita)"
echo "Node     : ${MIERU_NODE}"
echo "Service  : mita"
echo "Status   : sudo systemctl status mita"
echo "Logs     : sudo journalctl -u mita -n 50 --no-pager"
echo -e "${yellow}Keep server/client clocks synchronized. UFW has not been automatically enabled.${none}"
echo -e "${green}mita installed successfully and is running: active (running).${none}"
echo -e "${yellow}Verify connectivity from your client.${none}"
echo -e "${yellow}Redeployment generates new credentials. Update your client; old UFW rules are retained.${none}"
