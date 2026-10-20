#!/usr/bin/env bash
# =============================================================================
# sw/env.sh -- RISC-V 工具链环境（WSL 内，无需 sudo）
# -----------------------------------------------------------------------------
# 工具链来自 Ubuntu 的 deb 包，用 dpkg -x 解到 ~/rv32/sysroot：
#     apt-get download gcc-riscv64-unknown-elf binutils-riscv64-unknown-elf
#     dpkg -x <deb> ~/rv32/sysroot
# 不装进系统，不改 PATH 的全局配置，退出 shell 就干净。
#
# 用法：  source sw/env.sh && riscv64-unknown-elf-gcc --version
# =============================================================================
RV_BIN="${HOME}/rv32/sysroot/usr/bin"
export PATH="${RV_BIN}:${PATH}"
export CROSS="riscv64-unknown-elf"
# ★ zicsr 必须显式声明：gcc 13 起 csrr/csrw 不再隐含在 rv32i 里，
#   而本核有完整的 Zicsr（v12 回归覆盖），所以目标串是 rv32im_zicsr。
#   多库选择仍落在 rv32im/ilp32（libgcc 用那一份）。
export ARCH="-march=rv32im_zicsr -mabi=ilp32"

# 仓库根目录（本文件在 sw/ 下）
SW_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "${SW_DIR}/.." && pwd)"
export PROJ_ROOT
