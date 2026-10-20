#!/usr/bin/env bash
# 一次性体检：确认工具链能出 rv32im 目标码，且 libgcc 有 rv32 版本。
source "$(dirname "$0")/env.sh"

set +e
echo "== gcc =="
riscv64-unknown-elf-gcc --version | head -1

echo "== multilib =="
riscv64-unknown-elf-gcc -print-multi-lib

echo "== test compile =="
cat > /tmp/t.c <<'EOF'
volatile int g;
int f(int a) { return a * 3 + 1; }
int main(void) { g = f(7); return g; }
EOF
riscv64-unknown-elf-gcc $ARCH -O2 -c /tmp/t.c -o /tmp/t.o
echo "rc=$?"
riscv64-unknown-elf-objdump -d /tmp/t.o | head -20

echo "== libgcc =="
riscv64-unknown-elf-gcc $ARCH -print-libgcc-file-name
ls -l "$(riscv64-unknown-elf-gcc $ARCH -print-libgcc-file-name)" 2>&1
