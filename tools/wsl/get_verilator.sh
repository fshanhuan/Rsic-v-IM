#!/usr/bin/env bash
# Get verilator WITHOUT sudo: download .deb, unpack to ~/opt, check it runs.
set -u
DEST="$HOME/opt"
WORK="$HOME/vdeb"
mkdir -p "$DEST" "$WORK"
cd "$WORK" || exit 1

echo "=== dependencies of the verilator package ==="
apt-cache depends verilator 2>&1 | head -20

echo
echo "=== perl present? ==="
perl -v 2>&1 | sed -n '2p'

echo
echo "=== downloading verilator .deb (no sudo) ==="
apt-get download verilator 2>&1 | tail -5
ls -la ./*.deb 2>/dev/null

deb="$(ls verilator_*.deb 2>/dev/null | head -1)"
if [ -z "$deb" ]; then echo "DOWNLOAD FAILED"; exit 2; fi

echo
echo "=== unpacking $deb -> $DEST ==="
rm -rf "$DEST/verilator"
mkdir -p "$DEST/verilator"
dpkg-deb -x "$deb" "$DEST/verilator"
find "$DEST/verilator" -maxdepth 3 -type d | head -10

echo
echo "=== locate binaries + share dir ==="
find "$DEST/verilator" -name 'verilator*' -maxdepth 5 | head -10
find "$DEST/verilator" -type d -name 'verilator' | head -5
