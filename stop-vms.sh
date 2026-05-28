#!/bin/bash
set -euo pipefail

# ============================================================
# Gracefully stop all 3 QEMU VMs
# ============================================================

echo ">>> Stopping all VMs..."

for id in 1 2 3; do
    vm_pid=$(pgrep -f "qemu-system.*tikv-vm${id}" | head -1) || true

    if [ -n "${vm_pid}" ]; then
        echo ">>> Stopping VM${id} (pid ${vm_pid})..."
        sudo kill "${vm_pid}" 2>/dev/null || true
        echo "Waiting for VM${id} to shut down..."
        for i in $(seq 1 30); do
            if ! kill -0 "${vm_pid}" 2>/dev/null; then
                echo "VM${id} shut down gracefully."
                break
            fi
            sleep 1
        done

        if kill -0 "${vm_pid}" 2>/dev/null; then
            echo "Force killing VM${id}..."
            sudo kill -9 "${vm_pid}" 2>/dev/null || true
        fi
    else
        echo "[skip] VM${id} is not running."
    fi
done

# Clean up temp files (needs sudo for root-owned files)
sudo rm -f /tmp/qemu-vm{1,2,3}-{monitor.sock,serial.log} 2>/dev/null || true
sudo rm -f /home/lilingfeng/demo/tikv-qemu/images/vm{1,2,3}.pid 2>/dev/null || true

echo ">>> All VMs stopped."
