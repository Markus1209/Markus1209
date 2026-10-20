#!/usr/bin/env bash
# language: bash, file: scorched_earth.sh, runtime: Linux/POSIX, target: test VM only
# WARNING: DESTRUCTIVE. Run ONLY in a disposable VM you own. This bricks the guest.
# Legit use: malware detonation labs, IR/EDR testing, red-team range detonation,
# stress-testing snapshot/rollback, chaos/resilience drills on throwaway guests.

set -u
# --- safety rail: refuse to run on bare metal unless FORCE_BAREMETAL=1 ---
if [ "${FORCE_BAREMETAL:-0}" != "1" ]; then
  if grep -qiE 'hypervisor|qemu|vmware|virtualbox|kvm|bhyve' /proc/cpuinfo 2>/dev/null; then
    : # hypervisor detected, proceed
  else
    echo "REFUSING: no hypervisor flag detected. This script bricks the host." >&2
    echo "If you truly want this on bare metal: FORCE_BAREMETAL=1 $0" >&2
    exit 1
  fi
fi

echo "[*] scortched earth starting on $(hostname) at $(date -Is)"

# 1) Kill userland — stop services, then everything that survives.
echo "[*] stopping services"
systemctl stop --no-block '*' 2>/dev/null || true
systemctl kill -s SIGKILL --all 2>/dev/null || true

# 2) Wipe data volumes fast (blkdiscard = instant TRIM, near-instant on SSD/VM disk)
echo "[*] discarding block devices"
for dev in /dev/sd* /dev/nvme*n* /dev/vd* /dev/xvd*; do
  [ -b "$dev" ] || continue
  case "$dev" in
    *[0-9]|*p[0-9]) continue ;;   # skip partitions, hit whole disks
  esac
  blkdiscard -f "$dev" 2>/dev/null || dd if=/dev/urandom of="$dev" bs=4M status=none 2>/dev/null &
done
wait

# 3) Overwrite and unlink every file we can reach.
echo "[*] shredding filesystem"
find / -xdev -type f \( -not -path '/proc/*' -not -path '/sys/*' -not -path '/dev/*' \) \
  -exec shred -n 1 -z -u {} + 2>/dev/null

# 4) Nuke directory trees that shred can't unlink cleanly.
for d in /var /home /root /tmp /etc /opt /srv /usr /boot; do
  rm -rf --one-file-system -- "$d" 2>/dev/null
done

# 5) Truncate the journal + zero MBR/GPT so boot dies.
echo "[*] zeroing boot sectors"
for dev in /dev/sd* /dev/nvme*n* /dev/vd* /dev/xvd*; do
  [ -b "$dev" ] || continue
  dd if=/dev/zero of="$dev" bs=1M count=16 conv=notrunc status=none 2>/dev/null
done

# 6) Flood memory so nothing can recover gracefully (VM balloon has to give).
echo "[*] memory pressure"
: > /tmp/.pressure 2>/dev/null
while :; do
  dd if=/dev/zero of=/tmp/.pressure bs=1M count=1024 status=none 2>/dev/null || break
done &
MEM_PID=$!
sleep 30

# 7) Final act: force panic/reboot so the guest can't run fsck to recover.
echo "[*] triggering panic"
sync
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo c > /proc/sysrq-trigger 2>/dev/null || { echo b > /proc/sysrq-trigger 2>/dev/null; }
kill -9 "$MEM_PID" 2>/dev/null
exit 0
