#!/usr/bin/env bash
# The v9 README claims cdp-tests has 47 tests = 39 RV32I + 8 RV32M.
# Our clone has exactly 39. Where are the 8 RV32M ones?
set -u
R="$HOME/BigBird-CPU-Lab"
echo "=== bin/ count ==="
ls -1 "$R/cdp-tests/bin"/*.bin | wc -l

echo
echo "=== any mul/div named artifacts anywhere in the repo? ==="
find "$R" -iname '*mul*' -o -iname '*div*' 2>/dev/null | grep -v '\.git/' | head -20

echo
echo "=== cdp-tests/vsrc ==="
ls -1 "$R/cdp-tests/vsrc" 2>/dev/null
echo "=== cdp-tests/csrc ==="
ls -1 "$R/cdp-tests/csrc" 2>/dev/null
echo "=== cdp-tests/mySoC ==="
ls -1 "$R/cdp-tests/mySoC" 2>/dev/null

echo
echo "=== does anything mention RV32M / MUL / DIV in the test framework? ==="
grep -rln 'MUL\|DIV\|mul_\|div_' "$R/cdp-tests" 2>/dev/null | head -10

echo
echo "=== git branches / tags (are the 8 tests on another ref?) ==="
cd "$R" && git log --oneline -3 2>/dev/null
git branch -a 2>/dev/null | head
git tag 2>/dev/null | head

echo
echo "=== README claim ==="
grep -n '39\|47\|RV32M\|RV32I' "$R/README.md" 2>/dev/null | head -12
