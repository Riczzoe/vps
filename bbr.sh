# -----------------------
# Enable BBR
# -----------------------
cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
EOF

echo 'tcp_bbr' > /etc/modules-load.d/bbr.conf

modprobe tcp_bbr 2>/dev/null || true
sysctl --system
