#!/bin/bash
set -euo pipefail

# ============================================================
# Create 3 VM disk images with cloud-init configuration
# Each VM: 2CPU, 2GB RAM, based on Ubuntu 24.04 cloud image
# ============================================================
#
# 三种镜像的关系：
#
#   noble-server-cloudimg-amd64.img  ← download-image.sh 下载的 Ubuntu 基础镜像
#     │                                 只读，3 台 VM 共享这一份
#     │  backing_file（写时复制）
#     │
#     ├── vm1.qcow2                   ← VM1 的增量层：VM 运行时的所有写操作
#     ├── vm2.qcow2                   ←    都落在这里，读操作穿透到 base
#     └── vm3.qcow2                   ←    初始几乎 0 字节，随使用增长
#
#   vm{1,2,3}-seed.img               ← cloud-init 配置打包成的 ISO
#     ├── vm{1,2,3}-user-data            cloud-localds 把 user-data + meta-data
#     └── vm{1,2,3}-meta-data            打包成 ISO，VM 首次启动时读取
#                                         执行其中的网络/用户/软件包配置
#
#   QEMU 启动时挂载关系（见 start-vms.sh）：
#     -drive file=vm1.qcow2 ...       ← 根文件系统（qcow2 COW → backing → base）
#     -drive file=vm1-data.qcow2 ...  ← 独立数据盘（10G，无 backing，TiKV/PD 数据存此处）
#     -drive file=vm1-seed.img ...    ← cloud-init 配置盘（只读，首次启动后不再需要）
# ============================================================

DATA_DISK_SIZE="10G"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_IMG="${SCRIPT_DIR}/images/noble-server-cloudimg-amd64.img"
CLOUD_INIT_DIR="${SCRIPT_DIR}/cloud-init"
VM_DIR="${SCRIPT_DIR}/images"

if [ ! -f "${BASE_IMG}" ]; then
    echo "ERROR: Base image not found: ${BASE_IMG}"
    echo "       Run download-image.sh first."
    exit 1
fi

echo ">>> Creating VM disk images (copy-on-write backing files)..."

for id in 1 2 3; do
    VM_IMG="${VM_DIR}/vm${id}.qcow2"

    if [ -f "${VM_IMG}" ]; then
        echo "[skip] VM${id} image already exists: ${VM_IMG}"
    else
        echo ">>> Creating VM${id} disk image..."
        # qcow2 写时复制：-b 指定只读基础镜像作为 backing file
        # vm 的所有写入只在 qcow2 层，基础镜像保持不变
        qemu-img create \
            -f qcow2 \
            -b "${BASE_IMG}" \
            -F qcow2 \
            "${VM_IMG}" 15G
    fi

    echo ">>> Creating cloud-init ISO for VM${id}..."
    # 将 user-data（网络/用户/软件包配置）和 meta-data（主机名/实例ID）
    # 打包为 ISO 镜像，VM 首次启动时 cloud-init 自动读取并执行
    cloud-localds \
        "${VM_DIR}/vm${id}-seed.img" \
        "${CLOUD_INIT_DIR}/vm${id}-user-data" \
        "${CLOUD_INIT_DIR}/vm${id}-meta-data"

    # 独立的 TiKV/PD 数据盘（无 backing file，独立增长）
    DATA_IMG="${VM_DIR}/vm${id}-data.qcow2"
    if [ -f "${DATA_IMG}" ]; then
        echo "[skip] VM${id} data disk already exists: ${DATA_IMG}"
    else
        echo ">>> Creating VM${id} data disk (${DATA_DISK_SIZE})..."
        qemu-img create -f qcow2 "${DATA_IMG}" "${DATA_DISK_SIZE}"
    fi
done

echo ""
echo "=== VM images created ==="
ls -lh "${VM_DIR}"/vm[123].qcow2 "${VM_DIR}"/vm[123]-data.qcow2 "${VM_DIR}"/vm[123]-seed.img
