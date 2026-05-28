#!/bin/bash
set -euo pipefail

# ============================================================
# Clean up TiKV/PD deployment state from VMs
# Does NOT remove VM images — only uninstalls TiKV/PD software
# and data from inside the VMs.
# ============================================================

declare -A VM_IP
VM_IP[1]="172.16.0.101"
VM_IP[2]="172.16.0.102"
VM_IP[3]="172.16.0.103"

SSH_USER="ubuntu"
SSH_PASS="ubuntu"
CLUSTER_NAME="tikv-cluster"

ssh_vm() {
    local ip=$1; shift
    sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 "${SSH_USER}@${ip}" "$@" 2>/dev/null
}

echo "========================================"
echo "Cleaning TiKV/PD Deployment State"
echo "========================================"
echo ""
echo "This will remove all TiKV/PD binaries, data, and configurations"
echo "from the VMs. VM disk images are NOT affected."
echo ""

# ============================================================
# Method 1: TiUP cluster destroy (if deployed via TiUP)
# ============================================================

if command -v tiup &>/dev/null; then
    export PATH="${HOME}/.tiup/bin:${PATH}"
    # Unset proxy so tiup can reach bridge IPs directly
    unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
    echo ">>> Checking for TiUP-managed cluster '${CLUSTER_NAME}'..."
    if tiup cluster list 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
        echo ">>> Stopping TiUP cluster '${CLUSTER_NAME}'..."
        tiup cluster stop "${CLUSTER_NAME}" -y 2>/dev/null || true
        echo ">>> Destroying TiUP cluster '${CLUSTER_NAME}'..."
        tiup cluster destroy "${CLUSTER_NAME}" -y 2>/dev/null || true
        echo "TiUP cluster destroyed."
    else
        echo "[skip] No TiUP cluster named '${CLUSTER_NAME}' found."
    fi
fi

# ============================================================
# Method 2: Manual cleanup on each VM (for manual deployment)
# ============================================================

echo ""
echo ">>> Cleaning manual deployment artifacts from VMs..."

for id in 1 2 3; do
    ip="${VM_IP[$id]}"
    echo -n "VM${id} (${ip}): "

    if ! ssh_vm "${ip}" "echo ok" 2>/dev/null; then
        echo "SSH unreachable, skipping"
        continue
    fi

    ssh_vm "${ip}" "
        timeout 10 sudo systemctl stop pd tikv 2>/dev/null || true
        timeout 10 sudo systemctl disable pd tikv 2>/dev/null || true
        sudo rm -f /etc/systemd/system/pd.service /etc/systemd/system/tikv.service
        timeout 10 sudo systemctl daemon-reload 2>/dev/null || true
        sudo rm -rf /opt/pd /opt/tikv /opt/tikv-deploy
        sudo rm -rf /data/pd /data/tikv
        sudo rm -f /usr/local/bin/pd-server /usr/local/bin/pd-ctl /usr/local/bin/tikv-server /usr/local/bin/tikv-ctl
        echo cleaned
    " 2>/dev/null || echo "cleanup failed"
done

echo ""
echo "=== Deployment state cleaned ==="
echo "VM images are preserved. To destroy VMs: bash clean.sh"
