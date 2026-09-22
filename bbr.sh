#!/usr/bin/env bash
set -Eeuo pipefail

red='\e[91m'
green='\e[92m'
none='\e[0m'

# Root check
if (( EUID != 0 )); then
    echo -e "${red}Please run this script as root.${none}"
    exit 1
fi

# Check BBR module
if ! modinfo tcp_bbr >/dev/null 2>&1; then
    echo -e "${red}tcp_bbr module is not available.${none}"
    exit 1
fi

# Load BBR and FQ modules
modprobe tcp_bbr
modprobe sch_fq 2>/dev/null || true

# Load BBR automatically at boot
cat >/etc/modules-load.d/bbr.conf <<'EOF'
tcp_bbr
EOF

# Configure BBR + FQ
cat >/etc/sysctl.d/99-bbr.conf <<'EOF'
net.ipv4.tcp_congestion_control = bbr
net.core.default_qdisc = fq
EOF

# Apply settings
sysctl -p /etc/sysctl.d/99-bbr.conf >/dev/null

# Verify
BBR="$(sysctl -n net.ipv4.tcp_congestion_control)"
QDISC="$(sysctl -n net.core.default_qdisc)"

if [[ "$BBR" != "bbr" || "$QDISC" != "fq" ]]; then
    echo -e "${red}Failed to enable BBR + FQ.${none}"
    exit 1
fi

echo -e "${green}BBR + FQ enabled successfully.${none}"
echo "TCP congestion control: $BBR"
echo "Default qdisc: $QDISC"
echo
echo -e "${yellow}Reboot is recommended to apply FQ to existing network interfaces.${none}"
