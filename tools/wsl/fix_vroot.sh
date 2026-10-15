#!/usr/bin/env bash
# Bridge .deb layout -> source-install layout expected by the verilator perl wrapper.
set -u
VBIN="$HOME/opt/verilator/usr/bin"
VROOT="$HOME/opt/verilator/usr/share/verilator"

echo "=== how does the wrapper resolve verilator_bin? ==="
grep -n 'verilator_bin\|VERILATOR_ROOT' "$VBIN/verilator" | head -20

echo
echo "=== symlinking binaries into VERILATOR_ROOT ==="
for b in verilator_bin verilator_bin_dbg verilator_coverage_bin_dbg; do
    if [ -f "$VBIN/$b" ]; then
        ln -sf "$VBIN/$b" "$VROOT/$b"
        echo "  linked $b"
    fi
done

. "$HOME/opt/env.sh"
echo
echo "=== retry ==="
verilator --version 2>&1 | head -3

echo
echo "=== smoke test ==="
T="$HOME/opt/smoke"; cd "$T" || exit 1
verilator -cc --exe --build top.sv main.cpp --top-module top -Wno-lint 2>&1 | tail -4
if [ -x obj_dir/Vtop ]; then ./obj_dir/Vtop; else echo "SMOKE FAILED"; fi
