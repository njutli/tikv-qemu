#!/bin/bash
set -euo pipefail

# ============================================================
# Install QEMU, cloud-utils, and required dependencies
# Run: sudo bash install.sh
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use: sudo bash install.sh"
    exit 1
fi

# sudo strips proxy env vars by default, but WSL2 often requires a local proxy
# (e.g. Clash/V2Ray on Windows) to reach external sites.
# Attempt to detect and restore the proxy from the invoking user's running shell,
# and also check common files that WSL proxy helpers write to.
if [ -z "${https_proxy:-}" ] && [ -n "${SUDO_USER:-}" ]; then
    # Method 1: read proxy from user's running shell via /proc
    user_home="/home/${SUDO_USER}"
    user_proxy=""
    user_noproxy=""
    for pid in $(pgrep -u "${SUDO_USER}" bash 2>/dev/null || true); do
        if [ -z "${user_proxy}" ]; then
            user_proxy=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep '^https_proxy=' | cut -d= -f2- | head -1) || true
        fi
        if [ -z "${user_noproxy}" ]; then
            user_noproxy=$(tr '\0' '\n' < "/proc/${pid}/environ" 2>/dev/null | grep '^no_proxy=' | cut -d= -f2- | head -1) || true
        fi
        [ -n "${user_proxy}" ] && [ -n "${user_noproxy}" ] && break
    done

    # Method 2: check common wsl proxy config files
    for f in "${user_home}/.wslproxy" "${user_home}/.config/wsl/proxy.conf" /etc/profile.d/proxy.sh; do
        if [ -f "$f" ] && [ -z "${user_proxy}" ]; then
            user_proxy=$(grep -oP 'https?://[^"'\'']+' "$f" | head -1) || true
        fi
    done

    if [ -n "${user_proxy}" ]; then
        export https_proxy="${user_proxy}"
        export HTTPS_PROXY="${user_proxy}"
        export http_proxy="${user_proxy/#https/http}"
        export HTTP_PROXY="${user_proxy/#https/http}"

        # Propagate no_proxy from user env, and append common apt repos
        # that should bypass the proxy (they are direct connections).
        if [ -n "${user_noproxy}" ]; then
            user_noproxy="${user_noproxy},archive.ubuntu.com,security.ubuntu.com,*.ubuntu.com,*.launchpad.net,*.docker.com"
        else
            user_noproxy="localhost,127.0.0.1,archive.ubuntu.com,security.ubuntu.com,*.ubuntu.com,*.launchpad.net,*.docker.com"
        fi
        export no_proxy="${user_noproxy}"
        export NO_PROXY="${user_noproxy}"
        echo ">>> Proxy detected: ${https_proxy}"
    fi
fi

# Final check: can we actually reach the internet?
# If both DNS and direct connectivity fail, warn the user early.
if ! curl -s --connect-timeout 3 https://tiup-mirrors.pingcap.com > /dev/null 2>&1; then
    echo "=============================================="
    echo " WARNING: Cannot reach tiup-mirrors.pingcap.com"
    echo ""
    echo " Your system likely uses a proxy (e.g. 127.0.0.1:7897)"
    echo " but sudo stripped the proxy environment variables."
    echo ""
    echo " Retry with:"
    echo "   sudo -E bash install.sh"
    echo ""
    echo " Or set proxy explicitly:"
    echo "   export https_proxy=http://127.0.0.1:7897"
    echo "   sudo -E bash install.sh"
    echo "=============================================="
    exit 1
fi

echo ">>> Updating package index..."
apt-get update -y

echo ">>> Installing QEMU, virt tools, and system dependencies..."
# ------------------------------------------------------------------
# Package                         | Purpose
# ------------------------------------------------------------------
# qemu-system-x86                 | x86_64 QEMU 虚拟机主程序，启动 3 台 VM
# qemu-utils                      | qemu-img 磁盘工具，创建/调整 qcow2 镜像
# cloud-image-utils               | cloud-localds，将 cloud-init 配置打包为 ISO 注入 VM
# cloud-init                      | VM 首次启动时自动配置网络、用户、安装软件包
# bridge-utils                    | brctl，管理 br0 网桥，连接 tap0-2 实现 VM 间二层互通
# iproute2                        | ip 命令，创建 tap 设备、配置 IP/路由/网桥
# openssh-client                  | SSH 客户端，从宿主机远程连接 VM 执行部署
# sshpass (TiKV 要求 >= 1.06)     | 非交互式 SSH 密码认证，deploy-tikv.sh 自动部署依赖
# socat                           | 通过 QEMU monitor socket 发送关机指令，实现优雅停机
# numactl (TiKV 要求 >= 2.0.12)   | NUMA 拓扑感知，优化多 NUMA 节点内存访问性能
# wget                            | 下载 Ubuntu cloud image、TiKV/PD 二进制包
# curl                            | 安装 TiUP、查询 PD API 健康状态
# jq                              | 解析 PD API 返回的 JSON 集群状态
# net-tools                       | ifconfig/netstat 等传统网络诊断工具，辅助调试
# ------------------------------------------------------------------
apt-get install -y \
    qemu-system-x86 \
    qemu-utils \
    cloud-image-utils \
    cloud-init \
    bridge-utils \
    iproute2 \
    openssh-client \
    sshpass \
    socat \
    numactl \
    wget \
    curl \
    jq \
    net-tools

# KVM (Kernel-based Virtual Machine) 是 Linux 内核虚拟化模块，
# QEMU 通过 /dev/kvm 使用 CPU 硬件加速 (VT-x/AMD-V)，避免纯软件模拟性能瓶颈。
# 将当前用户加入 kvm 组后，无需 root 也可启动 KVM 加速的 VM。
echo ">>> Adding user to kvm group..."
if [ -n "${SUDO_USER:-}" ]; then
    usermod -a -G kvm "${SUDO_USER}" 2>/dev/null || true
fi

# ============================================================
# TiUP is PingCAP's official cluster management tool for TiKV/PD.
# Official docs: https://tikv.org/docs/7.1/deploy/install/production/
# Step 1 of the official guide has 5 sub-steps, executed below.
# IMPORTANT: TiUP installs to ~/.tiup/. All commands run as the real
# user (SUDO_USER). Proxy env vars (detected earlier) must reach tiup
# so it can download components from tiup-mirrors.pingcap.com.
# ============================================================

# Helper: run a command as the real user, inheriting root's proxy env
run_as_user() {
    if [ -n "${SUDO_USER:-}" ]; then
        sudo --preserve-env=all -u "${SUDO_USER}" bash -c "export PATH=\$HOME/.tiup/bin:\$PATH && $*"
    else
        echo "ERROR: SUDO_USER not set" >&2
        return 1
    fi
}

echo ">>> Step 1.1: Installing TiUP binary..."
if [ -n "${SUDO_USER:-}" ] && [ -f "/home/${SUDO_USER}/.tiup/bin/tiup" ]; then
    echo "[skip] TiUP binary already installed: $(/home/${SUDO_USER}/.tiup/bin/tiup --version 2>&1 | head -1)"
else
    run_as_user "curl --proto '=https' --tlsv1.2 -sSf https://tiup-mirrors.pingcap.com/install.sh | sh" || {
        echo ""
        echo "ERROR: Failed to download TiUP installer."
        echo "       Check your proxy or network: curl https://tiup-mirrors.pingcap.com"
        exit 1
    }
    echo "TiUP binary installed."
fi

echo ">>> Step 1.2: Setting TiUP PATH..."
if [ -n "${SUDO_USER:-}" ]; then
    export PATH="/home/${SUDO_USER}/.tiup/bin:${PATH}"
fi
echo "OK"

echo ">>> Step 1.3: Installing TiUP cluster component..."
# `tiup cluster` auto-downloads the cluster management plugin (~10MB).
# This is the most network-intensive sub-step and the most likely to fail.
# Check if component is already installed by looking at its data directory.
cluster_installed=""
if [ -n "${SUDO_USER:-}" ] && [ -d "/home/${SUDO_USER}/.tiup/components/cluster" ]; then
    cluster_installed=1
fi
if [ -n "${cluster_installed}" ]; then
    echo "[skip] TiUP cluster already installed ($(run_as_user 'tiup --binary cluster' 2>/dev/null || echo 'unknown'))"
else
    echo "Downloading tiup cluster component..."
    if run_as_user "tiup install cluster"; then
        echo "TiUP cluster component installed ($(run_as_user 'tiup --binary cluster' 2>/dev/null))"
    else
        echo ""
        echo "ERROR: Failed to install tiup cluster component."
        echo "       This usually means tiup can't reach tiup-mirrors.pingcap.com."
        echo "       After fixing network, run:  tiup cluster"
        exit 1
    fi
fi

echo ">>> Step 1.4: Updating TiUP and cluster to latest..."
run_as_user "tiup update --self && tiup update cluster" 2>&1 | tail -3 || {
    echo "WARNING: tiup update failed (non-fatal, using current version)"
}
echo "Done."

echo ">>> Step 1.5: Verify TiUP cluster version..."
cluster_ver=$(run_as_user "tiup --binary cluster" 2>&1) || {
    echo ""
    echo "ERROR: tiup cluster component is not installed."
    echo "       Run manually:  tiup cluster"
    exit 1
}
echo "${cluster_ver}"

# tun: 虚拟点对点网络设备 (L3)，QEMU user-mode 网络栈依赖此模块
# tap: 虚拟以太网设备 (L2)，QEMU 通过 tap 将 VM 网卡桥接到宿主机 br0，
#      实现 VM 之间以及 VM 与宿主机之间的二层网络互通
echo ">>> Loading required kernel modules..."
modprobe tun 2>/dev/null || echo "(tun module already loaded or built-in)"
modprobe tap 2>/dev/null || echo "(tap module already loaded or built-in)"

echo ">>> Verifying installation..."
qemu-system-x86_64 --version
echo ""
echo "=== Installation complete ==="
echo "Next steps:"
echo "  1. Run: bash download-image.sh"
echo "  2. Run: sudo bash setup-network.sh"
echo "  3. Run: bash create-vms.sh"
echo "  4. Run: bash start-vms.sh"
