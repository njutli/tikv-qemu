#!/bin/bash
set -euo pipefail

# ============================================================
# Build and run TiKV RawKV read/write test
# Simulates JuiceFS metadata patterns
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEST_DIR="${SCRIPT_DIR}/tests"

echo "========================================"
echo "TiKV RawKV Test for JuiceFS Metadata"
echo "========================================"

# Install Go if needed
if ! command -v go &>/dev/null; then
    echo ">>> Installing Go..."
    sudo apt-get update -qq && sudo apt-get install -y -qq golang-go
fi

echo "Go version: $(go version)"

# Build test program
cd "${SCRIPT_DIR}"
echo ">>> Building test program..."
cd tests
go mod tidy 2>&1 | tail -3
go build -o /tmp/tikv-rawkv-test tikv-rawkv-test.go

echo ""
echo ">>> Running test..."
# Unset proxy so gRPC connects directly to PD at 172.16.0.101:2379
# (otherwise Go's gRPC transport routes through proxy, which doesn't handle gRPC)
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
/tmp/tikv-rawkv-test

echo ""
echo "Test complete."
rm -f /tmp/tikv-rawkv-test
