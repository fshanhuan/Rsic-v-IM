`timescale 1ns / 1ps

/* =============================================================================
 * font5x7.sv — 5x7 点阵字模 ROM（**由 tools/gen_font5x7.py 自动生成，请勿手改**）
 * -----------------------------------------------------------------------------
 * 字符集（共 25 个）:  0123456789.-:VPMINAXEFSC
 * 接口：ch 是字符索引（不是 ASCII），row 是行号 0..6，输出 5 位行点阵（bit4 = 最左）
 *
 * 为什么用索引而不是 ASCII：索引 5 位就够，ROM 只有 25 项；
 * 软件侧只写索引，映射表见本文件末尾的注释。
 * ============================================================================= */
module font5x7 (
    input  logic [4:0] ch,      // 字符索引 0..24
    input  logic [2:0] row,     // 行号 0..6
    output logic [4:0] bits     // 5 位行点阵，bit4 = 最左
);

    function automatic logic [4:0] frow(input logic [4:0] c, input logic [2:0] r);
        case (c)
            5'd00: case (r) 3'd0: frow = 5'b00000; 3'd1: frow = 5'b00000; 3'd2: frow = 5'b00000; 3'd3: frow = 5'b00000; 3'd4: frow = 5'b00000; 3'd5: frow = 5'b00000; 3'd6: frow = 5'b00000; default: frow = 5'b00000; endcase   // ' '
            5'd01: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10011; 3'd3: frow = 5'b10101; 3'd4: frow = 5'b11001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // '0'
            5'd02: case (r) 3'd0: frow = 5'b00100; 3'd1: frow = 5'b01100; 3'd2: frow = 5'b00100; 3'd3: frow = 5'b00100; 3'd4: frow = 5'b00100; 3'd5: frow = 5'b00100; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // '1'
            5'd03: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b00001; 3'd3: frow = 5'b00010; 3'd4: frow = 5'b00100; 3'd5: frow = 5'b01000; 3'd6: frow = 5'b11111; default: frow = 5'b00000; endcase   // '2'
            5'd04: case (r) 3'd0: frow = 5'b11110; 3'd1: frow = 5'b00001; 3'd2: frow = 5'b00001; 3'd3: frow = 5'b01110; 3'd4: frow = 5'b00001; 3'd5: frow = 5'b00001; 3'd6: frow = 5'b11110; default: frow = 5'b00000; endcase   // '3'
            5'd05: case (r) 3'd0: frow = 5'b00010; 3'd1: frow = 5'b00110; 3'd2: frow = 5'b01010; 3'd3: frow = 5'b10010; 3'd4: frow = 5'b11111; 3'd5: frow = 5'b00010; 3'd6: frow = 5'b00010; default: frow = 5'b00000; endcase   // '4'
            5'd06: case (r) 3'd0: frow = 5'b11111; 3'd1: frow = 5'b10000; 3'd2: frow = 5'b11110; 3'd3: frow = 5'b00001; 3'd4: frow = 5'b00001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // '5'
            5'd07: case (r) 3'd0: frow = 5'b00110; 3'd1: frow = 5'b01000; 3'd2: frow = 5'b10000; 3'd3: frow = 5'b11110; 3'd4: frow = 5'b10001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // '6'
            5'd08: case (r) 3'd0: frow = 5'b11111; 3'd1: frow = 5'b00001; 3'd2: frow = 5'b00010; 3'd3: frow = 5'b00100; 3'd4: frow = 5'b01000; 3'd5: frow = 5'b01000; 3'd6: frow = 5'b01000; default: frow = 5'b00000; endcase   // '7'
            5'd09: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10001; 3'd3: frow = 5'b01110; 3'd4: frow = 5'b10001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // '8'
            5'd10: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10001; 3'd3: frow = 5'b01111; 3'd4: frow = 5'b00001; 3'd5: frow = 5'b00010; 3'd6: frow = 5'b01100; default: frow = 5'b00000; endcase   // '9'
            5'd11: case (r) 3'd0: frow = 5'b00000; 3'd1: frow = 5'b00000; 3'd2: frow = 5'b00000; 3'd3: frow = 5'b00000; 3'd4: frow = 5'b00000; 3'd5: frow = 5'b01100; 3'd6: frow = 5'b01100; default: frow = 5'b00000; endcase   // '.'
            5'd12: case (r) 3'd0: frow = 5'b00000; 3'd1: frow = 5'b00000; 3'd2: frow = 5'b00000; 3'd3: frow = 5'b11111; 3'd4: frow = 5'b00000; 3'd5: frow = 5'b00000; 3'd6: frow = 5'b00000; default: frow = 5'b00000; endcase   // '-'
            5'd13: case (r) 3'd0: frow = 5'b00000; 3'd1: frow = 5'b01100; 3'd2: frow = 5'b01100; 3'd3: frow = 5'b00000; 3'd4: frow = 5'b01100; 3'd5: frow = 5'b01100; 3'd6: frow = 5'b00000; default: frow = 5'b00000; endcase   // ':'
            5'd14: case (r) 3'd0: frow = 5'b10001; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10001; 3'd3: frow = 5'b10001; 3'd4: frow = 5'b10001; 3'd5: frow = 5'b01010; 3'd6: frow = 5'b00100; default: frow = 5'b00000; endcase   // 'V'
            5'd15: case (r) 3'd0: frow = 5'b11110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10001; 3'd3: frow = 5'b11110; 3'd4: frow = 5'b10000; 3'd5: frow = 5'b10000; 3'd6: frow = 5'b10000; default: frow = 5'b00000; endcase   // 'P'
            5'd16: case (r) 3'd0: frow = 5'b10001; 3'd1: frow = 5'b11011; 3'd2: frow = 5'b10101; 3'd3: frow = 5'b10101; 3'd4: frow = 5'b10001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b10001; default: frow = 5'b00000; endcase   // 'M'
            5'd17: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b00100; 3'd2: frow = 5'b00100; 3'd3: frow = 5'b00100; 3'd4: frow = 5'b00100; 3'd5: frow = 5'b00100; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // 'I'
            5'd18: case (r) 3'd0: frow = 5'b10001; 3'd1: frow = 5'b11001; 3'd2: frow = 5'b10101; 3'd3: frow = 5'b10011; 3'd4: frow = 5'b10001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b10001; default: frow = 5'b00000; endcase   // 'N'
            5'd19: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10001; 3'd3: frow = 5'b11111; 3'd4: frow = 5'b10001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b10001; default: frow = 5'b00000; endcase   // 'A'
            5'd20: case (r) 3'd0: frow = 5'b10001; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b01010; 3'd3: frow = 5'b00100; 3'd4: frow = 5'b01010; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b10001; default: frow = 5'b00000; endcase   // 'X'
            5'd21: case (r) 3'd0: frow = 5'b11111; 3'd1: frow = 5'b10000; 3'd2: frow = 5'b10000; 3'd3: frow = 5'b11110; 3'd4: frow = 5'b10000; 3'd5: frow = 5'b10000; 3'd6: frow = 5'b11111; default: frow = 5'b00000; endcase   // 'E'
            5'd22: case (r) 3'd0: frow = 5'b11111; 3'd1: frow = 5'b10000; 3'd2: frow = 5'b10000; 3'd3: frow = 5'b11110; 3'd4: frow = 5'b10000; 3'd5: frow = 5'b10000; 3'd6: frow = 5'b10000; default: frow = 5'b00000; endcase   // 'F'
            5'd23: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10000; 3'd3: frow = 5'b01110; 3'd4: frow = 5'b00001; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // 'S'
            5'd24: case (r) 3'd0: frow = 5'b01110; 3'd1: frow = 5'b10001; 3'd2: frow = 5'b10000; 3'd3: frow = 5'b10000; 3'd4: frow = 5'b10000; 3'd5: frow = 5'b10001; 3'd6: frow = 5'b01110; default: frow = 5'b00000; endcase   // 'C'
            default: frow = 5'b00000;
        endcase
    endfunction

    assign bits = frow(ch, row);

endmodule

/* 索引表：
 *    0 = ' '
 *    1 = '0'
 *    2 = '1'
 *    3 = '2'
 *    4 = '3'
 *    5 = '4'
 *    6 = '5'
 *    7 = '6'
 *    8 = '7'
 *    9 = '8'
 *   10 = '9'
 *   11 = '.'
 *   12 = '-'
 *   13 = ':'
 *   14 = 'V'
 *   15 = 'P'
 *   16 = 'M'
 *   17 = 'I'
 *   18 = 'N'
 *   19 = 'A'
 *   20 = 'X'
 *   21 = 'E'
 *   22 = 'F'
 *   23 = 'S'
 *   24 = 'C'
 */
