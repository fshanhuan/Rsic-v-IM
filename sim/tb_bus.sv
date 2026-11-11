`timescale 1ns / 1ps

/* =============================================================================
 * tb_bus.sv — A1 总线化的板级冒烟测试（不需要 C 工具链）
 * -----------------------------------------------------------------------------
 * 载入 sim/bus_smoke.hex（由 sim/gen_bus_smoke.py 生成），检查四件事：
 *
 *   ① DRAM 写/读        → u_board.g_dram_single.dram_inst.mem_ram[0x4000] == 0xCAFE_0123
 *   ② 代码窗口读指令字   → 程序自己比较（读不到就跳 fail）
 *   ③ 代码窗口写         → u_board.irom_inst.mem[0x100] == 0xBEEF_0456
 *   ④ MMIO              → led == 7'h2A、UART 收到 "OK"
 *
 * ★ 为什么第 ② 条必须由程序自己比：读 mux 的回选是**纯译码**（hit_*），
 *   数据在请求的下一拍才有效 —— 如果用 sel_*（含 ren）门控，读回会变成 0。
 *   这个错误只有"真的读一次再比"才能抓出来。
 * ★ 为什么第 ③ 条直接查 BRAM 数组：DCache 是写直达，写回后缓存里也有这份数据，
 *   用 `lw` 读回来会命中缓存，**测不出总线写通路**。直接看数组才是真判据。
 * ★ 层次路径：sync_mem 的数组在**模块作用域**（mem_rom / mem_ram）；sync_mem_dp
 *   （IROM）的数组叫 `mem`，实例 irom_inst 已提到 generate 外（双核协同时改的）。
 *
 * 判据输出：[BUS-SMOKE] PASS / FAIL（regress 脚本靠这行判断）
 * ============================================================================= */
module tb_bus;

    /* ------------------------------ 时钟/复位 ------------------------------ */
    logic clk = 1'b0;
    logic rst_n = 1'b0;
    always #10 clk = ~clk;              // 20 ns 周期 = 50 MHz

    initial begin
        rst_n = 1'b0;
        #200;
        rst_n = 1'b1;
    end

    /* ------------------------------ DUT ----------------------------------- */
    logic       uart_tx;
    logic [6:0] led;

    board_top #(
        .IROM_INIT ("sim/bus_smoke.hex")
    ) u_board (
        .sys_clk   (clk),
        .btn_rst_n (rst_n),
        .uart_rx   (1'b1),              // 本测试不需要串口输
    .uart_tx   (uart_tx),
        .led       (led)
    );

    /* --------------------------- UART 接收模型 -----------------------------
     * 115200 @ 50 MHz 434.03 位。起始位下降沿同步，半位后开始采样     * ------------------------------------------------------------------- */
    localparam integer BIT = 434;

    integer  st = 0;
    integer  cnt = 0;
    integer  nbit = 0;
    logic [7:0] sh = 8'h00;
    logic [7:0] rx_byte = 8'h00;
    logic       rx_valid = 1'b0;

    always @(posedge clk) begin
        rx_valid <= 1'b0;
        if (!rst_n) begin
            st <= 0; cnt <= 0; nbit <= 0;
        end else begin
            case (st)
                0: if (!uart_tx) begin st <= 1; cnt <= 0; nbit <= 0; end
                1: if (cnt == (BIT / 2 - 1)) begin st <= 2; cnt <= 0; end
                   else                       cnt <= cnt + 1;
                2: if (cnt == (BIT - 1)) begin
                       cnt <= 0;
                       sh[nbit] <= uart_tx;
                       if (nbit == 7) st <= 3;
                       else           nbit <= nbit + 1;
                   end else cnt <= cnt + 1;
                3: begin
                       rx_byte  <= sh;
                       rx_valid <= 1'b1;
                       st <= 4;                 // 先等停止位，再重新武
    cnt <= 0;
                   end
                // 停止位等待：采样bit7 时线还停在数据位上，如果直接st=0
    //   会把这个"残留的数据位"当成下一帧的起始位，解出 0xFF / 0x2D 这类
                //   假字节（实测踩过）。这里要求线连续高半个位才认为可以重新找起始位
    4: begin
                       if (!uart_tx)      cnt <= 0;
                       else if (cnt == (BIT / 2)) begin st <= 0; cnt <= 0; end
                       else               cnt <= cnt + 1;
                   end
                default: st <= 0;
            endcase
        end
    end

    /* ------------------------------ 收字-------------------------------- */
    logic [7:0] got [0:7];
    integer nrecv = 0;

    always @(posedge clk) begin
        if (rx_valid && nrecv < 8) begin
            got[nrecv] <= rx_byte;
            nrecv      <= nrecv + 1;
            $display("[BUS-SMOKE] uart byte %0d = 0x%02x", nrecv, rx_byte);
        end
    end

    /* ------------------------------ 拍计-------------------------------- */
    integer cycles = 0;
    always @(posedge clk) cycles <= cycles + 1;

    /* --------------------------- 调试：总线事件 ---------------------------- */
    logic        we_dram_d = 1'b0;
    logic        re_code_d = 1'b0;
    logic [14:0] wa_d = 15'd0;
    logic [15:0] ca_d = 16'd0;

    always @(posedge clk) begin
        we_dram_d <= u_board.bus_we_dram;
        re_code_d <= u_board.bus_re_code;
        wa_d      <= u_board.perip_addr[16:2];
        ca_d      <= u_board.perip_addr[17:2];
    end

    always @(posedge clk) begin
        if (rst_n && u_board.bus_we_dram)
            $display("[DBG] we_dram t=%0t addr=%h wd=%h mask=%b", $time,
                     u_board.perip_addr, u_board.perip_wdata, u_board.perip_mask);
        if (rst_n && u_board.bus_we_code)
            $display("[DBG] we_code t=%0t addr=%h wd=%h", $time,
                     u_board.perip_addr, u_board.perip_wdata);
        if (rst_n && u_board.bus_we_mmio)
            $display("[DBG] we_mmio t=%0t addr=%h wd=%h", $time,
                     u_board.perip_addr, u_board.perip_wdata);
        if (we_dram_d)
            $display("[DBG] after-write g_dram_single.dram_inst.mem_ram[%0h]=%h", wa_d,
                     u_board.g_dram_single.dram_inst.mem_ram[wa_d]);
        if (re_code_d)
            $display("[DBG] after-read  perip_rdata=%h (code word %0h)",
                     u_board.perip_rdata, ca_d);
        // 20 万拍打一PC，用来区循环次数对但每圈很慢" vs "循环跑爆
        if ((cycles % 200_000) == 0 && cycles != 0)
            $display("[DBG] t=%0t pc=%h", $time, u_board.debug_wb_pc);
    end

    /* ------------------------------ 判据 ---------------------------------- */
    integer nfail = 0;
    integer npass = 0;
    logic [31:0] dram_w, imem_w;

    task automatic chk(input bit cond, input string name);
        begin
            if (cond) begin npass = npass + 1; $display("[BUS-SMOKE]   [PASS] %0s", name); end
            else      begin nfail = nfail + 1; $display("[BUS-SMOKE]   [FAIL] %0s", name); end
        end
    endtask

    initial begin
        // 等程序跑完：收到 2 个字符，或最6 ms（远大于 2 个字符的 174 us
    wait ((nrecv >= 2) || (cycles > 300_000));
        #2000;                          // 让最后一个写落地

        dram_w = u_board.g_dram_single.dram_inst.mem_ram[32'h4000];           // 0x1_0000 / 4
        imem_w = u_board.irom_inst.mem[32'h100];     // 0x400 / 4

        $display("[BUS-SMOKE] led=0x%02x  dram[0x1000]=0x%08x  imem[0x100]=0x%08x  nrecv=%0d",
                 led, dram_w, imem_w, nrecv);
        $display("[BUS-SMOKE] cycles=%0d  mcycle=%0d  t=%0t  pc=%h",
                 cycles, u_board.debug_mcycle, $time, u_board.debug_wb_pc);

        chk(led == 7'h2A,                                          "LED write via we_mmio (0x2A)");
        chk(dram_w == 32'hCAFE_0123,                               "DRAM write+read via bus (0xCAFE_0123)");
        chk(imem_w == 32'hBEEF_0456,                               "code-window write via we_code (0xBEEF_0456)");
        chk((nrecv == 2) && (got[0] == 8'h4F) && (got[1] == 8'h4B), "UART TXDATA writes -> OK");

        if (nfail == 0) $display("[BUS-SMOKE] PASS  (%0d/%0d)", npass, npass + nfail);
        else            $display("[BUS-SMOKE] FAIL  (%0d failed, %0d passed)", nfail, npass);
        // _diag/regress.ps1 Run-Vvp 用的标准判据标签
        $display("[BUS-SMOKE-SELFCHECK] status=%s", (nfail == 0) ? "PASS" : "FAIL");
        $finish;
    end

endmodule
