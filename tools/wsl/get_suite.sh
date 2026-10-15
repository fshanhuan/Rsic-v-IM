#!/usr/bin/env bash
# Shallow-clone the official BigBird-CPU-Lab suite and inspect cdp-tests.
set -u
DST="$HOME/BigBird-CPU-Lab"
if [ -d "$DST/.git" ]; then
    echo "already cloned: $DST"
else
    echo "=== cloning (shallow) ==="
    git clone --depth 1 https://github.com/hongpengWu/BigBird-CPU-Lab.git "$DST" 2>&1 | tail -6
fi

echo
echo "=== top level ==="
ls -1 "$DST" 2>/dev/null

echo
echo "=== cdp-tests ==="
ls -1 "$DST/cdp-tests" 2>/dev/null

echo
echo "=== cdp-tests/Makefile (first 60 lines) ==="
sed -n '1,60p' "$DST/cdp-tests/Makefile" 2>/dev/null

echo
echo "=== how many .bin tests? ==="
ls "$DST/cdp-tests/bin"/*.bin 2>/dev/null | wc -l
ls "$DST/cdp-tests/bin" 2>/dev/null | head -8
