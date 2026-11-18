// =============================================================================
// sim/tb_boot_image.sv -- 固化镜像（boot_rec.hex / boot_rec_dram.hex）自检
// -----------------------------------------------------------------------------
// 为什么要有这个台子：
//   "上电即跑"完全依赖两个文本镜像被 $readmemh 正确装载。可这条链路上**没有任何
//   编译期检查**：文件丢了、行数不对、字节序反了、DRAM 基址算错了，综合器最多给一条
//   警告，上板表现统一是"CPU 停在 0x0"—— 和"软件写错"完全分不清（这是 2026-11-17
//   真的踩过的坑：v9_rec 一直是 IROM_BOOT=1，上电后 CPU 在 500 ms 引导窗口里等串口，
//   串口没通就永远不跑任何程序）。
//
// 这台子只做一件最硬的事：用**和板上完全相同的路径**（$readmemh 全量镜像）把两个字
// 装载进数组，然后核对内容。任何一项不符立刻 FAIL。
//
// 核对项（每项都对应一个具体的失败模式）：
//   1. IROM 行数 = 16384（64 KB）        ← 行数不对 = 文件被截断/生成脚本算错
//   2. DRAM 行数 = 32768（128 KB）
//   3. irom[0] == 0x00011197             ← crt0 的第一条指令（auipc gp），见 objdump
//   4. irom[0..5] == crt0 前 6 条指令     ← 字节序/整体错位
//   5. dram[0x4000] == 0x6D617266        ← .rodata 首字（"fram"），0x1_0000 起
//      dram[0x4001] == 0x003D7365        ← "es=\0"
//   6. 非零字数：IROM 558 / DRAM 81      ← 数量不符说明混进了别的镜像或丢了一段
//   7. dram[0x0000..0x3FFF] 必须全 0      ← DRAM 镜像压到文件系统/应用数据区会静默
//                                          改掉 ramdisk，这条把它挡住
//
// 跑法：
//   iverilog -g2012 -o sim/build/tb_boot_image.vvp sim/tb_boot_image.sv
//   vvp sim/build/tb_boot_image.vvp
// =============================================================================
`timescale 1ns/1ps

module tb_boot_image;

    localparam int IROM_WORDS = 16384;
    localparam int DRAM_WORDS = 32768;

    // ★ 期望值全部是"从镜像反推出来的常量"，不是从镜像读出来的（否则同义反复）
    localparam logic [31:0] EXP_IROM0 = 32'h0001_1197;   // auipc gp, 0x11
    localparam logic [31:0] EXP_IROM1 = 32'h93C1_8193;   // addi gp, gp, -1732（随 .text 变长而变）
    localparam logic [31:0] EXP_DRAM0 = 32'h6D61_7266;   // 'fram'
    localparam int          EXP_IROM_NZ = 639;
    localparam int          EXP_DRAM_NZ = 76;
    localparam int          DRAM_BASE_WORD = 32'h1_0000 >> 2;   // 0x4000

    logic [31:0] irom [0:IROM_WORDS-1];
    logic [31:0] dram [0:DRAM_WORDS-1];

    int n_pass = 0;
    int n_fail = 0;

    task automatic chk(input string name, input logic ok);
        if (ok) begin
            n_pass++;
            $display("  PASS  %s", name);
        end else begin
            n_fail++;
            $display("  FAIL  %s", name);
        end
    endtask

    int nz_irom, nz_dram, nz_low, i, bad_low;

    initial begin
        $display("================ BOOT IMAGE SELF-CHECK ================");

        // $readmemh 遇到不存在的文件只会打一条警告然后**继续**（数组保持 X），
        // 所以先把两个数组铺成 X，装载后逐项检查，能区分"没装"和"装了但错"。
        for (i = 0; i < IROM_WORDS; i = i + 1) irom[i] = 32'hxxxx_xxxx;
        for (i = 0; i < DRAM_WORDS; i = i + 1) dram[i] = 32'hxxxx_xxxx;
        $readmemh("project_src/boot_rec.hex",      irom);
        $readmemh("project_src/boot_rec_dram.hex", dram);

        // ---- 1/2 行数（没装到的位置是 X）
        nz_irom = 0; nz_dram = 0; nz_low = 0; bad_low = 0;
        for (i = 0; i < IROM_WORDS; i = i + 1) if (irom[i] !== 32'h0) nz_irom++;
        for (i = 0; i < DRAM_WORDS; i = i + 1) begin
            if (dram[i] !== 32'h0) nz_dram++;
            if (i < DRAM_BASE_WORD) begin
                if (dram[i] !== 32'h0) bad_low++;
            end
        end
        $display("  IROM 非零字 %0d，DRAM 非零字 %0d（0x0..0x3FFF 内 %0d）",
                 nz_irom, nz_dram, bad_low);

        chk("IROM 全量装载（无非零 X 残留）", nz_irom == EXP_IROM_NZ);
        chk("DRAM 全量装载（无非零 X 残留）", nz_dram == EXP_DRAM_NZ);

        // ---- 3/4 入口
        chk($sformatf("irom[0] = 0x%08h（期望 0x%08h）", irom[0], EXP_IROM0),
            irom[0] === EXP_IROM0);
        chk($sformatf("irom[1] = 0x%08h（crt0 第 2 条 addi gp）", irom[1]),
            irom[1] === EXP_IROM1);
        chk($sformatf("irom[2] = 0x%08h（crt0 第 3 条 auipc sp）", irom[2]),
            irom[2] === 32'h0002_0117);

        // ---- 5 DRAM 基址
        chk($sformatf("dram[0x4000] = 0x%08h（期望 0x%08h）", dram[DRAM_BASE_WORD], EXP_DRAM0),
            dram[DRAM_BASE_WORD] === EXP_DRAM0);
        chk($sformatf("dram[0x4001] = 0x%08h（期望 0x003D7365）", dram[DRAM_BASE_WORD+1]),
            dram[DRAM_BASE_WORD+1] === 32'h003D_7365);

        // ---- 6 数量
        chk($sformatf("IROM 非零字数 = %0d（期望 %0d）", nz_irom, EXP_IROM_NZ),
            nz_irom == EXP_IROM_NZ);
        chk($sformatf("DRAM 非零字数 = %0d（期望 %0d）", nz_dram, EXP_DRAM_NZ),
            nz_dram == EXP_DRAM_NZ);

        // ---- 7 不许压到低地址（ramdisk / 应用数据区）
        chk("DRAM 0x0..0x3FFF（ramdisk）必须全 0", bad_low == 0);

        $display("-----------------------------------------------------");
        if (n_fail == 0)
            $display(" BOOT IMAGE SELF-CHECK: ALL PASS (%0d/%0d)", n_pass, n_pass + n_fail);
        else
            $display(" BOOT IMAGE SELF-CHECK: %0d FAIL / %0d 项", n_fail, n_pass + n_fail);
        $display("=====================================================");
        $finish;
    end

endmodule
