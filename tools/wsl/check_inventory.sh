#!/usr/bin/env bash
set -u
SUITE="$HOME/BigBird-CPU-Lab/cdp-tests"
echo "=== bin/ full listing ==="
ls -1 "$SUITE/bin" | head -60
echo "count(*.bin): $(ls -1 "$SUITE/bin"/*.bin 2>/dev/null | wc -l)"

echo
echo "=== any intr mechanism? ==="
grep -rn 'intr' "$SUITE/Makefile" 2>/dev/null | head -10
ls -1 "$SUITE"/bin/*intr* 2>/dev/null || echo "(no intr bin files)"

echo
echo "=== upstream README: how many tests are claimed? ==="
grep -rn 'cdp-tests\|47\|test' "$HOME/BigBird-CPU-Lab/README.md" 2>/dev/null | head -15

echo
echo "=== is there an intr test dir elsewhere? ==="
find "$HOME/BigBird-CPU-Lab" -maxdepth 3 -iname '*intr*' 2>/dev/null | head -10
