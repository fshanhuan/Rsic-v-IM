#!/usr/bin/env bash
# 非 root 安装 iverilog：apt-get download + dpkg -x 到本地前缀，不改动系统
set -euo pipefail
PREFIX="$HOME/ivlocal"
WORK="$HOME/ivwork"
mkdir -p "$PREFIX" "$WORK"
cd "$WORK"

if [ ! -x "$PREFIX/usr/bin/iverilog" ]; then
  echo "=== apt-get download iverilog ==="
  apt-get download iverilog 2>&1 | tail -5
  DEB=$(ls -1 iverilog_*.deb | head -1)
  echo "deb = $DEB"
  dpkg -x "$DEB" "$PREFIX"
fi

echo "=== installed tree ==="
find "$PREFIX" -maxdepth 4 -name 'iverilog*' -o -maxdepth 4 -name 'vvp*' | head -20

IV="$PREFIX/usr/bin/iverilog"
echo "=== version ==="
LD_LIBRARY_PATH="$PREFIX/usr/lib/x86_64-linux-gnu:${LD_LIBRARY_PATH:-}" "$IV" -V 2>&1 | head -5 || echo "FAILED to run iverilog"
