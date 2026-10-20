`timescale 1ns / 1ps

/* =============================================================================
 * sim/tb_board_top_uart.sv — v12（B）UART MMIO 端到端测试（板级）
 * -----------------------------------------------------------------------------
 * 前面两个测试台各管一段：
 *   tb_uart_tx.sv        —— 发送器本身对不对（回环）
 *   tb_sys (+kind=zicntr)—— CSR/计数器对不对
 * 这个测试台补最后一段、也是最容易出问题的一段：**CPU 真的能"打印"吗**。
 * 它把 board_top（带 MMIO 译码 + DCache + uart_tx）整块跑起来，用程序里的
 * `sw 0(x1), x2` 往 0x1000_0000 写，再把 uart_tx 的输出接一个 uart_rx 当"串口终端"。
 *
 * 判据（对应 sim/gen_uart_mmio_prog.py 的程序）：
 *   U1 串口先收到 'H'(0x48)，再收到 'i'(0x69) —— MMIO 写 + busy 轮询都通
 *   U2 x5 == 0xCAFE0000：MMIO 写**没有**顺带改掉 DRAM 第 0 个字
 *      （board_top 里 dram 的 wen 必须被 ~mmio_uart_sel 门掉；漏门是"打一个字，
 *       栈里的变量莫名变了"这种最恶心的一类 bug）
 *   U3 x8 == 0x1234：普通 DRAM 读写没被 MMIO 译码误伤
 *   U4 x10 == 0x600D：程序走到了尾（不是跑飞后碰巧通过）
 *
 * ★ 时钟用 50MHz（#10）：板上就是 50MHz（board_top_ila 的 MMCM 分频），
 *   BIT_TICKS(50MHz,115200) = 434，与真板完全一致。
 * ★ uart_rx 的 CLK_FREQ 必须与 board_top 里 uart_tx 的 CLK_FREQ 相同，
 *   否则收下来的每个字节都是错的（位宽对不上）。
 * ============================================================================= */
module tb_board_top_uart;

    logic clk = 1'b0;
    logic btn_rst_n = 1'b0;     // 按键：低有效，先按住
    always #10 clk = ~clk;      // 50MHz（与板上一致）

    // ------------------------------------------------------------ 板级观测口
    logic        dbg_have_inst, dbg_ena, dbg_trap_take, dbg_dnpc_flag, dbg_ready;
    logic [31:0] dbg_pc, dbg_value, dbg_ifu_pc;
    logic [ 4:0] dbg_reg;
    logic [31:0] ic_hit, ic_miss, dc_hit, dc_miss;
    logic [31:0] dbg_mcause, dbg_mepc, dbg_mtval;
    logic [31:0] dbg_status, dbg_mcycle;
    logic        boot_busy, boot_ok, boot_err;
    logic        uart_tx_line;

    reg [8*260-1:0] prog_path = "sim/uart_mmio.hex";

    board_top #(
        .IROM_WORDS (4096),
        .DRAM_WORDS (16384),
        .IROM_INIT  (""),         // 运行时 $readmemh（见下）
        .IROM_BOOT  (0)
    ) u_board (
        .sys_clk               (clk),
        .btn_rst_n             (btn_rst_n),

        .debug_wb_have_inst    (dbg_have_inst),
        .debug_wb_pc           (dbg_pc),
        .debug_wb_ena          (dbg_ena),
        .debug_wb_reg          (dbg_reg),
        .debug_wb_value        (dbg_value),

        .debug_icache_hit_cnt  (ic_hit),
        .debug_icache_miss_cnt (ic_miss),
        .debug_dcache_hit_cnt  (dc_hit),
        .debug_dcache_miss_cnt (dc_miss),

        .debug_mcause          (dbg_mcause),
        .debug_mepc            (dbg_mepc),
        .debug_mtval           (dbg_mtval),
        .debug_trap_take       (dbg_trap_take),

        .debug_dnpc_flag       (dbg_dnpc_flag),
        .debug_ready           (dbg_ready),
        .debug_ifu_pc          (dbg_ifu_pc),

        .debug_status          (dbg_status),
        .debug_mcycle          (dbg_mcycle),

        // IROM_BOOT=0 → 引导逻辑不综合，uart_rx 接固定电平即可
        .uart_rx               (1'b1),
        .uart_tx               (uart_tx_line),     // ★ 被测的串口发送线
        .debug_boot_busy       (boot_busy),
        .debug_boot_ok         (boot_ok),
        .debug_boot_err        (boot_err)
    );

    // ------------------------------------------------ 串口"终端"：接收并打印
    logic [7:0] rx_data;
    logic       rx_valid;
    integer     rx_cnt = 0;
    logic [7:0] rx_bytes [0:7];

    uart_rx #(
        .CLK_FREQ (50_000_000),
        .BAUD     (115_200)
    ) u_term (
        .clk   (clk),
        .rst   (~btn_rst_n),
        .rx    (uart_tx_line),
        .data  (rx_data),
        .valid (rx_valid)
    );

    integer cyc = 0;
    always @(posedge clk) cyc <= cyc + 1;

    always @(posedge clk) begin
        if (btn_rst_n && rx_valid) begin
            if (rx_cnt < 8) rx_bytes[rx_cnt] = rx_data;
            rx_cnt = rx_cnt + 1;
            $display("[UART] cyc=%0d byte='%c' (0x%02x)  count=%0d",
                     cyc, rx_data, rx_data, rx_cnt);
        end
    end

    // ------------------------------------------------------------------ 判据
    integer npass = 0, nfail = 0;
    task chk(input [8*70-1:0] name, input cond);
        begin
            if (cond) begin
                npass = npass + 1;
                $display("  [PASS] %0s", name);
            end else begin
                nfail = nfail + 1;
                $display("  [FAIL] %0s", name);
            end
        end
    endtask

    logic done = 1'b0;
    integer k;
    integer guard;
    // 无标记程序（比如 sim/uart_hello.hex 是**无限循环**打印）不会有 x10=0x600D，
    // 所以允许用 +maxticks=N 把观察窗口拉长，用来验证"周期性重复打印"。
    //   默认 200000 拍（4ms）—— 足够跑完 uart_mmio.hex。
    //   验证 hello 时用 +maxticks=2600000（52ms，覆盖 2~3 轮 14ms 的延时）。
    integer max_ticks = 200000;

    initial begin
        for (k = 0; k < 16384; k = k + 1) u_board.dram_inst.mem_ram[k] = 32'h0;
        // ★ 预置 DRAM[0] 为一个可识别的值：MMIO 写之后它必须原样不变（U2）
        u_board.dram_inst.mem_ram[0] = 32'hCAFE_0000;

        if ($value$plusargs("prog=%s", prog_path)) ;
        if ($value$plusargs("maxticks=%d", max_ticks)) ;
        $display("================================================================");
        $display(" tb_board_top_uart : program=%0s  maxticks=%0d", prog_path, max_ticks);
        $display("   UART MMIO: TXDATA=0x1000_0000  STATUS=0x1000_0004 (bit0=busy)");
        $display("================================================================");
        // ★ IROM_BOOT=0 时 irom_inst 在 generate 的 g_irom_rom 作用域里，
        //   层次路径必须带上 generate 块名（漏了会报 "Unable to bind ... mem_rom"）。
        $readmemh(prog_path, u_board.g_irom_rom.irom_inst.mem);

        btn_rst_n = 1'b0;
        repeat (8) @(posedge clk);
        @(negedge clk);
        #1 btn_rst_n = 1'b1;
    end

    // 等 x10 写回 0x600D（程序走到尾），然后再等最多 2 帧让第二个字节收完
    always @(negedge clk) begin
        if (btn_rst_n && !done) begin
            if (dbg_have_inst && dbg_ena && dbg_reg == 5'd10 && dbg_value == 32'h600D) begin
                done = 1'b1;
                $display("[END] marker x10=0x600D at cyc=%0d", cyc);
                // 最多等 2 帧（2*10*434 = 8680 拍）让 'i' 收完
                guard = 0;
                while (rx_cnt < 2 && guard < 2*10*434) begin
                    @(posedge clk);
                    guard = guard + 1;
                end
                report();
            end
        end
        if (btn_rst_n && !done && cyc > max_ticks) begin
            done = 1'b1;
            $display("[BOARD-UART] status=TIMEOUT (no marker x10=0x600D in %0d cycles)", cyc);
            nfail = nfail + 1;
            report();
        end
    end

    task report();
        begin
            $display("");
            $display("------------ board_top + UART MMIO ------------");
            $display("  received bytes = %0d", rx_cnt);
            $display("  x5 (DRAM[0]) = %h   x8 (DRAM[0x40]) = %h",
                     u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5],
                     u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[8]);
            $display("  total cycles = %0d   dcache hit/miss = %0d/%0d", cyc, dc_hit, dc_miss);

            chk("received 'H' (0x48) first",       rx_cnt >= 1 && rx_bytes[0] == 8'h48);
            chk("received 'i' (0x69) second",      rx_cnt >= 2 && rx_bytes[1] == 8'h69);
            chk("no extra bytes printed",          rx_cnt == 2);
            chk("DRAM[0] untouched by MMIO write",
                u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[5] == 32'hCAFE_0000);
            chk("plain DRAM read/write still works",
                u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[8] == 32'h1234);
            chk("program reached its end (x10=0x600D)",
                u_board.u_cpu.IDU_Inst0.Reg_Stack_inst0.Reg_inst.rf[10] == 32'h600D);

            $display("--------------------------------------------------");
            if (nfail == 0)
                $display("[BOARD-UART-SELFCHECK] status=PASS (%0d checks)", npass);
            else
                $display("[BOARD-UART-SELFCHECK] status=FAIL (%0d failed, %0d passed)", nfail, npass);
            $display("==================================================");
            $finish;
        end
    endtask

endmodule
