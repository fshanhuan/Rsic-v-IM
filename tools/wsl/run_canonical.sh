#!/usr/bin/env bash
# Run the official cdp-tests suite against the CANONICAL tree (not staging).
# usage: run_canonical.sh <label>
set -u
. "$HOME/opt/env.sh"

LABEL="${1:-canonical}"
CANON="/mnt/e/share doc/v9"
WORK="$HOME/work/v9_canon"
SUITE="$HOME/BigBird-CPU-Lab/cdp-tests"
LOGDIR="$HOME/suite_logs/$LABEL"

echo "=== sync CANONICAL -> $WORK ==="
rm -rf "$WORK"; mkdir -p "$WORK"
cp "$CANON"/rtl/*.sv "$WORK"/ || exit 1
cp "$CANON"/*.v  "$WORK"/ 2>/dev/null
echo "files: $(ls "$WORK" | wc -l)"
echo "MDU_pipelined.sv present at top: $([ -f "$WORK/MDU_pipelined.sv" ] && echo YES || echo NO)"
echo "MDU-4 guard note: $(grep -c 'MDU-4' "$WORK/MDU_pipelined.sv")"
echo "up_stall in EXU.sv: $(grep -c 'up_stall' "$WORK/EXU.sv")"
echo "H2 mem_mask fix  : $(grep -c 'mem_en | mem_req_r' "$WORK/DCache.sv")"

echo
echo "=== rebuild ==="
cd "$SUITE" || exit 1
make clean >/dev/null 2>&1
timeout 1500 make build CPU_DIR="$WORK" 2>&1 | tail -4
if [ ! -x obj_dir/VminiRV_SoC ]; then echo "BUILD FAILED"; exit 1; fi
echo "SIM BINARY OK"

echo
mkdir -p "$LOGDIR"
pass=0; fail=0; failed=""
for t in $(ls -1 bin/*.bin | xargs -n1 basename | sed 's/\.bin$//'); do
    out="$(timeout 180 make run TEST="$t" CPU_DIR="$WORK" 2>&1)"
    rc=$?
    if [ $rc -eq 0 ] && ! printf '%s' "$out" | grep -q 'Timed out!'; then
        pass=$((pass+1)); printf '.'
    else
        fail=$((fail+1)); failed="$failed $t"
        printf '\nFAIL %s (rc=%s)\n' "$t" "$rc"
        printf '%s\n' "$out" > "$LOGDIR/$t.log"
    fi
done
echo
echo
echo "=========== $LABEL (canonical tree) ==========="
echo "passed: $pass"
echo "failed: $fail"
echo "failed list:$failed"
