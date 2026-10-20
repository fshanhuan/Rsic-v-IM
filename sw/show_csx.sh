#!/usr/bin/env bash
# 一次性查看 FreeRTOS 内核里 chip_specific_extensions 的示例头，决定我们的写法
set -u
D="${HOME}/rv32/FreeRTOS-Kernel/portable/GCC/RISC-V/chip_specific_extensions"
echo "== tree =="
ls -R "${D}" | head -40
echo
echo "== RV32I_CLINT_no_extensions =="
cat "${D}/RV32I_CLINT_no_extensions/freertos_risc_v_chip_specific_extensions.h" 2>/dev/null
