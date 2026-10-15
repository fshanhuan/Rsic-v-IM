`timescale 1ns / 1ps

/* =============================================================================
 * tb_dcache_unit.sv — DCache 模块级单元测试（上板改造新增）
 * -----------------------------------------------------------------------------
 * 为什么单独写：
 *   sim/tb_iverilog.sv 是整机回归（好护栏，但 D-Cache 的边界行为在里面很难
 *   被逼出来）。本测试台把 DCache 单独拎出来打，覆盖上板改造的三个关键点：
 *
 *   ① 同步读回填正确性：同步 DRAM 固定 1 拍延迟，回填必须写对行。
 *      这条曾经错过 —— 回填写进去的是“下一个 index 的字”，于是 load 读到的
 *      刚好是落在下一个 index 的地址上的值。
 *   ② uncacheable（MMIO）保护：不可缓存地址永远直通外设、绝不进缓存，
 *      否则“读有副作用”的外设寄存器行为不可预测。
 *
 * 关于 write-once（一次 store 只发一个 mem_wen 脉冲）：
 *   它需要真实的 LSU pipe 级时序才有意义，模块级测试台直接驱动
 *   cpu_en/cpu_wen 时观测点容易与脉冲错拍，因此该断言放在整机回归
 *   sim/tb_iverilog.sv 里（那里的 write-once 检查已 PASS）。
 *
 * 用法（在 v9/ 目录下）：
 *   iverilog -g2012 -o sim/build/tb_dcache_unit.vvp DCache.sv sim/tb_dcache_unit.sv
 *   vvp sim/build/tb_dcache_unit.vvp
 *   期望输出最后一行：DCACHE-UNIT: PASS
 * =========================================================================== */
module tb_dcache_unit;

    logic clk = 0, reset = 1;
    always #5 clk = ~clk;              // 100MHz

    logic        cpu_en, cpu_wen;
    logic [31:0] cpu_addr, cpu_wdata, mem_rdata;
    logic [ 1:0] cpu_mask;
    logic [31:0] cpu_rdata, mem_addr, mem_wdata;
    logic        mem_en, mem_wen, hit, miss, hold;
    logic [ 1:0] mem_mask;
    logic [31:0] hit_cnt, miss_cnt;

    DCache #(.INDEX_BITS(6), .TAG_BITS(24)) dut (
        .clk(clk), .reset(reset),
        .cpu_en(cpu_en), .cpu_wen(cpu_wen),
        .cpu_addr(cpu_addr), .cpu_wdata(cpu_wdata), .cpu_mask(cpu_mask),
        .mem_rdata(mem_rdata), .cpu_rdata(cpu_rdata), .mem_addr(mem_addr),
        .mem_en(mem_en), .mem_wen(mem_wen), .mem_wdata(mem_wdata),
        .mem_mask(mem_mask), .hit(hit), .miss(miss), .hold(hold),
        .hit_cnt(hit_cnt), .miss_cnt(miss_cnt)
    );

    /* ---- 同步 DRAM 模型（1 拍读延迟，与 board/sync_mem.sv 同语义） ----
       只响应可缓存区间（< 0x1000_0000）；>= 0x1000_0000 交给外设模型，
       否则两个 always_ff 会同时驱动 mem_rdata，后写的那个总是赢。 ---- */
    logic [31:0] dram [0:255];
    wire  [ 7:0] wa = mem_addr[9:2];
    wire         is_mmio = (mem_addr[31:28] == 4'h1);
    always_ff @(posedge clk) begin
        if (mem_en && !is_mmio) mem_rdata <= dram[wa];
        if (mem_wen)            dram[wa] <= mem_wdata;
    end

    /* ---- 外设模型：读有副作用（每次读返回递增值）---- */
    logic [31:0] periph_val = 32'h0;
    integer      periph_rd = 0;
    always_ff @(posedge clk) begin
        if (mem_en && is_mmio) begin
            periph_rd  <= periph_rd + 1;
            mem_rdata  <= periph_val + 32'h1;
            periph_val <= periph_val + 32'h1;
        end
    end

    /* ---- write 观测：确认写直达确实落到存储器 ---- */
    logic [31:0] last_wr_addr  = 32'h0;
    logic [31:0] last_wr_data  = 32'h0;
    logic        got_wr        = 1'b0;
    always_ff @(posedge clk) if (mem_wen) begin
        last_wr_addr <= mem_addr;
        last_wr_data <= mem_wdata;
        got_wr       <= 1'b1;
    end

    integer nfail = 0;
    integer n;
    logic [31:0] v1, v2;

    task chk(input [8*40-1:0] nm, input [31:0] got, input [31:0] exp);
        begin
            if (got === exp) $display("  [PASS] %0s = %h", nm, got);
            else begin nfail = nfail + 1; $display("  [FAIL] %0s = %h (exp %h)", nm, got, exp); end
        end
    endtask

    // 等一次访问完成：DCache 报出 access_en（含命中）即可，再多给几拍让回填落地
    task wait_access;
        begin
            n = 0;
            while (n < 20) begin
                @(negedge clk);
                if (dut.access_en || hit) n = 20;
                else n = n + 1;
            end
            repeat (4) @(negedge clk);
        end
    endtask

    initial begin
        for (int i = 0; i < 256; i = i + 1) dram[i] = 32'h0;
        dram[4] = 32'hDEAD_BEEF;         // 地址 0x10
        cpu_en = 0; cpu_wen = 0; cpu_addr = 0; cpu_wdata = 0;
        cpu_mask = 2'b10; mem_rdata = 32'h0;
        repeat (3) @(posedge clk); reset = 0;
        repeat (2) @(posedge clk);

        /* === ① 同步读回填正确性 === */
        cpu_en = 1; cpu_wen = 0; cpu_addr = 32'h10; cpu_mask = 2'b10;
        wait_access;
        chk("LOAD 0x10 (miss->fill)", cpu_rdata, 32'hDEAD_BEEF);
        cpu_en = 0; repeat (3) @(posedge clk);

        /* === ② 写直达 + 缓存行一致性 ===
           v9 修复：这里必须在**时钟沿后 1ns** 驱动 cpu_en/cpu_wen。
             原来在沿上直接阻塞赋值，而 DUT 里 `store_fire` 是连续赋值、
             `store_req_r <= store_fire` 在 always_ff 内：同一时间步里两个进程的
             求值顺序不确定 —— 实测状态机推进了、写脉冲却读到旧值，导致这条
             单元测试**一次 store 都没有真正发出去**（wr_seen=0），后面那条
             "store 后读回"的观测自然也是 0。改成沿后 1ns 驱动后脉冲正常，
             于是这里可以升级成真正的判据（原来只打印观测值）。 */
        @(posedge clk); #1;
        cpu_en = 1; cpu_wen = 1; cpu_addr = 32'h20; cpu_wdata = 32'hCAFE_1234; cpu_mask = 2'b10;
        repeat (6) @(posedge clk);
        @(posedge clk); #1;
        cpu_en = 0; cpu_wen = 0; repeat (3) @(posedge clk);
        $display("  store observation: last_wr addr=%h data=%h wr_seen=%b dram[8]=%h",
                 last_wr_addr, last_wr_data, got_wr, dram[8]);
        chk("WRITE 0x20 write-through (dram word)", dram[8], 32'hCAFE_1234);

        /* 写直达之后重新读该地址：必须拿到存储器里的值（不能残留旧缓存行） */
        @(posedge clk); #1;
        cpu_en = 1; cpu_wen = 0; cpu_addr = 32'h20; cpu_mask = 2'b10;
        wait_access;
        $display("  LOAD 0x20 (after store) observation = %h (dram[8]=%h)", cpu_rdata, dram[8]);
        chk("LOAD 0x20 after store", cpu_rdata, 32'hCAFE_1234);
        cpu_en = 0; repeat (3) @(posedge clk);

        /* 再次读 0x10：应当命中缓存 */
        cpu_en = 1; cpu_wen = 0; cpu_addr = 32'h10; cpu_mask = 2'b10;
        wait_access;
        chk("LOAD 0x10 (2nd, hit)", cpu_rdata, 32'hDEAD_BEEF);
        cpu_en = 0; repeat (3) @(posedge clk);

        /* === ③ uncacheable (MMIO) 保护 === */
        cpu_en = 1; cpu_wen = 0; cpu_addr = 32'h1000_0000; cpu_mask = 2'b10;
        wait_access; v1 = cpu_rdata;
        cpu_en = 0; repeat (3) @(posedge clk);
        cpu_en = 1; cpu_wen = 0; cpu_addr = 32'h1000_0000; cpu_mask = 2'b10;
        wait_access; v2 = cpu_rdata;
        cpu_en = 0; repeat (3) @(posedge clk);

        $display("  MMIO read#1 = %h  read#2 = %h  peripheral reads = %0d", v1, v2, periph_rd);
        if (periph_rd < 2) begin
            nfail = nfail + 1;
            $display("  [FAIL] MMIO read served from cache");
        end else begin
            $display("  [PASS] MMIO read always reaches peripheral (never cached)");
        end
        if (v1 === v2) begin
            nfail = nfail + 1;
            $display("  [FAIL] side-effecting read was cached (identical values)");
        end else begin
            $display("  [PASS] side effect observed (values differ: %h vs %h)", v1, v2);
        end

        $display("");
        // v9 修复：原来这里是 `$display(nfail == 0 ? "DCACHE-UNIT: PASS" : "DCACHE-UNIT: FAIL");`
        //   —— 没有格式符，字符串字面量被当成 136 位整数打印（日志里那串
        //   23228598090284490058663670033758753477459 就是 "DCACHE-UNIT: PASS"），
        //   而且全文没有 $fatal：run_all.sh 按 vvp 退出码判定，正常结束恒为 0，
        //   于是这一项**永远不可能失败**（把期望值改坏也照样算 PASS）。
        //   现在明确打印并让失败真正把回归打红。
        if (nfail == 0) begin
            $display("DCACHE-UNIT: PASS");
        end else begin
            $display("DCACHE-UNIT: FAIL (%0d checks failed)", nfail);
            $fatal(1, "DCACHE-UNIT: FAIL");
        end
        $finish;
    end

endmodule
