#!/usr/bin/env bash
# Can we obtain verilator + the official cdp-tests suite?
echo "=== who am i ==="
id -un; id -u

echo
echo "=== passwordless sudo? ==="
if sudo -n true 2>/dev/null; then echo "SUDO_OK (passwordless)"; else echo "SUDO_NEEDS_PASSWORD_OR_UNAVAILABLE"; fi

echo
echo "=== network ==="
for u in https://github.com https://deb.debian.org http://archive.ubuntu.com; do
    code="$(curl -sS -o /dev/null -m 8 -w '%{http_code}' "$u" 2>/dev/null)"
    printf '%-30s %s\n' "$u" "${code:-FAILED}"
done

echo
echo "=== apt: is verilator known / installable? ==="
apt-cache policy verilator 2>&1 | head -8

echo
echo "=== apt lists present? ==="
ls /var/lib/apt/lists/ 2>/dev/null | head -3
echo "count: $(ls /var/lib/apt/lists/ 2>/dev/null | wc -l)"
