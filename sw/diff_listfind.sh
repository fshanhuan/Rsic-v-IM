#!/usr/bin/env bash
# =============================================================================
# sw/diff_listfind.sh -- 用 CoreMark 的 CORE_DEBUG 打印做 x86/rv32 逐行对拍
# -----------------------------------------------------------------------------
# 关键点：两边都链**同一份** sw/cm_probe_port/ee_mini.c 做格式化，所以输出逐字节
# 可比；探针只跑 core_list_join 的路径（core_bench_list），每步数值都能对上。
#
# 用法： bash sw/diff_listfind.sh
# 产物： sw/build/lf_host.log / lf_rv.log （以及 .diff）
# =============================================================================
set -euo pipefail
source "$(dirname "$0")/env.sh"
cd "${PROJ_ROOT}"

OUT="${PROJ_ROOT}/sw/build"
CM="${PROJ_ROOT}/sw/coremark"
PORT="${PROJ_ROOT}/sw/coremark_port"
HPORT="${PROJ_ROOT}/sw/cm_probe_port"
mkdir -p "${OUT}"

DBG="-DCORE_DEBUG=1"

echo "======== 1) x86 ========"
gcc -O2 -DCM_HOST=1 ${DBG} -I "${HPORT}" -I "${CM}" \
    "${PROJ_ROOT}/sw/cm_probe.c" \
    "${CM}/core_list_join.c" "${CM}/core_matrix.c" "${CM}/core_state.c" "${CM}/core_util.c" \
    "${HPORT}/port_stub.c" "${HPORT}/ee_mini.c" \
    -o "${OUT}/lf_host" > "${OUT}/lf_host_build.log" 2>&1 || true
if [ ! -x "${OUT}/lf_host" ]; then echo "!! host 编译失败"; head -6 "${OUT}/lf_host_build.log"; exit 1; fi
"${OUT}/lf_host" > "${OUT}/lf_host.log" 2>&1 || true

echo "======== 2) rv32 ========"
CFLAGS=(
    $ARCH -O2 ${DBG}
    -ffreestanding -fno-builtin -fno-common
    -mno-relax -msmall-data-limit=0
    -fno-delete-null-pointer-checks
    -I "${PORT}" -I "${CM}" -I "${HPORT}"
)
OBJS=()
for f in "${PROJ_ROOT}/sw/cm_probe.c" "${CM}/core_list_join.c" "${CM}/core_matrix.c" \
         "${CM}/core_state.c" "${CM}/core_util.c" \
         "${HPORT}/port_stub.c" "${HPORT}/ee_mini.c" "${PORT}/libc_mini.c"; do
    o="${OUT}/lf_$(basename "$f" | tr '.' '_').o"
    riscv64-unknown-elf-gcc "${CFLAGS[@]}" -c "$f" -o "$o"
    OBJS+=("$o")
done
riscv64-unknown-elf-gcc $ARCH -c "${PORT}/crt0.S" -o "${OUT}/lf_crt0.o"
riscv64-unknown-elf-gcc $ARCH -nostdlib -Wl,--gc-sections -T "${PORT}/link.ld" \
    "${OUT}/lf_crt0.o" "${OBJS[@]}" -o "${OUT}/lf_rv.elf" -lgcc
riscv64-unknown-elf-objcopy -O binary "${OUT}/lf_rv.elf" "${OUT}/lf_rv.bin"
python3 "${PROJ_ROOT}/sw/elf2hex.py" "${OUT}/lf_rv.bin" --split 0x10000 \
    --irom "${OUT}/lf_irom.hex" --dram "${OUT}/lf_dram.hex" \
    --irom-words 16384 --dram-words 32768

bash "${PROJ_ROOT}/sw/run_coremark.sh" \
    +irom=sw/build/lf_irom.hex +dram=sw/build/lf_dram.hex +max=20000000 \
    > "${OUT}/lf_rv_raw.log" 2>&1 || true

# 只留程序输出（滤掉仿真台的 [sim]/[T]/[MEM]/[HITBAD]/[WBAD]/[TRAP] 行）
grep -vE '^\[(sim|T|MEM|HITBAD|WBAD|TRAP|S|F|L|R|DC)\]' "${OUT}/lf_rv_raw.log" \
    | grep -vE '^(== |\[sim\])' | sed 's/\r$//' > "${OUT}/lf_rv.log" || true

echo "======== 3) 对拍 ========"
echo "host 行数=$(wc -l < "${OUT}/lf_host.log")  rv32 行数=$(wc -l < "${OUT}/lf_rv.log")"
echo "--- 第一处差异（会显示上下文 3 行）---"
diff -u "${OUT}/lf_host.log" "${OUT}/lf_rv.log" | head -40 || true
