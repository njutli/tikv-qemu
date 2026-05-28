#!/bin/bash
set -euo pipefail

# ============================================================
# Deploy TiKV 3-Replica + 3-Node PD across all 3 VMs
# Prerequisites: VMs must be running (start-vms.sh)
#
# Flow chart (what the host does):
#
#   ┌─────────────────────────────────────────────────────────────────────┐
#   │                        宿主机 (WSL2)                                │
#   │                                                                     │
#   │  1. check_prereqs:                                                  │
#   │     ├─ sshpass 已安装? ──→ 没有则 apt-get install                   │
#   │     └─ 3台 VM 都在运行? ──→ 否则 exit                                │
#   │                                                                     │
#   │  2. wait_vm_ready:                                                  │
#   │     └─ 轮询 SSH 172.16.0.{101,102,103}:22 ──→ 等待全部可达          │
#   │                                                                     │
#   │  3. download_binaries (wget 到宿主机本地):                           │
#   │     ├─ wget tikv-v7.1.5-linux-amd64.tar.gz  ──→ downloads/          │
#   │     └─ wget pd-v7.1.5-linux-amd64.tar.gz    ──→ downloads/          │
#   │                                                                     │
#   │  4. deploy_pd ×3 (scp + 远程执行):                                  │
#   │     ┌─── scp pd.tar.gz ──→ VM1:22 ──→ tar xzf ──→ /opt/pd/bin/     │
#   │     │   scp pd1.toml  ──→ VM1:22 ──→ /opt/pd/conf/pd.toml          │
#   │     │   ssh VM1 "tee /etc/systemd/system/pd.service"                │
#   │     │   ssh VM1 "systemctl enable pd"                               │
#   │     ├─── (同上) ──→ VM2:22 ──→ pd2.toml                             │
#   │     └─── (同上) ──→ VM3:22 ──→ pd3.toml                             │
#   │                                                                     │
#   │  5. start_all_pd (同时启动，形成 Raft 集群):                         │
#   │     ├─ ssh VM1 "systemctl restart pd"                               │
#   │     ├─ ssh VM2 "systemctl restart pd"                               │
#   │     └─ ssh VM3 "systemctl restart pd"                               │
#   │                                                                     │
#   │  6. deploy_tikv ×3:                                                 │
#   │     ┌─── scp tikv.tar.gz ──→ VM1:22 ──→ tar xzf ──→ /opt/tikv/bin/ │
#   │     │   scp tikv1.toml   ──→ VM1:22 ──→ /opt/tikv/conf/tikv.toml   │
#   │     │   ssh VM1 "tee /etc/systemd/system/tikv.service"              │
#   │     │   ssh VM1 "systemctl enable tikv && systemctl restart tikv"   │
#   │     ├─── (同上) ──→ VM2:22 ──→ tikv2.toml                           │
#   │     └─── (同上) ──→ VM3:22 ──→ tikv3.toml                           │
#   │                                                                     │
#   │  7. verify_cluster:                                                 │
#   │     ├─ ssh VM1 "pd-ctl member"          ──→ 确认 3 个 PD 成员       │
#   │     ├─ ssh VM1 "pd-ctl store"           ──→ 确认 3 个 TiKV Store    │
#   │     └─ curl localhost:2379/pd/api/v1/health ──→ PD API 可访问       │
#   │                                                                     │
#   └─────────────────────────────────────────────────────────────────────┘
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="${SCRIPT_DIR}/config"

declare -A VM_SSH_PORT
VM_SSH_PORT[1]="2201"
VM_SSH_PORT[2]="2202"
VM_SSH_PORT[3]="2203"

declare -A VM_IP
VM_IP[1]="172.16.0.101"
VM_IP[2]="172.16.0.102"
VM_IP[3]="172.16.0.103"

SSH_OPTS="-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10"
SSH_USER="ubuntu"
SSH_PASS="ubuntu"

TIKV_VERSION="${TIKV_VERSION:-v7.1.5}"
PD_VERSION="${PD_VERSION:-v7.1.5}"

TIKV_TAR="tikv-${TIKV_VERSION}-linux-amd64.tar.gz"
PD_TAR="pd-${PD_VERSION}-linux-amd64.tar.gz"

DOWNLOAD_BASE="https://tiup-mirrors.pingcap.com"

# ============================================================
# Helper functions
# ============================================================

ssh_vm() {
    local vm_id=$1
    shift
    sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${VM_IP[$vm_id]}" "$@"
}

scp_to_vm() {
    local vm_id=$1
    local local_file=$2
    local remote_path=$3
    sshpass -p "${SSH_PASS}" scp ${SSH_OPTS} "${local_file}" "${SSH_USER}@${VM_IP[$vm_id]}:${remote_path}"
}

check_prereqs() {
    if ! command -v sshpass &>/dev/null; then
        echo ">>> Installing sshpass..."
        sudo apt-get install -y sshpass >/dev/null 2>&1
    fi

    for id in 1 2 3; do
        if ! pgrep -f "qemu-system.*tikv-vm${id}" > /dev/null 2>&1; then
            echo "ERROR: VM${id} is not running. Run: sudo bash start-vms.sh"
            exit 1
        fi
    done

    echo "All VMs are running."
}

wait_vm_ready() {
    local vm_id=$1
    local max_retries=60
    echo -n ">>> Waiting for VM${vm_id} SSH..."
    for i in $(seq 1 ${max_retries}); do
        if sshpass -p "${SSH_PASS}" ssh ${SSH_OPTS} "${SSH_USER}@${VM_IP[$vm_id]}" "echo ok" 2>/dev/null; then
            echo " ready!"
            return 0
        fi
        sleep 2
        echo -n "."
    done
    echo " timeout!"
    return 1
}

# ============================================================
# Download TiKV/PD binaries on host (cached for reuse)
# ============================================================

download_binaries() {
    local cache_dir="${SCRIPT_DIR}/downloads"
    mkdir -p "${cache_dir}"

    for tar in "${TIKV_TAR}" "${PD_TAR}"; do
        local url="${DOWNLOAD_BASE}/${tar}"
        local dest="${cache_dir}/${tar}"
        if [ ! -f "${dest}" ]; then
            echo ">>> Downloading ${tar}..."
            wget -q --show-progress -O "${dest}" "${url}" || {
                echo "ERROR: Failed to download ${tar} from ${url}"
                exit 1
            }
        else
            echo "[skip] ${tar} already downloaded."
        fi
    done
}

# ============================================================
# Deploy PD to a VM
# ============================================================

deploy_pd() {
    local vm_id=$1
    echo ""
    echo "========================================"
    echo "Deploying PD to VM${vm_id} (${VM_IP[$vm_id]})"
    echo "========================================"

    local cache_dir="${SCRIPT_DIR}/downloads"

    # Create directories
    ssh_vm ${vm_id} "sudo mkdir -p /opt/pd/bin /opt/pd/conf /data/pd /var/log/pd"

    # Copy PD binary
    ssh_vm ${vm_id} "sudo mkdir -p /opt/pd/bin /opt/pd/conf /data/pd /var/log/pd"
    scp_to_vm ${vm_id} "${cache_dir}/${PD_TAR}" "/tmp/${PD_TAR}"
    ssh_vm ${vm_id} "cd /tmp && tar xzf ${PD_TAR} && sudo mv -f pd-server /opt/pd/bin/ && rm -f ${PD_TAR}"

    # Copy PD config
    scp_to_vm ${vm_id} "${CONFIG_DIR}/pd${vm_id}.toml" "/tmp/pd.toml"
    ssh_vm ${vm_id} "sudo mv /tmp/pd.toml /opt/pd/conf/pd.toml && sudo chown -R root:root /opt/pd /data/pd /var/log/pd"

    # Create systemd service — 让 PD 作为系统服务运行，实现：
    #   1. 开机自启（enable）
    #   2. 崩溃自动重启（Restart=on-failure）
    #   3. 统一用 systemctl 管理启停
    #
    # 各字段含义：
    #   [Unit]
    #     Description        服务的描述文本
    #     After=network.target  在网络就绪后才启动（PD 需要网络通信）
    #
    #   [Service]
    #     Type=simple         最简单的类型，systemd 认为 ExecStart 启动后服务即就绪
    #     User=root           以 root 身份运行（需要写 /data/pd 和 /var/log）
    #     ExecStart           启动命令：pd-server 读配置文件，日志写到 /var/log/pd/
    #     Restart=on-failure  进程异常退出时自动重启（exit code != 0）
    #     RestartSec=5        重启前等待 5 秒（避免频繁重启）
    #     LimitNOFILE=1000000 最大打开文件数（TiKV/PD 需要大量文件描述符）
    #
    #   [Install]
    #     WantedBy=multi-user.target  系统进入多用户模式时自动启动本服务
    ssh_vm ${vm_id} "sudo tee /etc/systemd/system/pd.service" > /dev/null <<'SYSDSRV'
[Unit]
Description=PD (Placement Driver)
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/pd/bin/pd-server --config=/opt/pd/conf/pd.toml --log-file=/var/log/pd/pd.log
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000

[Install]
WantedBy=multi-user.target
SYSDSRV

    ssh_vm ${vm_id} "sudo systemctl daemon-reload && sudo systemctl enable pd"
    # enable 工作原理：
    #   systemctl enable pd 在 multi-user.target.wants/ 下创建软链接
    #   → /etc/systemd/system/multi-user.target.wants/pd.service → ../pd.service
    #   系统启动到 multi-user.target 时会自动启动该目录下所有服务
}

# ============================================================
# Start PD on all VMs (must start together for initial cluster)
# ============================================================

start_all_pd() {
    echo ""
    echo "========================================"
    echo "Starting PD cluster on all 3 nodes"
    echo "========================================"

    for id in 1 2 3; do
        echo ">>> Starting PD on VM${id}..."
        ssh_vm ${id} "sudo systemctl restart pd"
    done

    echo ">>> Waiting for PD cluster to form (15s)..."
    sleep 15

    echo ">>> PD health check:"
    for id in 1 2 3; do
        echo -n "  VM${id} PD member: "
        ssh_vm ${id} "curl -s --noproxy '*' http://127.0.0.1:2379/pd/api/v1/health" 2>/dev/null | grep -q '"health"' && echo "ok" || echo "pending..."
    done

    echo ">>> PD members:"
    curl -s --noproxy '*' "http://172.16.0.101:2379/pd/api/v1/members" 2>/dev/null || echo "  (may take a moment to sync)"
}

# ============================================================
# Deploy TiKV to a VM
# ============================================================

deploy_tikv() {
    local vm_id=$1
    echo ""
    echo "========================================"
    echo "Deploying TiKV to VM${vm_id} (${VM_IP[$vm_id]})"
    echo "========================================"

    local cache_dir="${SCRIPT_DIR}/downloads"

    # Create directories
    ssh_vm ${vm_id} "sudo mkdir -p /opt/tikv/bin /opt/tikv/conf /data/tikv /var/log/tikv"

    # Copy TiKV binary
    scp_to_vm ${vm_id} "${cache_dir}/${TIKV_TAR}" "/tmp/${TIKV_TAR}"
    ssh_vm ${vm_id} "cd /tmp && tar xzf ${TIKV_TAR} && sudo mv -f tikv-server /opt/tikv/bin/ && rm -f ${TIKV_TAR}"

    # Copy TiKV config
    scp_to_vm ${vm_id} "${CONFIG_DIR}/tikv${vm_id}.toml" "/tmp/tikv.toml"
    ssh_vm ${vm_id} "sudo mv /tmp/tikv.toml /opt/tikv/conf/tikv.toml && sudo chown -R root:root /opt/tikv /data/tikv /var/log/tikv"

    # Create systemd service — 与 PD 服务类似，额外加了内存限制
    #   MemoryLimit=1500M  TiKV 最多使用 1.5GB 内存，超出会被 OOM kill
    #                      （VM 总共 2GB，留 500MB 给系统和 PD）
    ssh_vm ${vm_id} "sudo tee /etc/systemd/system/tikv.service" > /dev/null <<'SYSDSRV'
[Unit]
Description=TiKV Server
After=network.target

[Service]
Type=simple
User=root
ExecStart=/opt/tikv/bin/tikv-server --config=/opt/tikv/conf/tikv.toml
Restart=on-failure
RestartSec=5
LimitNOFILE=1000000
MemoryLimit=1500M

[Install]
WantedBy=multi-user.target
SYSDSRV

    ssh_vm ${vm_id} "sudo systemctl daemon-reload && sudo systemctl enable tikv"
    echo ">>> Starting TiKV on VM${vm_id}..."
    ssh_vm ${vm_id} "sudo systemctl restart tikv"
    sleep 3

    ssh_vm ${vm_id} "sudo systemctl status tikv --no-pager -l" || true
}

# ============================================================
# Verify cluster
# ============================================================

verify_cluster() {
    echo ""
    echo "========================================"
    echo "Verifying Cluster"
    echo "========================================"
    sleep 10

    echo ""
    echo ">>> PD Members:"
    curl -s --noproxy '*' "http://172.16.0.101:2379/pd/api/v1/members" 2>/dev/null || echo "  (PD may still be syncing...)"

    echo ""
    echo ">>> TiKV Stores:"
    curl -s --noproxy '*' "http://172.16.0.101:2379/pd/api/v1/stores" 2>/dev/null || echo "  (TiKV nodes may still be registering...)"

    echo ""
    echo ">>> PD Health (via bridge):"
    curl -s --noproxy '*' "http://172.16.0.101:2379/pd/api/v1/health" 2>/dev/null || echo "  unreachable"

    echo ""
    echo ">>> PD API entry point:"
    echo "  curl http://172.16.0.101:2379/pd/api/v1/health"
    echo "  curl http://172.16.0.101:2379/pd/api/v1/stores"
}

# ============================================================
# Main
# ============================================================

echo "========================================"
echo "TiKV 3+3 Cluster Deployment"
echo "=============================="
echo " PD:   3 nodes (VM1, VM2, VM3)"
echo " TiKV: 3 nodes (VM1, VM2, VM3)"
echo " TiKV: ${TIKV_VERSION}"
echo " PD:   ${PD_VERSION}"
echo "========================================"

check_prereqs

# Wait for VMs to be fully booted
for id in 1 2 3; do
    wait_vm_ready ${id} || {
        echo "ERROR: VM${id} SSH not available. Check VM status."
        exit 1
    }
done

echo ""
echo ">>> All VMs are reachable via SSH."

# Download binaries once on host
download_binaries

# Deploy PD to all 3 VMs
for id in 1 2 3; do
    deploy_pd ${id}
done

# Start all PDs together (Raft initial cluster formation)
start_all_pd

# Deploy TiKV to all 3 VMs
for id in 1 2 3; do
    deploy_tikv ${id}
done

# Verify
verify_cluster

echo ""
echo "========================================"
echo "Deployment Complete!"
echo "========================================"
echo ""
echo "PD API:  curl http://172.16.0.101:2379/pd/api/v1/health"
echo ""
echo "SSH Access (via bridge network):"
echo "  ssh ubuntu@172.16.0.101   # VM1 (PD1 + TiKV1)"
echo "  ssh ubuntu@172.16.0.102   # VM2 (PD2 + TiKV2)"
echo "  ssh ubuntu@172.16.0.103   # VM3 (PD3 + TiKV3)"
echo ""
echo "Cluster Management (with TiUP):"
echo "  export PATH=\$HOME/.tiup/bin:\$PATH"
echo "  tiup cluster display tikv-cluster"
echo ""
