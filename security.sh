#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

red='\e[91m'
green='\e[92m'
yellow='\e[93m'
none='\e[0m'

# root check
if (( EUID != 0 )); then
    echo -e "${red}Please run this script as root.${none}"
    exit 1
fi

# -----------------------
# Configuration
# -----------------------
SSHD_CONFIG="/etc/ssh/sshd_config"
SSH_HARDENING_CONFIG="/etc/ssh/sshd_config.d/00-vps-security.conf"
EXTRA_TCP_PORTS=(443 8443)
EXTRA_UDP_PORTS=()

if systemctl cat ssh.service >/dev/null 2>&1; then
    SSH_SERVICE="ssh"
else
    SSH_SERVICE="sshd"
fi

if ufw status | grep -q '^Status: active'; then
    UFW_WAS_ACTIVE=1
else
    UFW_WAS_ACTIVE=0
fi


# -----------------------
# Dependencies
# -----------------------
apt-get update
apt-get install -y ufw fail2ban


# -----------------------
# Backup
# -----------------------
backup_dir="/root/ssh-security-backup/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$backup_dir"

cp -a /etc/ssh "$backup_dir/"
cp -a /etc/ufw "$backup_dir/" 2>/dev/null || true
cp -a /etc/default/ufw "$backup_dir/ufw-default" 2>/dev/null || true
cp -a /etc/fail2ban "$backup_dir/" 2>/dev/null || true

echo -e "${green}Backup:${none} $backup_dir"


if [[ ! -s /root/.ssh/authorized_keys ]]; then
    echo -e "${red}No root authorized_keys found.${none}"
    exit 1
fi

# -----------------------
# Rollback
# -----------------------
rollback() {
    trap - ERR
    set +e

    echo -e "${red}SSH setup failed. Rolling back...${none}"

    rm -rf /etc/ssh
    rm -rf /etc/fail2ban
    cp -a "$backup_dir/ssh" /etc/

    [[ -d "$backup_dir/ufw" ]] && {
        rm -rf /etc/ufw
        cp -a "$backup_dir/ufw" /etc/
    }

    [[ -f "$backup_dir/ufw-default" ]] &&
        cp -a "$backup_dir/ufw-default" /etc/default/ufw

    cp -a "$backup_dir/fail2ban" /etc/

    if (( UFW_WAS_ACTIVE )); then
        ufw reload
    else
        ufw --force disable
    fi

    systemctl restart "$SSH_SERVICE"

    exit 1
}

trap rollback ERR


# -----------------------
# SSH port
# -----------------------
old_port=$(
    sshd -T |
    awk '$1 == "port" {print $2; exit}'
)

while :; do
    new_port=$(shuf -i 20000-60000 -n 1)

    if ! ss -H -lnt "sport = :$new_port" | grep -q .; then
        break
    fi
done

echo -e "${yellow}SSH port:${none} $old_port -> $new_port"


# -----------------------
# SSH config
# -----------------------
cat > "$SSH_HARDENING_CONFIG" <<EOF
Port $new_port
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin prohibit-password
EOF

# -----------------------
# Validate SSH
# -----------------------
sshd -t
effective_config=$(sshd -T)

grep -q "^port $new_port$" <<< "$effective_config"
grep -q '^pubkeyauthentication yes$' <<< "$effective_config"
grep -q '^passwordauthentication no$' <<< "$effective_config"
grep -q '^kbdinteractiveauthentication no$' <<< "$effective_config"
grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<< "$effective_config"

# -----------------------
# UFW
# -----------------------
if ufw status | grep -Eiq "^${new_port}/tcp.*DENY"; then
    echo -e "${red}UFW already denies ${new_port}/tcp.${none}"
    rollback
fi

for port in "${EXTRA_TCP_PORTS[@]}"; do
    ufw allow "${port}/tcp"
done

for port in "${EXTRA_UDP_PORTS[@]}"; do
    ufw allow "${port}/udp"
done

ufw allow "$new_port/tcp"


# -----------------------
# IPv6 firewall
# -----------------------
if ip -6 addr show scope global | grep -q 'inet6'; then
    grep -q '^IPV6=yes' /etc/default/ufw
fi

ufw --force enable


# -----------------------
# Restart SSH
# -----------------------
systemctl restart "$SSH_SERVICE"

sleep 1
ss -H -lnt "sport = :$new_port" | grep -q .


# -----------------------
# Fail2ban
# -----------------------
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $new_port
maxretry = 5
findtime = 10m
bantime = 1h
EOF

fail2ban-client -t
systemctl enable --now fail2ban


# -----------------------
# Test SSH login
# -----------------------
server_ip=$(hostname -I | awk '{print $1}')

echo
echo -e "${yellow}Keep this SSH session open.${none}"
echo "Open a new terminal and test:"
echo
echo "ssh -p $new_port root@$server_ip"
echo

read -r -p "Did the key login succeed? [y/N] " answer

if [[ "$answer" != "y" && "$answer" != "Y" ]]; then
    rollback
fi

trap - ERR

echo -e "${green}SSH hardening completed.${none}"
echo -e "${green}SSH port:${none} $new_port"
