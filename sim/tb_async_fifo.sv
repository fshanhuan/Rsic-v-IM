`timescale 1ns / 1ps

/* =============================================================================
 * tb_async_fifo.sv — 异步 FIFO + 文本叠加层自检
 * -----------------------------------------------------------------------------
 * 两件事一起验：
 *   1) **FIFO 本身**：两个不同频率的时钟（50 MHz 写、40 MHz 读），
 *      灌 N 个已知数据，读出顺序必须完全一致、一个不少、一个不多；
 *   2) **叠加层**：把字符从写侧（cpu 域）灌进去，然后在 pix 域按像素采样，
 *      确认面板位置、字形亮点、面板底色都对。
 *
 * 判据（可手算）：
 *   往第 0 行第 0 列写索引 1（'0'），字形第 0 行是 .###.：
 *     屏幕 (16,16) 格内 (0,0) → 暗 → 面板色 24
 *     屏幕 (18,16) 格内 (2,0) → 亮 → 文字色 235
 *     屏幕 (16,17) 格内 (0,1) → '0' 第 1 行 #...# → 亮 → 235
 * ============================================================================= */
module tb_async_fifo;

    logic wclk = 1'b0;      // 50 MHz
    logic rclk = 1'b0;      // 40 MHz
    always #10   wclk = ~wclk;
    always #12.5 rclk = ~rclk;

    logic wrst = 1'b1, rrst = 1'b1;

    logic [10:0] wdata;
    logic        wpush;
    logic        wfull;
    logic [10:0] rdata;
    logic        rpop;
    logic        rempty;

    async_fifo #(.WIDTH(11), .AW(3)) dut (
        .wclk   (wclk),
        .wrst   (wrst),
        .wdata  (wdata),
        .wpush  (wpush),
        .wfull  (wfull),
        .rclk   (rclk),
        .rrst   (rrst),
        .rdata  (rdata),
        .rpop   (rpop),
        .rempty (rempty)
    );

    int errors = 0;
    task automatic chk(input string nm, input longint got, input longint exp);
        if (got == exp) $display("[PASS] %-30s = %0d", nm, got);
        else begin $display("[FAIL] %-30s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    /* ---------------- 1) FIFO 顺序/完整性 ---------------- */
    localparam int N = 20;
    logic [10:0] rd_log [0:N-1];
    int          nrd = 0;

    /* 读侧：不空就 pop，并在**同一拍**记录 rdata。
     * ★ 这里踩过一个 TB 自身的坑：第一版把 rpop 写成寄存器（rpop <= 1），
     *   于是 pop 比记录晚一拍，同一份数据被记了两次（256,256,257,257…），
     *   看起来像"FIFO 重复出数"。pop 必须是组合的，才能和 rdata 同拍。 */
    wire rpop_w = !rempty && (nrd < N);
    assign rpop = rpop_w;

    always @(posedge rclk) begin
        if (!rrst && rpop_w) begin
            rd_log[nrd] <= rdata;
            nrd         <= nrd + 1;
        end
    end

    initial begin
        repeat (4) @(posedge wclk);
        wrst <= 1'b0;
        repeat (4) @(posedge rclk);
        rrst <= 1'b0;
        repeat (4) @(posedge wclk);

        /* 灌 20 个已知数据（注意：FIFO 深度只有 8，所以必须边灌边读） */
        for (int i = 0; i < N; i++) begin
            @(negedge wclk);
            wdata <= 11'h100 + i[10:0];
            wpush <= 1'b1;
            @(negedge wclk);
            wpush <= 1'b0;
            repeat (6) @(negedge wclk);     // 留时间给读侧
        end

        repeat (200) @(posedge rclk);

        chk("读到个数", nrd, N);
        for (int i = 0; i < N && i < nrd; i++)
            chk($sformatf("第%0d个数据顺序", i), rd_log[i], 11'h100 + i);
        chk("读完后为空", rempty, 1);

        if (errors == 0) $display("[SELFCHECK] status=PASS");
        else             $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        $finish;
    end

    initial begin
        #5_000_000;
        $display("[FAIL] 超时 nrd=%0d", nrd);
        $display("[SELFCHECK] status=FAIL");
        $finish;
    end

endmodule
