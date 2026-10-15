#!/usr/bin/env bash
set -u
. "$HOME/opt/env.sh"
echo "=== addi.log (tail) ==="
tail -30 "$HOME/suite_logs/baseline_h3only/addi.log" 2>/dev/null
echo
echo "=== manual run: addi ==="
cd "$HOME/BigBird-CPU-Lab/cdp-tests" || exit 1
make run TEST=addi CPU_DIR="$HOME/work/v9" 2>&1 | tail -25
echo "make exit: ${PIPESTATUS[0]}"
echo
echo "=== does the sim binary run at all? ==="
ls -la obj_dir/VminiRV_SoC
ls -la meminit.bin bin/addi.bin 2>&1
