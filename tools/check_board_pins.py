# =============================================================================
# check_board_pins.py — 把 XDC 里的引脚和 EES-331 手册的官方引脚表逐脚核对
# -----------------------------------------------------------------------------
# 为什么要这个脚本：
#   "引脚写错了"是这类板级项目最难查的一类 bug —— 综合能过、下载能过、
#   板上就是没反应，而且不会报任何错。本项目已经踩过一次类似的问题
#   （I2C 扫错地址，见 docs/记录仪_HDMI_方案.md §7.5）。
#   所以把"手册表 ↔ XDC"的比对做成可重复执行的检查，而不是靠人眼看一遍。
#
# 用法：
#   python tools/check_board_pins.py
# 退出码：0 = 全部一致；1 = 有不一致（会逐条打印）
# =============================================================================
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANUAL = ROOT / "_diag" / "ees331_manual.txt"
XDC = ROOT / "v9_board_rec.xdc"


def load_manual_pins():
    """从手册文本里抽 {'HDIMI_D0': 'R7', ...}。手册表是四列：序号 器件引脚 引脚标号 FPGA IO 方向。"""
    txt = MANUAL.read_text(encoding="utf-8", errors="replace")
    pins = {}
    # 形如：  1 HDIMI_D0 U30-88 R7
    # 手册里两种列顺序都存在，必须分开匹配：
    #   HDMI 表： 序号  信号名   器件引脚( U30-88 )  FPGA 脚
    #   DAC  表： 序号  器件引脚( U24-1 )  信号名    FPGA 脚   方向
    pat_a = re.compile(r"^\s*\d+\s+(\S+)\s+U\d+-\d+\s+([A-Z]{1,2}\d{1,2})\s*$")
    pat_b = re.compile(
        r"^\s*\d+\s+U\d+-\d+\s+(\S+)\s+([A-Z]{1,2}\d{1,2})\s+(?:OUTPUT|INPUT|INOUT)\s*$")
    for line in txt.splitlines():
        m = pat_a.match(line) or pat_b.match(line)
        if m:
            name, fpga = m.group(1), m.group(2)
            pins.setdefault(name, fpga)
    return pins


def load_xdc_pins():
    """从 XDC 抽 {(信号): (PACKAGE_PIN)}，信号名去掉 [n] 下标。"""
    txt = XDC.read_text(encoding="utf-8", errors="replace")
    out = {}
    for line in txt.splitlines():
        line = line.strip()
        if not line.startswith("set_property"):
            continue
        m = re.search(r"PACKAGE_PIN\s+([A-Z]{1,2}\d{1,2})", line)
        if not m:
            continue
        pin = m.group(1)
        # 两种写法：{hdmi_d[0]}（带花括号，名字里本身含 ]）和 adc_p11（不带）
        m2 = re.search(r"\[get_ports\s+\{([^}]+)\}\]", line)
        if m2:
            sig = m2.group(1).strip()
        else:
            m3 = re.search(r"\[get_ports\s+([^\]\s]+)\]", line)
            if not m3:
                continue
            sig = m3.group(1).strip()
        mm = re.match(r"^(\w+)\[(\d+)\]$", sig)
        key = f"{mm.group(1)}[{mm.group(2)}]" if mm else sig
        out[key] = pin
    return out


def main():
    mp = load_manual_pins()
    xp = load_xdc_pins()

    # XDC 信号名 → 手册引脚名
    mapping = {"hdmi_de": "HDMI_DE", "hdmi_hsync": "HDMI_HSYNC",
               "hdmi_vsync": "HDMI_VSYNC", "hdmi_clk": "HDMI_CLK",
               "hdmi_scl": "IIC_SCL_HDMI", "hdmi_sda": "IIC_SDA_HDMI",
               "dac_cs_n": "DAC_CS#", "dac_wr1_n": "DAC_WR1#",
               "dac_wr2_n": "DAC_WR2#", "dac_xfer_n": "DAC_XFER#",
               "dac_ile": "DAC_BYTE2"}
    for i in range(16):
        mapping[f"hdmi_d[{i}]"] = f"HDIMI_D{i}"
    dac_bits = {7: "DAC_D7", 6: "DAC_D6", 5: "DAC_D5", 4: "DAC_D4",
                3: "DAC_D3", 2: "DAC_D2", 1: "DAC_D1", 0: "DAC_D0"}
    for i, nm in dac_bits.items():
        mapping[f"dac_d[{i}]"] = nm

    rows, bad, unknown = [], 0, 0
    for sig, man_name in mapping.items():
        if sig not in xp:
            rows.append((sig, man_name, "(XDC 里没有)", "-", "MISSING"))
            bad += 1
            continue
        exp = mp.get(man_name)
        got = xp[sig]
        if exp is None:
            rows.append((sig, man_name, got, "(手册未找到)", "SKIP"))
            unknown += 1
        elif exp == got:
            rows.append((sig, man_name, got, exp, "PASS"))
        else:
            rows.append((sig, man_name, got, exp, "FAIL"))
            bad += 1

    # XADC 模拟脚（手册 §18：AD11 = A18/A19）
    for sig, exp in (("adc_p11", "A18"), ("adc_n11", "A19")):
        got = xp.get(sig, "(缺失)")
        ok = (got == exp)
        rows.append((sig, "XADC AD11", got, exp, "PASS" if ok else "FAIL"))
        if not ok:
            bad += 1

    w = max(len(r[0]) for r in rows) + 2
    print(f"{'XDC 信号':<{w}}{'手册引脚名':<18}{'XDC':<8}{'手册':<8}结果")
    print("-" * (w + 46))
    for sig, man, got, exp, st in rows:
        print(f"{sig:<{w}}{man:<18}{got:<8}{str(exp):<8}{st}")
    print("-" * (w + 46))
    print(f"共 {len(rows)} 项：PASS={sum(1 for r in rows if r[4]=='PASS')} "
          f"FAIL={bad} SKIP={unknown}")
    if bad == 0:
        print("[BOARD-PINS] OK — XDC 与手册官方引脚表逐脚一致")
        return 0
    print("[BOARD-PINS] MISMATCH — 见上表 FAIL/MISSING 行")
    return 1


if __name__ == "__main__":
    sys.exit(main())
