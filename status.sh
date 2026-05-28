#!/bin/bash
set -euo pipefail

# ============================================================
# Quick status check for the TiKV 3-PD + 3-TiKV cluster
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
declare -A VM_SSH_PORT
VM_SSH_PORT[1]="2201"
VM_SSH_PORT[2]="2202"
VM_SSH_PORT[3]="2203"

declare -A VM_IP
VM_IP[1]="172.16.0.101"
VM_IP[2]="172.16.0.102"
VM_IP[3]="172.16.0.103"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=5"
SSH_PASS="ubuntu"

echo "========================================"
echo "TiKV + PD Cluster Status"
echo "========================================"

echo ""
echo "--- QEMU Processes ---"
for id in 1 2 3; do
    pidfile="${SCRIPT_DIR}/images/vm${id}.pid"
    if [ -f "${pidfile}" ] && kill -0 "$(cat "${pidfile}")" 2>/dev/null; then
        echo "VM${id}: RUNNING (pid $(cat "${pidfile}"))"
    else
        echo "VM${id}: STOPPED"
    fi
done

echo ""
echo "--- VM Services (PD + TiKV) ---"
for id in 1 2 3; do
    echo -n "VM${id} (${VM_IP[$id]}): "
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} ubuntu@"${VM_IP[$id]}" \
        "echo -n 'PD='; systemctl is-active pd 2>/dev/null || echo 'inactive'; echo -n ' TiKV='; systemctl is-active tikv 2>/dev/null || echo 'inactive'" 2>/dev/null || echo "  SSH unreachable"
done

echo ""
echo "--- PD Health (per node via bridge) ---"
for id in 1 2 3; do
    echo -n "  PD${id} (${VM_IP[$id]}): "
    curl -s --noproxy '*' "http://${VM_IP[$id]}:2379/pd/api/v1/health" 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print([m['health'] for m in d])" 2>/dev/null || echo "unreachable"
done

echo ""
echo "--- PD Members ---"
curl -s --noproxy '*' "http://172.16.0.101:2379/pd/api/v1/members" 2>/dev/null || echo "  Could not query PD members"

echo ""
echo "--- TiKV Stores ---"
curl -s --noproxy '*' "http://172.16.0.101:2379/pd/api/v1/stores" 2>/dev/null || echo "  Could not query TiKV stores"

echo ""
echo "--- Replication Config ---"
curl -s --noproxy '*' "http://172.16.0.101:2379/pd/api/v1/config/replicate" 2>/dev/null || echo "  Could not query"

echo ""
echo "========================================"
echo "PD API:  curl http://172.16.0.101:2379/pd/api/v1/health"
echo "SSH:     ssh ubuntu@172.16.0.101"
