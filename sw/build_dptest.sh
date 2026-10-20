#!/usr/bin/env bash
# =============================================================================
# sw/build_dptest.sh -- 两遍编译 sw/dptest.c（自校验 IROM 数据窗口）
# -----------------------------------------------------------------------------
# 为什么必须两遍：
#   dptest 校验"IROM 前 64 个字的校验和"，期望值必须由**链接后的镜像**算出来。
#   第一遍先占位编译 → 从 irom.hex 读出前 64 个字算校验和 → 把值写回 .data
#   （sw/dptest.c 里的 dp_expect_ck）→ 第二遍编译。
#   ★ 期望值放在**可写变量**（.data / DRAM）里，不能是立即数：立即数会进 .text，
#     而 .text 正是被校验的对象 —— 自我指涉，永远对不上。
#   ★ 脚本末尾会断言"第二遍的 .text 与第一遍逐字节相同"，否则说明校验和变了，
#     需要再迭代一次（正常情况下不会）。
#
# 用法： bash sw/build_dptest.sh
# 产物： sw/build/dptest_irom.hex / dptest_dram.hex
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"

OUT="${PROJ_ROOT}/sw/build"
PORT="${PROJ_ROOT}/sw/coremark_port"
SRC="${PROJ_ROOT}/sw/dptest.c"
mkdir -p "${OUT}"

CFLAGS=(
    $ARCH -O2
    -ffreestanding -fno-builtin -fno-common
    -mno-relax -msmall-data-limit=0
    -Wall -Wno-unused-parameter
)

# 把 dp_expect_ck 的初值改成 $1（十进制或 0x）
set_expect() {
    python3 - "$SRC" "$1" <<'PY'
import re, sys
src, val = sys.argv[1], sys.argv[2]
s = open(src, encoding='utf-8').read()
s2 = re.sub(r'volatile unsigned int dp_expect_ck = 0x[0-9A-Fa-f]+u?;',
            'volatile unsigned int dp_expect_ck = %s;' % val, s)
if s2 == s and ('= %s;' % val) not in s:
    sys.exit('[build_dptest] 找不到 dp_expect_ck 的定义，拒绝继续')
open(src, 'w', encoding='utf-8', newline='\n').write(s2)
PY
}

build() {
    riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${SRC}" -o "${OUT}/dptest.o"
    riscv64-unknown-elf-gcc $ARCH -c "${PORT}/crt0.S"        -o "${OUT}/dptest_crt0.o"
    riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "${PORT}/libc_mini.c" -o "${OUT}/dptest_libc.o"
    riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${PORT}/link.ld" \
        "${OUT}/dptest_crt0.o" "${OUT}/dptest.o" "${OUT}/dptest_libc.o" \
        -o "${OUT}/dptest.elf" -lgcc
    riscv64-unknown-elf-objcopy -O binary "${OUT}/dptest.elf" "${OUT}/dptest.bin"
    python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/dptest.bin" \
        --split 0x10000 \
        --irom "${OUT}/dptest_irom.hex" --dram "${OUT}/dptest_dram.hex" \
        --irom-words 16384 --dram-words 32768 > /dev/null
}

cksum() {
    python3 - "${OUT}/dptest_irom.hex" <<'PY'
import sys
words = []
for line in open(sys.argv[1], encoding='utf-8'):
    line = line.strip()
    if line:
        words.append(int(line, 16) & 0xFFFFFFFF)
ck = 5381
for w in words[:64]:
    ck = ((ck << 5) - ck + w) & 0xFFFFFFFF
print('0x%08X' % ck)
PY
}

echo "== pass 1 (占位) =="
set_expect 0xDEADBEEF
build
CK=$(cksum)
echo "   IROM[0..63] 校验和 = ${CK}"
cp "${OUT}/dptest_irom.hex" "${OUT}/dptest_irom.pass1.hex"

echo "== pass 2 (回填期望值) =="
set_expect "${CK}"
build
CK2=$(cksum)
echo "   回填后再算一次 = ${CK2}"
if [ "${CK}" != "${CK2}" ]; then
    echo "!! .text 变了（校验和自指涉），再迭代一遍"
    set_expect "${CK2}"
    build
    CK3=$(cksum)
    echo "   第三遍 = ${CK3}"
    [ "${CK2}" = "${CK3}" ] || { echo "!! 仍然不稳定，放弃"; exit 1; }
fi

if cmp -s "${OUT}/dptest_irom.pass1.hex" "${OUT}/dptest_irom.hex"; then
    echo "   .text 稳定（两遍 IROM 镜像逐字节相同）"
else
    echo "   !! 两遍 .text 不同 —— 校验和会失配，请检查 dp_expect_ck 是否被编进 .text"
    exit 1
fi

riscv64-unknown-elf-size "${OUT}/dptest.elf"
echo "== done: sw/build/dptest_irom.hex / dptest_dram.hex =="
