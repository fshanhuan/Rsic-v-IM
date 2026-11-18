# =============================================================================
# gen_font5x7.py — 生成 board/font5x7.sv（5x7 点阵字模 ROM）
# -----------------------------------------------------------------------------
# 为什么要"生成"而不是手写 SV 的 case 分支：
#   字模是**图形数据**，手写成十六进制常量没法检查对错；写成 ASCII 图之后，
#   形状在源码里就是可见的，改起来也直观。生成器顺手做两件事：
#     1) 检查每个字形必须正好 7 行 × 5 列，只允许 '.' 和 '#'；
#     2) 生成完再把 ROM 反解回 ASCII 打印一遍（自检），和源图不一致就报错。
#
# 用法：
#   python tools/gen_font5x7.py           # 生成 + 自检
#   python tools/gen_font5x7.py --check   # 只自检，不写文件（给 CI/回归用）
#
# 覆盖字符：空格 0-9 . - : 以及 V P M I N A X E F S C —— 正好够记录仪的
#   数值面板（VPP / MIN / MAX / MEAN / FPS / ℃ 用 C 表示）使用。
# =============================================================================
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "board" / "font5x7.sv"

# ---- 字模：每个字形 7 行、每行 5 列；'#' = 亮点 ----
GLYPHS = {
    " ": ["....."] * 7,
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#####"],
    "3": ["####.", "....#", "....#", ".###.", "....#", "....#", "####."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
    ".": [".....", ".....", ".....", ".....", ".....", ".##..", ".##.."],
    "-": [".....", ".....", ".....", "#####", ".....", ".....", "....."],
    ":": [".....", ".##..", ".##..", ".....", ".##..", ".##..", "....."],
    "V": ["#...#", "#...#", "#...#", "#...#", "#...#", ".#.#.", "..#.."],
    "P": ["####.", "#...#", "#...#", "####.", "#....", "#....", "#...."],
    "M": ["#...#", "##.##", "#.#.#", "#.#.#", "#...#", "#...#", "#...#"],
    "I": [".###.", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "N": ["#...#", "##..#", "#.#.#", "#..##", "#...#", "#...#", "#...#"],
    "A": [".###.", "#...#", "#...#", "#####", "#...#", "#...#", "#...#"],
    "X": ["#...#", "#...#", ".#.#.", "..#..", ".#.#.", "#...#", "#...#"],
    "E": ["#####", "#....", "#....", "####.", "#....", "#....", "#####"],
    "F": ["#####", "#....", "#....", "####.", "#....", "#....", "#...."],
    "S": [".###.", "#...#", "#....", ".###.", "....#", "#...#", ".###."],
    "C": [".###.", "#...#", "#....", "#....", "#....", "#...#", ".###."],
}

ORDER = [" ", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9",
         ".", "-", ":", "V", "P", "M", "I", "N", "A", "X", "E", "F", "S", "C"]


def validate():
    """结构检查：必须是 7 行、每行 5 个字符、只有 . 和 #"""
    bad = 0
    for ch, rows in GLYPHS.items():
        if len(rows) != 7:
            print(f"[FAIL] '{ch}' 行数 {len(rows)} != 7")
            bad += 1
        for r, row in enumerate(rows):
            if len(row) != 5 or set(row) - {".", "#"}:
                print(f"[FAIL] '{ch}' 第 {r} 行非法: {row!r}")
                bad += 1
    return bad


def to_hex(rows):
    """5 位宽，左对齐到 bit[4]"""
    return [sum(1 << (4 - i) for i, c in enumerate(row) if c == "#") for row in rows]


def render_from_hex(vals):
    out = []
    for v in vals:
        out.append("".join("#" if v & (1 << (4 - i)) else "." for i in range(5)))
    return out


def emit_sv():
    lines = []
    lines.append("`timescale 1ns / 1ps")
    lines.append("")
    lines.append("/* =============================================================================")
    lines.append(" * font5x7.sv — 5x7 点阵字模 ROM（**由 tools/gen_font5x7.py 自动生成，请勿手改**）")
    lines.append(" * -----------------------------------------------------------------------------")
    lines.append(" * 字符集（共 %d 个）: %s" % (len(ORDER), "".join(c for c in ORDER)))
    lines.append(" * 接口：ch 是字符索引（不是 ASCII），row 是行号 0..6，输出 5 位行点阵（bit4 = 最左）")
    lines.append(" *")
    lines.append(" * 为什么用索引而不是 ASCII：索引 5 位就够，ROM 只有 25 项；")
    lines.append(" * 软件侧只写索引，映射表见本文件末尾的注释。")
    lines.append(" * ============================================================================= */")
    lines.append("module font5x7 (")
    lines.append("    input  logic [4:0] ch,      // 字符索引 0..%d" % (len(ORDER) - 1))
    lines.append("    input  logic [2:0] row,     // 行号 0..6")
    lines.append("    output logic [4:0] bits     // 5 位行点阵，bit4 = 最左")
    lines.append(");")
    lines.append("")
    lines.append("    function automatic logic [4:0] frow(input logic [4:0] c, input logic [2:0] r);")
    lines.append("        case (c)")
    for idx, ch in enumerate(ORDER):
        vals = to_hex(GLYPHS[ch])
        cases = " ".join("3'd%d: frow = 5'b%s;" % (r, format(v, "05b")) for r, v in enumerate(vals))
        lines.append("            5'd%02d: case (r) %s default: frow = 5'b00000; endcase   // '%s'"
                     % (idx, cases, ch))
    lines.append("            default: frow = 5'b00000;")
    lines.append("        endcase")
    lines.append("    endfunction")
    lines.append("")
    lines.append("    assign bits = frow(ch, row);")
    lines.append("")
    lines.append("endmodule")
    lines.append("")
    lines.append("/* 索引表：")
    for idx, ch in enumerate(ORDER):
        lines.append(" *   %2d = '%s'" % (idx, ch))
    lines.append(" */")
    return "\n".join(lines) + "\n"


def selftest():
    """反解校验：把 ROM 里的值再渲染成 ASCII，和源图逐字符比"""
    bad = 0
    for ch in ORDER:
        src = GLYPHS[ch]
        vals = to_hex(src)
        back = render_from_hex(vals)
        if back != src:
            print(f"[FAIL] '{ch}' 反解不一致")
            for a, b in zip(src, back):
                if a != b:
                    print(f"    源 {a}  反解 {b}")
            bad += 1
    if bad == 0:
        print("[FONT] 反解自检通过（%d 字形）" % len(ORDER))
    return bad


def print_all():
    """把全部字形打印成 ASCII 图，人工可核对形状"""
    per_line = 8
    names = ORDER
    for start in range(0, len(names), per_line):
        chunk = names[start:start + per_line]
        print("  ".join(f" '{c}'  " for c in chunk))
        for r in range(7):
            print("  ".join(GLYPHS[c][r] for c in chunk))
        print()


def main():
    check_only = "--check" in sys.argv
    bad = validate()
    if bad:
        print(f"[FONT] 结构检查失败 {bad} 处")
        return 1
    bad += selftest()
    if bad:
        return 1
    if check_only:
        print("[FONT] check OK（未写文件）")
        return 0
    OUT.write_text(emit_sv(), encoding="utf-8", newline="\n")
    print(f"[FONT] 已生成 {OUT.relative_to(ROOT)}（{len(ORDER)} 字形）")
    print_all()
    return 0


if __name__ == "__main__":
    sys.exit(main())
