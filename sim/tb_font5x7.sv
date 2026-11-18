`timescale 1ns / 1ps

/* =============================================================================
 * tb_font5x7.sv — 字模 ROM 自检
 * -----------------------------------------------------------------------------
 * 判据分两层：
 *   1) **逐点阵断言**：几个关键位置的行值必须等于手算值；
 *   2) **整体打印**：把 ROM 内容按字符块打印成 ASCII 图，肉眼能直接看出形状对不对。
 *      （字模是图形数据，只靠几个采样点不足以保证"看起来是对的"。）
 * ============================================================================= */
module tb_font5x7;

    logic [4:0] ch;
    logic [2:0] row;
    logic [4:0] bits;

    font5x7 dut (.ch(ch), .row(row), .bits(bits));

    int errors = 0;
    int nchk   = 0;
    task automatic chk(input string nm, input int got, input int exp);
        if (got == exp) $display("[PASS] %-28s = %0d", nm, got);
        else begin $display("[FAIL] %-28s = %0d (期望 %0d)", nm, got, exp); errors++; end
    endtask

    task automatic expect_row(input int c, input int r, input logic [4:0] exp);
        nchk++;
        ch = c[4:0]; row = r[2:0]; #1;
        if (bits !== exp) begin
            $display("[FAIL] ch=%0d row=%0d = %05b (期望 %05b)", c, r, bits, exp);
            errors++;
        end
    endtask

    /* 把 25 个字符打印成 ASCII 图 */
    task automatic dump_all();
        for (int c = 0; c < 25; c++) begin
            $display("---- 索引 %0d ----", c);
            for (int r = 0; r < 7; r++) begin
                ch = c[4:0]; row = r[2:0]; #1;
                $write("  |");
                for (int i = 4; i >= 0; i--)
                    $write("%s", bits[i] ? "#" : ".");
                $write("|\n");
            end
        end
    endtask

    initial begin
        /* ---- 关键点阵断言（索引见 font5x7.sv 末尾的索引表）---- */
        /* 0 = 空格：全 0 */
        expect_row(0, 0, 5'b00000);
        expect_row(0, 3, 5'b00000);
        expect_row(0, 6, 5'b00000);

        /* 1 = '0'：第 0 行 .###. */
        expect_row(1, 0, 5'b01110);
        /* 1 = '0'：第 6 行 .###. */
        expect_row(1, 6, 5'b01110);

        /* 9 = '8'：第 3 行 .###.（中间那一横）*/
        expect_row(9, 3, 5'b01110);

        /* 14 = 'V'：第 6 行 ..#.. */
        expect_row(14, 6, 5'b00100);

        /* 19 = 'A'：第 3 行 ##### */
        expect_row(19, 3, 5'b11111);

        /* 25 号起越界：必须输出 0，不能出 X */
        nchk++;
        ch = 5'd25; row = 3'd0; #1;
        chk("越界索引输出 0", bits, 0);

        if (errors == 0) begin
            $display("---- 全字符 ASCII 图 ----");
            dump_all();
            $display("[SELFCHECK] status=PASS  共 %0d 项检查", nchk);
        end else begin
            $display("[SELFCHECK] status=FAIL errors=%0d", errors);
        end
        $finish;
    end

endmodule
