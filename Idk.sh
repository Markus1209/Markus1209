#!/usr/bin/env bash
# language: bash, file: instant_ash.sh, runtime: Linux/POSIX, target: disposable test VM only
# DESTRUCTIVE. Hypervisor-gated. Zero wait: blkdiscard all disks, zero boot sectors, panic.
# Legit use: malware detonation labs, snapshot/rollback drills, EDR/IR range testing.

set -u
if [ "${FORCE_BAREMETAL:-0}" != "1" ]; then
  grep -qiE 'hypervisor|qemu|vmware|virtualbox|kvm|bhyve' /proc/cpuinfo 2>/dev/null \
    || { echo "REFUSING: not a hypervisor guest. Override: FORCE_BAREMETAL=1" >&2; exit 1; }
fi

echo "[*] instant ash on $(hostname) at $(date -Is)"

# 1) Instantly TRIM every whole disk in parallel — SSD/thin-provisioned VM disk = gone now.
#    dd fallback only where blkdiscard fails (non-TRIM backing store).
for dev in /dev/sd* /dev/nvme*n* /dev/vd* /dev/xvd*; do
  [ -b "$dev" ] || continue
  case "$dev" in *[0-9]|*p[0-9]) continue ;; esac
  blkdiscard -f "$dev" 2>/dev/null \
    || dd if=/dev/zero of="$dev" bs=16M status=none 2>/dev/null &
done

# 2) Zero the front of every disk in parallel — kills MBR/GPT/bootloader in one shot.
for dev in /dev/sd* /dev/nvme*n* /dev/vd* /dev/xvd*; do
  [ -b "$dev" ] || continue
  dd if=/dev/zero of="$dev" bs=1M count=8 conv=notrunc status=none 2>/dev/null &
done
wait

# 3) Panic immediately — no fsync recovery, no journal replay, no graceful shutdown.
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
echo c > /proc/sysrq-trigger 2>/dev/null || echo b > /proc/sysrq-trigger 2>/dev/null
