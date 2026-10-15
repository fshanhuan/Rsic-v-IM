#!/usr/bin/env bash
# WSL reconnaissance for v9: toolchain + official differential suite.
echo "=== kernel / distro ==="
uname -srm
. /etc/os-release 2>/dev/null && echo "$PRETTY_NAME"

echo
echo "=== tools ==="
for t in verilator make g++ gcc python3 git iverilog yosys; do
    p="$(command -v "$t" 2>/dev/null)"
    printf '%-10s %s\n' "$t" "${p:-MISSING}"
done

echo
echo "=== versions ==="
verilator --version 2>&1 | head -1
make --version 2>&1 | head -1
g++ --version 2>&1 | head -1
python3 --version 2>&1 | head -1
iverilog -V 2>&1 | head -1

echo
echo "=== search for official suite (cdp-tests / BigBird) ==="
for d in /root /home /opt /srv /usr/local /mnt/c /mnt/d /mnt/e; do
    [ -d "$d" ] || continue
    find "$d" -maxdepth 4 \( -iname '*cdp-tests*' -o -iname '*BigBird*' \) 2>/dev/null | head -5
done
echo "(search done)"

echo
echo "=== can we see the v9 trees? ==="
for p in "/mnt/e/share doc/v9" "/mnt/e/FPGA/v9_vivado_ila"; do
    if [ -d "$p" ]; then
        echo "OK   $p  ($(ls "$p" | wc -l) entries)"
    else
        echo "MISS $p"
    fi
done

echo
echo "=== free space / tmp ==="
df -h /tmp /root 2>/dev/null | sed -n '1,5p'
