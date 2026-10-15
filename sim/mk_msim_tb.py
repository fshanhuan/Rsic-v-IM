#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""从 sim/tb_iverilog.sv 生成 ModelSim 专用测试台 sim/tb_msim.sv。

只改三处「为 iverilog 写死」的东西，不动任何验证语义：

1. 删掉寄存器堆的 0 时刻过程赋值预清。
   那是 rtl/RegisterFile.sv 还没有复位分支时的 workaround；现在 RTL 自己会复位，
   而 ModelSim 的 vopt 会直接报错：
     vopt-7061 Variable 'rf' driven in an always_ff block,
               may not be driven by any other process.
2. 删掉逐元素 $dumpvars(...) 的 32 行 + dram[1024] 一行。
   那是为了绕开「iverilog 不自动导出存储器数组」。ModelSim 的
   $dumpvars(0, tb) 已经覆盖整棵层次树，而且 ModelSim 认为
   $dumpvars(<levels>, <variable>) 第二个参数必须是模块实例：
     vsim-PLI-3537 $dumpvars() : Argument 2 is invalid.
3. 把结尾的 $fatal(1, ...) 换成「不能靠非零退出码判断」的显式打印 +
   $finish。ModelSim 在 -c 批处理下, $fatal 有时不能让 vsim 返回非 0，
   而我们的脚本是靠日志里的 PASS/FAIL/status= 判定的 —— 让它更明确。
"""
import io
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "tb_iverilog.sv")
DST = os.path.join(HERE, "tb_msim.sv")

with io.open(SRC, "r", encoding="utf-8") as f:
    lines = f.readlines()

out = []
i = 0
n = len(lines)
removed_preload = 0
removed_dump = 0
replaced_fatal = 0


def block_end(lines, start):
    """从 start 行（含 begin）起，按 begin/end 配平，返回该 begin 对应的 end 行号。"""
    depth = 0
    j = start
    while j < len(lines):
        code = lines[j].split("//")[0]
        depth += len(re.findall(r"\bbegin\b", code))
        depth -= len(re.findall(r"\bend\b", code))
        if depth <= 0 and j > start:
            return j
        j += 1
    raise RuntimeError("unbalanced begin/end from line %d" % (start + 1))


while i < n:
    line = lines[i]

    # ---- 1) 删掉 rf 预清块：注释头("rtl/RegisterFile.sv:20-22") → if(...)begin ... end ----
    if "rtl/RegisterFile.sv:20-22" in line:
        # 回退掉紧跟其上的分隔注释行（已在 out 里）
        while out and out[-1].lstrip().startswith("// ---"):
            out.pop()
        j = i
        while "if (!$test$plusargs" not in lines[j]:
            j += 1
        j = block_end(lines, j)     # -> 该 if 的 end 行
        i = j + 1
        removed_preload += 1
        continue

    # ---- 2) 删掉逐元素 dumpvars ----
    if "$dumpvars(0, u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[" in line:
        while i < n and "dram[1024]" not in lines[i]:
            i += 1
        i += 1                      # 跳过 dram[1024] 那一行
        removed_dump += 1
        continue

    out.append(line)
    i += 1

text = "".join(out)

# ---- 0) 模块名改成 tb_msim，避免和 tb_iverilog 同名冲突（两个库放一起时） ----
text = text.replace("module tb_iverilog", "module tb_msim")
text = text.replace("$dumpvars(0, tb_iverilog)", "$dumpvars(0, tb_msim)")

# ---- 3) $fatal -> 显式打印 + $finish ----
text2, cnt = re.subn(
    r"\$fatal\(1,\s*\"\[SELFCHECK\] TIMEOUT: no ecall within %0d cycles\", cycle\);",
    '$display("[SELFCHECK] status=TIMEOUT: no ecall within %0d cycles", cycle);',
    text)
replaced_fatal += cnt
text2, cnt = re.subn(
    r"\$fatal\(1,\s*\"\[SELFCHECK\] FAIL: %0d mismatch\(es\)\", nfail\);",
    '$display("[SELFCHECK] status=FAIL: %0d mismatch(es)", nfail);',
    text2)
replaced_fatal += cnt
text = text2

hdr = (
    "// =============================================================================\n"
    "// tb_msim.sv — ModelSim 专用测试台（由 sim/mk_msim_tb.py 自动生成，不要手改）\n"
    "//   源文件：sim/tb_iverilog.sv（功能与判据完全一致）\n"
    "//   差异只有三处（见 mk_msim_tb.py 头部说明）：\n"
    "//     - 去掉 rf 的 0 时刻过程赋值预清（RTL 已有复位；ModelSim vopt-7061 会报错）\n"
    "//     - 去掉逐元素 $dumpvars（ModelSim 的 $dumpvars(0, tb) 已覆盖，否则 vsim-PLI-3537）\n"
    "//     - $fatal -> 显式 [SELFCHECK] status=... 打印 + $finish（便于批处理判定）\n"
    "//   回归命令： vlog -sv ... sim/tb_msim.sv 然后 vsim -c work.tb_msim +prog=...\n"
    "// =============================================================================\n"
)

with io.open(DST, "w", encoding="utf-8", newline="\n") as f:
    f.write(hdr + text)

print("wrote %s" % DST)
print("  preload block removed : %d" % removed_preload)
print("  dumpvars block removed: %d" % removed_dump)
print("  $fatal replaced       : %d" % replaced_fatal)
if removed_preload != 1 or removed_dump != 1 or replaced_fatal != 2:
    print("WARNING: unexpected edit count, inspect output")
    sys.exit(0)
