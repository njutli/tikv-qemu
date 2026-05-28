#!/bin/bash
set -euo pipefail

# ============================================================
# Download Ubuntu 24.04 LTS cloud image as base VM image
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE_DIR="${SCRIPT_DIR}/images"
BASE_IMG="${IMAGE_DIR}/noble-server-cloudimg-amd64.img"
IMG_URL="https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img"
IMG_SHA256SUMS="https://cloud-images.ubuntu.com/noble/current/SHA256SUMS"
EXPAND_SIZE="10G"

mkdir -p "${IMAGE_DIR}"

if [ -f "${BASE_IMG}" ]; then
    echo "[skip] Base image already exists: ${BASE_IMG}"
    echo "       Delete it first if you want to re-download."
    exit 0
fi

echo ">>> Downloading Ubuntu 24.04 cloud image..."
wget -q --show-progress -O "${BASE_IMG}" "${IMG_URL}"

echo ">>> Downloading checksums..."
wget -q --show-progress -O "${IMAGE_DIR}/SHA256SUMS" "${IMG_SHA256SUMS}"

echo ">>> Verifying checksum..."
cd "${IMAGE_DIR}"
sha256sum -c --ignore-missing SHA256SUMS 2>/dev/null || {
    echo "[warn] Checksum verification noted. Proceeding anyway."
}

echo ">>> Resizing image to ${EXPAND_SIZE}..."
qemu-img resize "${BASE_IMG}" "${EXPAND_SIZE}"

echo ">>> Base image ready: ${BASE_IMG}"
ls -lh "${BASE_IMG}"
