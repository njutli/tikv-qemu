#!/bin/bash
set -euo pipefail

# ============================================================
# Start all 3 QEMU VMs for TiKV 3-Replica + 3-Node PD Cluster
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VM_DIR="${SCRIPT_DIR}/images"
BRIDGE="br0"

declare -A VM_IP
VM_IP[1]="172.16.0.101"
VM_IP[2]="172.16.0.102"
VM_IP[3]="172.16.0.103"

declare -A VM_MAC
VM_MAC[1]="52:54:00:12:34:01"
VM_MAC[2]="52:54:00:12:34:02"
VM_MAC[3]="52:54:00:12:34:03"

declare -A VM_SSH_PORT
VM_SSH_PORT[1]="2201"
VM_SSH_PORT[2]="2202"
VM_SSH_PORT[3]="2203"

# TiKV port forwarding (to host localhost)
declare -A VM_TIKV_PORT
VM_TIKV_PORT[1]="20160"
VM_TIKV_PORT[2]="20161"
VM_TIKV_PORT[3]="20162"

declare -A VM_TIKV_STATUS_PORT
VM_TIKV_STATUS_PORT[1]="20180"
VM_TIKV_STATUS_PORT[2]="20181"
VM_TIKV_STATUS_PORT[3]="20182"

# PD port forwarding (host -> VM1 only, cluster is internally routable)
PD_CLIENT_PORT="2379"
PD_PEER_PORT="2380"

# PD client ports for VM2/VM3 (optional management access)
PD2_CLIENT_PORT="2381"
PD3_CLIENT_PORT="2382"

# QEMU settings
QEMU_MEM="2048"
QEMU_SMP="2"
QEMU_VNC_BASE=1

# ============================================================
# Pre-flight checks
# ============================================================

if ! command -v qemu-system-x86_64 &>/dev/null; then
    echo "ERROR: qemu-system-x86_64 not found. Run: sudo bash install.sh"
    exit 1
fi

if ! ip link show "${BRIDGE}" &>/dev/null; then
    echo "ERROR: Bridge ${BRIDGE} not found. Run: sudo bash setup-network.sh"
    exit 1
fi

for id in 1 2 3; do
    VM_IMG="${VM_DIR}/vm${id}.qcow2"
    VM_DATA="${VM_DIR}/vm${id}-data.qcow2"
    VM_SEED="${VM_DIR}/vm${id}-seed.img"
    if [ ! -f "${VM_IMG}" ]; then
        echo "ERROR: VM${id} image not found: ${VM_IMG}"
        echo "       Run: bash create-vms.sh"
        exit 1
    fi
    if [ ! -f "${VM_DATA}" ]; then
        echo "ERROR: VM${id} data disk not found: ${VM_DATA}"
        echo "       Run: bash create-vms.sh"
        exit 1
    fi
    if [ ! -f "${VM_SEED}" ]; then
        echo "ERROR: VM${id} seed image not found: ${VM_SEED}"
        echo "       Run: bash create-vms.sh"
        exit 1
    fi
done

# ============================================================
# Restart bridge to ensure it's up
# ============================================================
sudo ip link set "${BRIDGE}" up 2>/dev/null || true
for id in 1 2 3; do
    sudo ip link set "tap$((id - 1))" up 2>/dev/null || true
done

# ============================================================
# Build QEMU hostfwd string for VM port forwarding.
#
# Format: hostfwd=tcp::{host_port}-:{vm_port}
#   host_port = 宿主机 localhost 上监听的端口
#   vm_port   = QEMU 转发到 VM 内部的端口
#
# 最终拼接成 QEMU -netdev user 的 hostfwd 参数，例如 VM1：
#   hostfwd=tcp::2201-:22,hostfwd=tcp::20160-:20160,...
#
# 这样宿主机只需连 localhost:xxxx 就能访问 VM 内部的服务，
# 无需直接与 VM 的 172.16.0.x 内网 IP 通信。
# ============================================================

build_hostfwd() {
    local id=$1
    local fwds="hostfwd=tcp::${VM_SSH_PORT[$id]}-:22"
    fwds="${fwds},hostfwd=tcp::${VM_TIKV_PORT[$id]}-:20160"
    fwds="${fwds},hostfwd=tcp::${VM_TIKV_STATUS_PORT[$id]}-:20180"

    # VM1 gets primary PD client/peer ports
    if [ "$id" -eq 1 ]; then
        fwds="${fwds},hostfwd=tcp::${PD_CLIENT_PORT}-:2379"
        fwds="${fwds},hostfwd=tcp::${PD_PEER_PORT}-:2380"
    fi
    # VM2/3 PD client ports for optional direct management access
    if [ "$id" -eq 2 ]; then
        fwds="${fwds},hostfwd=tcp::${PD2_CLIENT_PORT}-:2379"
    fi
    if [ "$id" -eq 3 ]; then
        fwds="${fwds},hostfwd=tcp::${PD3_CLIENT_PORT}-:2379"
    fi
    echo "${fwds}"
}

start_vm() {
    local id=$1
    local vm_img="${VM_DIR}/vm${id}.qcow2"
    local vm_seed="${VM_DIR}/vm${id}-seed.img"
    local tap="tap$((id - 1))"
    local vnc=$((QEMU_VNC_BASE + id - 1))
    local pidfile="${VM_DIR}/vm${id}.pid"
    local hostfwd
    hostfwd=$(build_hostfwd "$id")

    if [ -f "${pidfile}" ]; then
        local oldpid
        oldpid=$(sudo cat "${pidfile}" 2>/dev/null) || true
        if [ -n "${oldpid}" ] && kill -0 "${oldpid}" 2>/dev/null; then
            echo "[warn] VM${id} is already running (pid ${oldpid})"
            return
        fi
        sudo rm -f "${pidfile}"
    fi

    echo ">>> Starting VM${id} (IP: ${VM_IP[$id]}, SSH: localhost:${VM_SSH_PORT[$id]} | PD+TiKV)..."

    sudo qemu-system-x86_64 \
        -name "tikv-vm${id}" \
        -machine type=q35,accel=kvm \
        -cpu host \
        -smp "${QEMU_SMP}" \
        -m "${QEMU_MEM}" \
        -drive file="${vm_img}",if=virtio,format=qcow2,discard=unmap \
        -drive file="${VM_DIR}/vm${id}-data.qcow2",if=virtio,format=qcow2 \
        -drive file="${vm_seed}",if=virtio,format=raw,readonly=on \
        -netdev tap,id=net0,ifname="${tap}",script=no,downscript=no \
        -device virtio-net-pci,netdev=net0,mac="${VM_MAC[$id]}" \
        -netdev "user,id=net1,${hostfwd}" \
        -device virtio-net-pci,netdev=net1 \
        -audiodev none,id=audio0 \
        -display none \
        -vnc "127.0.0.1:${vnc}" \
        -pidfile "${pidfile}" \
        -daemonize \
        -monitor "unix:/tmp/qemu-vm${id}-monitor.sock,server,nowait" \
        -serial "file:/tmp/qemu-vm${id}-serial.log" 2>/dev/null

    sudo chown "${SUDO_USER:-$USER}:${SUDO_USER:-$USER}" "${pidfile}" 2>/dev/null || true

    echo "VM${id} started (pid $(sudo cat "${pidfile}" 2>/dev/null))"
}

# ============================================================
# Countdown helper
# ============================================================
wait_with_progress() {
    local seconds=$1
    local msg=$2
    for ((i = seconds; i > 0; i--)); do
        printf "\r%s... %2ds remaining" "$msg" "$i"
        sleep 1
    done
    printf "\r%s... done!           \n" "$msg"
}

# ============================================================
# Main
# ============================================================

echo "========================================"
echo "Starting TiKV 3+3 QEMU Cluster"
echo "========================================"
echo ""
echo "VM1: ${VM_IP[1]} (PD1 + TiKV1) | SSH: localhost:${VM_SSH_PORT[1]}"
echo "VM2: ${VM_IP[2]} (PD2 + TiKV2) | SSH: localhost:${VM_SSH_PORT[2]}"
echo "VM3: ${VM_IP[3]} (PD3 + TiKV3) | SSH: localhost:${VM_SSH_PORT[3]}"
echo ""
echo "PD API (host):  localhost:${PD_CLIENT_PORT}"
echo "========================================"
echo ""

start_vm 1
start_vm 2
start_vm 3

echo ""
echo "=== All VMs launched ==="
echo ""
echo "Waiting 30s for VMs to boot..."

wait_with_progress 30 "VMs booting"

echo ""
echo "=== VMs Status ==="
for id in 1 2 3; do
    if pgrep -f "qemu-system.*tikv-vm${id}" > /dev/null 2>&1; then
        echo "VM${id}: RUNNING"
    else
        echo "VM${id}: FAILED"
    fi
done

echo ""
echo "=== SSH Access (via bridge network) ==="
echo "  ssh ubuntu@172.16.0.101  # VM1 (PD1 + TiKV1)"
echo "  ssh ubuntu@172.16.0.102  # VM2 (PD2 + TiKV2)"
echo "  ssh ubuntu@172.16.0.103  # VM3 (PD3 + TiKV3)"
echo ""
echo "Default SSH password: ubuntu (will prompt to change on first login)"
echo ""
echo "=== Next Steps ==="
echo "  bash deploy-tikv.sh   # Deploy and start TiKV + PD cluster"
