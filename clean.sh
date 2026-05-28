#!/bin/bash
set -euo pipefail

# ============================================================
# Clean up all VM data (images, logs, temp files)
# Run: bash clean.sh
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="${SCRIPT_DIR}/images"

echo ">>> This will remove ALL VM data. Are you sure? (yes/no)"
read -r confirm
if [ "$confirm" != "yes" ]; then
    echo "Aborted."
    exit 0
fi

# Stop running VMs first
bash "${SCRIPT_DIR}/stop-vms.sh" 2>/dev/null || true

echo ">>> Removing VM disk images..."
rm -f "${VM_DIR}/vm1.qcow2" "${VM_DIR}/vm2.qcow2" "${VM_DIR}/vm3.qcow2"
rm -f "${VM_DIR}/vm1-data.qcow2" "${VM_DIR}/vm2-data.qcow2" "${VM_DIR}/vm3-data.qcow2"
rm -f "${VM_DIR}/vm1-seed.img" "${VM_DIR}/vm2-seed.img" "${VM_DIR}/vm3-seed.img"

echo ">>> Removing temporary files..."
rm -f /tmp/qemu-vm{1,2,3}-{serial.log,monitor.sock}
rm -f "${VM_DIR}/vm"{1,2,3}".pid"
rm -f "${VM_DIR}/SHA256SUMS"

echo ">>> Cleanup complete."
echo "Base image NOT removed: ${VM_DIR}/noble-server-cloudimg-amd64.img"
echo "To remove it too: rm ${VM_DIR}/noble-server-cloudimg-amd64.img"
