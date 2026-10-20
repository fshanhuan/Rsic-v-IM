#!/usr/bin/env bash
# 一次性排查：-g 重编 core_list_join.c，看 d20/d24 那个 ebreak 对应哪一行 C 源码
source "$(dirname "$0")/env.sh"
cd "${PROJ_ROOT}"
OUT=/tmp/cmdbg
mkdir -p ${OUT}
riscv64-unknown-elf-gcc $ARCH -O2 -g -ffreestanding -fno-builtin -fno-common \
    -fno-asynchronous-unwind-tables -fno-unwind-tables -mno-relax -msmall-data-limit=0 \
    -I sw/coremark_port -I sw/coremark \
    -c sw/coremark/core_list_join.c -o ${OUT}/cl.o
echo "== disasm around ebreak =="
riscv64-unknown-elf-objdump -d -l -S ${OUT}/cl.o | grep -B 25 -A 3 "ebreak" | head -120
