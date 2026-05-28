#!/bin/bash
set -euo pipefail

# ============================================================
# Deploy TiKV 3-PD + 3-TiKV cluster using TiUP (official method)
# Prerequisites:
#   1. VMs running (sudo bash start-vms.sh)
#   2. TiUP installed (sudo bash install.sh)
#   3. VMs have internet access (via proxy relay on 172.16.0.1:8889)
#
# Flow chart (what the host does):
#
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │                        宿主机 (WSL2)                                │
#   │                                                                     │
#   │  1. Pre-flight checks:                                              │
#   │     └─ tiup 命令可用？ ──→ 否则 exit                                 │
#   │     └─ 3台 VM SSH 可达？ ──→ 否则 exit                               │
#   │                                                                     │
#   │  2. Setup passwordless SSH (TiUP 要求免密登录):                      │
#   │     ├─ ssh-keygen -t ed25519    ──→ ~/.ssh/id_ed25519               │
#   │     ├─ sshpass scp pubkey ──→ VM1:22 ──→ ~/.ssh/authorized_keys     │
#   │     ├─ sshpass scp pubkey ──→ VM2:22 ──→ ~/.ssh/authorized_keys     │
#   │     └─ sshpass scp pubkey ──→ VM3:22 ──→ ~/.ssh/authorized_keys     │
#   │                                                                     │
#   │  3. Generate topology.yaml:                                         │
#   │     └─ 写入 config/topology.yaml                                     │
#   │        ├─ global: user=ubuntu, data_dir=/data                       │
#   │        ├─ pd_servers: 172.16.0.{101,102,103}                       │
#   │        └─ tikv_servers: 172.16.0.{101,102,103}                     │
#   │                                                                     │
#   │  4. Check + Deploy (tiup cluster 负责):                              │
#   │     ├─ tiup cluster check topology.yaml -i ~/.ssh/id_ed25519       │
#   │     │   └─ SSH 到各 VM 检查 CPU/mem/disk/OS/端口 等前置条件          │
#   │     │   └─ 不满足则 --apply 自动修复（安装依赖等）                   │
#   │     │                                                               │
#   │     └─ tiup cluster deploy tikv-cluster v7.1.5 topology.yaml       │
#   │         ├─ SSH → VM1 ──→ 下载 pd-server/tikv-server 到 /opt/        │
#   │         ├─ SSH → VM2 ──→ 下发配置、创建 systemd                      │
#   │         └─ SSH → VM3 ──→ 注册到 TiUP cluster 管理                   │
#   │                                                                     │
#   │  5. Start cluster:                                                  │
#   │     └─ tiup cluster start tikv-cluster --init                       │
#   │         ├─ 依次 SSH 到各 VM ──→ systemctl start pd/tikv              │
#   │         └─ --init: 首次启动时初始化 PD Raft 集群                     │
#   │                                                                     │
#   │  6. Display status:                                                 │
#   │     └─ tiup cluster display tikv-cluster                            │
#   │         打印所有节点的角色/IP/端口/状态/目录                           │
#   │                                                                     │
#   └─────────────────────────────────────────────────────────────────────┘
#
# 与手动部署 (deploy-tikv.sh) 的核心区别：
#   - 手动：宿主机 wget → scp 二进制 → 手写 systemd → curl 验证
#   - TiUP：写 topology.yaml → tiup cluster 一条命令搞定全部
#   - TiUP 要求 VM 有外网（下载二进制）和 SSH 免密登录
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPOLOGY_FILE="${SCRIPT_DIR}/config/topology.yaml"
CLUSTER_NAME="tikv-cluster"
TIKV_VERSION="${TIKV_VERSION:-v7.1.5}"

declare -A VM_IP
VM_IP[1]="172.16.0.101"
VM_IP[2]="172.16.0.102"
VM_IP[3]="172.16.0.103"

SSH_USER="ubuntu"
SSH_PASS="ubuntu"
SSH_KEY="${HOME}/.ssh/id_ed25519"

# ============================================================
# Pre-flight checks
# ============================================================

echo "========================================"
echo "TiUP Cluster Deployment"
echo "========================================"

if ! command -v tiup &>/dev/null; then
    echo "ERROR: tiup not found. Run: sudo bash install.sh"
    exit 1
fi

for id in 1 2 3; do
    if ! sshpass -p "${SSH_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        "${SSH_USER}@${VM_IP[$id]}" "echo ok" 2>/dev/null; then
        echo "ERROR: VM${id} (${VM_IP[$id]}) not reachable via SSH."
        echo "       Run: sudo bash start-vms.sh"
        exit 1
    fi
done
echo "All VMs reachable."

# ============================================================
# Step 1: Setup passwordless SSH
# ============================================================

echo ""
echo ">>> Setting up SSH key authentication..."

if [ ! -f "${SSH_KEY}" ]; then
    echo ">>> Generating SSH key..."
    ssh-keygen -t ed25519 -f "${SSH_KEY}" -N "" -C "tikv-deploy"
fi

for id in 1 2 3; do
    ip="${VM_IP[$id]}"
    echo ">>> Copying SSH key to VM${id} (${ip})..."
    sshpass -p "${SSH_PASS}" ssh-copy-id -o StrictHostKeyChecking=no \
        -i "${SSH_KEY}.pub" "${SSH_USER}@${ip}" 2>/dev/null || {
        echo "ERROR: Failed to copy SSH key to ${ip}"
        exit 1
    }
done
echo "SSH key authentication configured."

# ============================================================
# Step 2: Generate topology file if not exists
# ============================================================

if [ ! -f "${TOPOLOGY_FILE}" ]; then
    echo ""
    echo ">>> Creating topology file: ${TOPOLOGY_FILE}"

    cat > "${TOPOLOGY_FILE}" << EOF
global:
  user: "${SSH_USER}"
  ssh_port: 22
  deploy_dir: "/opt/tikv-deploy"
  data_dir: "/data"

pd_servers:
  - host: 172.16.0.101
  - host: 172.16.0.102
  - host: 172.16.0.103

tikv_servers:
  - host: 172.16.0.101
  - host: 172.16.0.102
  - host: 172.16.0.103

monitoring_servers: []

grafana_servers: []

alertmanager_servers: []
EOF
else
    echo "[skip] Topology file already exists: ${TOPOLOGY_FILE}"
fi

# ============================================================
# Step 3: Check and deploy
# ============================================================

echo ""
echo ">>> Checking cluster prerequisites..."
if ! tiup cluster check "${TOPOLOGY_FILE}" -i "${SSH_KEY}" 2>&1 | tail -5; then
    echo ""
    echo "WARNING: Cluster check found issues. Attempting auto-fix..."
    tiup cluster check "${TOPOLOGY_FILE}" --apply -i "${SSH_KEY}" 2>&1 | tail -5 || true
fi

echo ""
echo ">>> Deploying cluster '${CLUSTER_NAME}' (${TIKV_VERSION})..."
tiup cluster deploy "${CLUSTER_NAME}" "${TIKV_VERSION}" "${TOPOLOGY_FILE}" -i "${SSH_KEY}" -y

# ============================================================
# Step 4: Start cluster
# ============================================================

echo ""
echo ">>> Starting cluster..."
tiup cluster start "${CLUSTER_NAME}" -i "${SSH_KEY}" --init

# ============================================================
# Step 5: Display status
# ============================================================

echo ""
echo ">>> Cluster status:"
tiup cluster display "${CLUSTER_NAME}"

echo ""
echo "========================================"
echo "Deployment Complete!"
echo "========================================"
echo ""
echo "Cluster:   ${CLUSTER_NAME}"
echo "Version:   ${TIKV_VERSION}"
echo ""
echo "Management commands:"
echo "  tiup cluster display ${CLUSTER_NAME}"
echo "  tiup cluster start ${CLUSTER_NAME}"
echo "  tiup cluster stop ${CLUSTER_NAME}"
echo ""
echo "PD API:  curl http://localhost:2379/pd/api/v1/health"
echo "SSH:     ssh ubuntu@172.16.0.101"
echo ""
