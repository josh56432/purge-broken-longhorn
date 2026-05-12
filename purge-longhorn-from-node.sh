#!/usr/bin/env bash
# purge-longhorn-node.sh
# Cleans up Longhorn leftovers on a single Kubernetes node:
# iSCSI sessions, mounts, loop devices, and the replica data directory.
# Run this on EVERY node that had Longhorn running, as root.

set -uo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Run as root."
  exit 1
fi

say() { printf "\n=== %s ===\n" "$*"; }

# ---------------------------------------------------------------------------
say "1/6  Logging out of any active iSCSI sessions"
# Longhorn attaches volumes via iSCSI loopback. Stale sessions can prevent
# unmounting and pin loop devices.
if command -v iscsiadm >/dev/null 2>&1; then
  iscsiadm -m session 2>/dev/null | grep -i longhorn || echo "  no longhorn sessions"
  iscsiadm -m session -u 2>/dev/null || true
  # Remove cached node records too
  iscsiadm -m node -o delete 2>/dev/null || true
else
  echo "  iscsiadm not installed, skipping"
fi

# ---------------------------------------------------------------------------
say "2/6  Unmounting anything under Longhorn paths"
for mp in $(mount | awk '/longhorn/ {print $3}' | sort -r); do
  echo "  umount $mp"
  umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
done

# kubelet may have bind-mounts under /var/lib/kubelet/pods/*/volumes/kubernetes.io~csi
for mp in $(awk '/longhorn/ {print $5}' /proc/self/mountinfo 2>/dev/null | sort -ru); do
  echo "  umount $mp"
  umount "$mp" 2>/dev/null || umount -l "$mp" 2>/dev/null || true
done

# ---------------------------------------------------------------------------
say "3/6  Detaching any leftover loop devices pointing at longhorn files"
if command -v losetup >/dev/null 2>&1; then
  losetup -a 2>/dev/null | awk -F: '/longhorn/ {print $1}' | while read -r lo; do
    echo "  losetup -d $lo"
    losetup -d "$lo" 2>/dev/null || true
  done
fi

# ---------------------------------------------------------------------------
say "4/6  Removing Longhorn data directories"
# WARNING: this is destructive. Skip or comment out if you still want the data.
for d in /var/lib/longhorn /var/lib/longhorn-engine-binaries /opt/longhorn; do
  if [ -e "$d" ]; then
    echo "  rm -rf $d"
    rm -rf "$d"
  fi
done

# ---------------------------------------------------------------------------
say "5/6  Cleaning kubelet CSI sockets for the longhorn driver"
for d in /var/lib/kubelet/plugins/driver.longhorn.io \
         /var/lib/kubelet/plugins_registry/driver.longhorn.io-reg.sock; do
  if [ -e "$d" ]; then
    echo "  rm -rf $d"
    rm -rf "$d"
  fi
done

# ---------------------------------------------------------------------------
say "6/6  Restarting the kubelet / k3s"
# Picks up the removed CSI plugin and clears any cached volume mounts.
if systemctl is-active --quiet k3s; then
  systemctl restart k3s
  echo "  restarted k3s"
elif systemctl is-active --quiet k3s-agent; then
  systemctl restart k3s-agent
  echo "  restarted k3s-agent"
elif systemctl is-active --quiet kubelet; then
  systemctl restart kubelet
  echo "  restarted kubelet"
else
  echo "  no known kubelet service active; restart manually if needed"
fi

echo
echo "Node cleanup complete. Verify:"
echo "  mount | grep longhorn       (should be empty)"
echo "  ls /var/lib/longhorn        (should be 'No such file')"
echo "  losetup -a | grep longhorn  (should be empty)"
