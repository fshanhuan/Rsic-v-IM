"""ila_i2c_decode.py -- 把 ila_i2c.csv 解成一条人类可读的 I2C 时间线。

位定义（与 project_src/board_top_rec.sv 里 u_ila_i2c 的拼接一致）：
    [7] init_no_dev  [6] hdmi_probed  [5] init_done  [4] init_busy
    [3] hdmi_sda_rd  [2] hdmi_scl_rd  [1] init_sda_oe [0] init_scl_oe

输出：
  1) 每一处电平变化的时刻（采样号 / ns / 谁变了 / 变到几）
  2) I2C 解码：START / STOP / 每个字节的 8 位 + 第 9 拍从机是否拉低（ACK）
  3) 结论：地址字节是多少、有没有 ACK
"""
import csv
import sys
from pathlib import Path

NS_PER_SAMPLE = 20.0          # 50 MHz


def load(path):
    rows = []
    with open(path, newline="", encoding="utf-8", errors="replace") as f:
        r = csv.reader(f)
        for row in r:
            if len(row) < 2:
                continue
            v = row[1].strip().strip('"').replace(" ", "")
            if set(v) <= {"0", "1"} and len(v) == 8:
                rows.append(v)
    return rows


def bits(v):
    # LSB 在右：字符串 v[7] 是 bit7
    return [int(c) for c in v]


def main():
    path = sys.argv[1] if len(sys.argv) > 1 else r"E:\FPGA\v9_vivado_ila\_diag\ila_i2c.csv"
    if not Path(path).exists():
        print(f"RESULT no_csv ({path})")
        return 1
    rows = load(path)
    if not rows:
        print("RESULT no_samples")
        return 1
    print(f"samples = {len(rows)}  ({len(rows)*NS_PER_SAMPLE/1000:.1f} us @50MHz)")

    scl = [bits(r)[2] for r in rows]
    sda = [bits(r)[3] for r in rows]
    done = [bits(r)[5] for r in rows]

    # ---- 1) 边沿表 ----
    print("\n-- 边沿（只打印相对上一拍的变化）--")
    last = rows[0]
    n_edges = 0
    for i in range(1, len(rows)):
        if rows[i] != last:
            a, b = bits(last), bits(rows[i])
            ch = []
            if a[2] != b[2]:
                ch.append(f"SCL {a[2]}->{b[2]}")
            if a[3] != b[3]:
                ch.append(f"SDA {a[3]}->{b[3]}")
            if ch:
                print(f"  #{i:5d}  {i*NS_PER_SAMPLE:9.0f} ns   " + "  ".join(ch))
                n_edges += 1
            last = rows[i]
    print(f"  (共 {n_edges} 个 SCL/SDA 边沿)")

    # ---- 2) I2C 解码 ----
    print("\n-- I2C 解码 --")
    events = []
    state = "idle"
    byte = 0
    nbit = 0
    for i in range(1, len(rows)):
        s_prev, d_prev = scl[i - 1], sda[i - 1]
        s, d = scl[i], sda[i]
        if s == 1 and s_prev == 1 and d != d_prev:
            events.append(("START" if d == 0 else "STOP", i, None, None))
            state = "addr" if d == 0 else "idle"
            byte, nbit = 0, 0
        elif s_prev == 0 and s == 1 and state != "idle":
            # SCL 上升沿：采样一位
            if nbit < 8:
                byte = (byte << 1) | d
                nbit += 1
            elif nbit == 8:
                events.append(("BYTE", i, byte, d))
                byte, nbit = 0, 0
    for kind, i, val, ack in events:
        if kind in ("START", "STOP"):
            print(f"  {kind:5s} @{i*NS_PER_SAMPLE:9.0f} ns")
        else:
            acktxt = "ACK(从机拉低)" if ack == 0 else "NACK(线上是高)"
            note = ""
            if val == 0x72:
                note = "  <= 0x72 = 7 位地址 0x39 写"
            print(f"  BYTE  0x{val:02X}  {acktxt}{note}  @{i*NS_PER_SAMPLE:9.0f} ns")

    # ---- 3) 结论 ----
    print("\n-- 结论 --")
    n_scl_h = sum(1 for x in scl if x)
    print(f"  SCL 高电平采样数 = {n_scl_h}/{len(scl)}  ({100.0*n_scl_h/len(scl):.1f}%)")
    prints = [e for e in events if e[0] == "BYTE"]
    if not prints:
        print("  RESULT no_byte_decoded（这段里没有完整字节：可能抓在了两次重试之间）")
        return 0
    acked = [e[2] for e in prints if e[3] == 0]
    if acked:
        print(f"  RESULT ack_seen  bytes={[hex(b) for b in acked[:4]]}")
    else:
        print(f"  RESULT all_nack  bytes={[hex(e[2]) for e in prints[:4]]}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
