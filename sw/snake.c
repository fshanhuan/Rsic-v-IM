/* =============================================================================
 * sw/snake.c — S5：贪吃蛇的**游戏逻辑内核**（无渲染，先用判据跑通）
 * -----------------------------------------------------------------------------
 * 为什么先做无渲染版：渲染要 ANSI 转义 + 115200 的帧预算，调起来慢；而正确性
 *   （走位 / 吃食长身 / 自撞 / 撞墙）可以完全脱屏验证。渲染是下一层，套在同一内核上。
 *
 * 数据结构（刻意选最笨但最不容易错的）：
 *   body[0] 是蛇头，body[1..len-1] 依次是身体；每走一步整体后移一格。
 *   O(len) 拷贝，len ≤ 64，一次几百拍 —— 在 50 MHz 上完全不值得优化。
 *
 * 规则：
 *   · 网格 20×12，pos = y*20 + x；
 *   · 撞墙 / 撞自己（尾巴那格除外，它下一步会让开）→ alive=0；
 *   · 吃到食物 → score+1、len+1；
 *   · 180° 反向由输入层拒绝，内核只负责执行。
 *
 * 判据：score=1、len=4、alive=0（最后撞墙），写 DRAM 0x2000，LED=0x2A。
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define LED      (*(volatile uint32_t *)0x10000010u)

#define W        20
#define H        12
#define MAXLEN   64

#define DIR_R 0
#define DIR_D 1
#define DIR_L 2
#define DIR_U 3

static uint16_t body[MAXLEN];
static uint16_t food;
static uint32_t len, score, alive, dir;

static void putc_(char c) { while (TXSTAT & 1u) ; TXDATA = (uint32_t)(uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }

static uint16_t mk(int x, int y) { return (uint16_t)(y * W + x); }
static int px(uint16_t p) { return p % W; }
static int py(uint16_t p) { return p / W; }

static void snake_init(int x, int y)
{
    len = 3; score = 0; alive = 1; dir = DIR_R;
    body[0] = mk(x, y);
    body[1] = mk(x - 1, y);
    body[2] = mk(x - 2, y);
    food = 0xFFFF;
}

/* 新头是否撞到自己；在"会吃到食物"的那一步，尾巴不移动，所以尾巴也算障碍 */
static int hit_self(uint16_t p, int will_grow)
{
    uint32_t i, n = will_grow ? len : (len - 1u);
    for (i = 0; i < n; i++)
        if (body[i] == p) return 1;
    return 0;
}

static int snake_step(void)
{
    int x, y;
    uint32_t i;
    uint16_t np;

    if (!alive) return 0;

    x = px(body[0]);
    y = py(body[0]);
    switch (dir) {
        case DIR_R: x++; break;
        case DIR_D: y++; break;
        case DIR_L: x--; break;
        default:    y--; break;
    }
    if (x < 0 || x >= W || y < 0 || y >= H) { alive = 0; return 0; }

    np = mk(x, y);
    {
        int grow = (np == food);
        if (hit_self(np, grow)) { alive = 0; return 0; }

        if (grow) {
            if (len < MAXLEN) len++;
            score++;
            food = 0xFFFF;
            for (i = len - 1u; i > 0; i--) body[i] = body[i - 1u];
            body[0] = np;
            return 1;
        }
        for (i = len - 1u; i > 0; i--) body[i] = body[i - 1u];
        body[0] = np;
    }
    return 0;
}

int main(void)
{
    int ok = 1, ate, i;
    volatile uint32_t *out = (volatile uint32_t *)0x00002000u;

    snake_init(5, 5);

    /* ① 直走吃食：食物在 (6,5) */
    food = mk(6, 5);
    ate = snake_step();
    ok &= (ate == 1) && (score == 1) && (len == 4) && (alive == 1);
    ok &= (body[0] == mk(6, 5)) && (body[1] == mk(5, 5));

    /* ② 再走三步 → 头到 (9,5) */
    snake_step(); snake_step(); snake_step();
    ok &= (body[0] == mk(9, 5));

    /* ③ 转下，两步 → (9,7) */
    dir = DIR_D;
    snake_step(); snake_step();
    ok &= (body[0] == mk(9, 7));

    /* ④ 转左，一步 → (8,7)，不应撞到自己（身体在 5~7 行靠右） */
    dir = DIR_L;
    snake_step();
    ok &= (alive == 1) && (body[0] == mk(8, 7));

    /* ⑤ 一直往左撞墙 → 应该在 x 越过 0 的那一步死掉 */
    for (i = 0; i < 12 && alive; i++) snake_step();
    ok &= (alive == 0);
    ok &= (px(body[0]) == 0);                 /* 停在第 0 列 */

    out[0] = score;
    out[1] = len;
    out[2] = alive;
    out[3] = (uint32_t)ok;

    LED = ok ? 0x2Au : 0x7Fu;
    puts_(ok ? "SNAKE-OK\n" : "SNAKE-FAIL\n");
    for (;;) ;
}
