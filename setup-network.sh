#!/bin/bash
set -euo pipefail

# ============================================================
# Set up bridge + tap devices for inter-VM networking
# Creates: br0 (172.16.0.1/24) + tap0, tap1, tap2
# Run: sudo bash setup-network.sh
# ============================================================

if [ "$(id -u)" -ne 0 ]; then
    echo "This script must be run as root. Use: sudo bash setup-network.sh"
    exit 1
fi

BRIDGE="br0"
BRIDGE_IP="172.16.0.1"
SUBNET_MASK="24"
TAP_DEVICES=("tap0" "tap1" "tap2")

# --- Load kernel modules ---
modprobe tun 2>/dev/null || true
modprobe tap 2>/dev/null || true
modprobe bridge 2>/dev/null || true

# --- Enable IP forwarding ---
# 把宿主机变成路由器：允许内核在不同网卡之间转发 IP 包。
# 例如 VM 想通过 br0 经宿主机访问外网，或者从 Windows 侧访问 VM 内网时，
# 宿主机需要把包从 br0 转发到 eth0（或反向），这两个开关就是为此准备的。
sysctl -w net.ipv4.ip_forward=1 > /dev/null
sysctl -w net.ipv4.conf.all.forwarding=1 > /dev/null

# Docker sets FORWARD policy to DROP, which blocks bridge traffic between VMs.
# Allow all traffic on the bridge interface (inter-VM PD/TiKV communication).
iptables -C FORWARD -i "${BRIDGE}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -i "${BRIDGE}" -j ACCEPT
iptables -C FORWARD -o "${BRIDGE}" -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD 1 -o "${BRIDGE}" -j ACCEPT

# --- Create bridge ---
if ip link show "${BRIDGE}" &>/dev/null; then
    echo "[skip] Bridge ${BRIDGE} already exists."
else
    echo ">>> Creating bridge ${BRIDGE}..."
    ip link add name "${BRIDGE}" type bridge
    ip addr add "${BRIDGE_IP}/${SUBNET_MASK}" dev "${BRIDGE}"
    ip link set "${BRIDGE}" up
    echo "Bridge ${BRIDGE} created with IP ${BRIDGE_IP}/${SUBNET_MASK}"
fi

# --- Create tap devices ---
if [ -z "${SUDO_USER:-}" ]; then
    echo "ERROR: SUDO_USER not set. Run with: sudo bash setup-network.sh"
    exit 1
fi

for tap in "${TAP_DEVICES[@]}"; do
    if ip link show "${tap}" &>/dev/null; then
        echo "[skip] Tap device ${tap} already exists."
    else
        echo ">>> Creating tap device ${tap}..."
        ip tuntap add dev "${tap}" mode tap user "${SUDO_USER}"
        ip link set "${tap}" up
    fi

    # Add tap to bridge if not already a member
    if ! bridge link show "${BRIDGE}" | grep -q "${tap}"; then
        echo ">>> Adding ${tap} to ${BRIDGE}..."
        ip link set "${tap}" master "${BRIDGE}"
    fi
done

echo ""

# ============================================================
# Proxy relay: VMs can't directly reach the Windows-side proxy
# at 127.0.0.1:7897. socat listens on the bridge IP and forwards
# connections to the proxy, giving VMs internet access.
# VM proxy setting: http://172.16.0.1:8889
# ============================================================
PROXY_RELAY_PORT=8889
PROXY_TARGET="127.0.0.1:7897"

# Kill old relay if running
pkill -f "socat.*${BRIDGE_IP}:${PROXY_RELAY_PORT}" 2>/dev/null || true

if curl -s --connect-timeout 2 -x "${PROXY_TARGET}" http://httpbin.org/ip > /dev/null 2>&1; then
    nohup socat "TCP-LISTEN:${PROXY_RELAY_PORT},bind=${BRIDGE_IP},fork,reuseaddr" \
        "TCP:${PROXY_TARGET}" > /dev/null 2>&1 &
    echo "Proxy relay started: ${BRIDGE_IP}:${PROXY_RELAY_PORT} -> ${PROXY_TARGET} (pid $!)"
    echo "VMs can use: export http_proxy=http://${BRIDGE_IP}:${PROXY_RELAY_PORT}"
else
    echo "[warn] Host proxy ${PROXY_TARGET} not reachable, skipping relay"
    echo "       VMs will not have internet access."
fi

echo ""
echo "=== Network setup complete ==="
echo "Bridge: ${BRIDGE} (${BRIDGE_IP}/${SUBNET_MASK})"
bridge link show "${BRIDGE}"
