/* =============================================================================
 * sw/snake_play.c — S5：可玩的贪吃蛇（ANSI 终端 + 方向键 + mtime 帧节拍）
 * -----------------------------------------------------------------------------
 * 显示：没有 VGA，唯一的"屏幕"是串口终端。用 ANSI 转义：
 *   ESC[<r>;<c>H 光标定位（增量重绘用）
 *   ESC[K        擦到行尾（状态行变短时用）
 *   ESC[?25l     隐藏光标（开局一次）
 *   20×12 网格，边框用 +-|，头 'O'，身 'o'，食物 '*'
 *
 * 输入：方向键是三个字节 ESC [ A/B/C/D；用 getc_nb 轮询（本工程的中断输入
 *   路径在真片上会破坏字节流，见 docs/ROADMAP_SoC.md 的 S1 记录）。
 *
 * 节拍：CLINT 的 mtime，500 kHz → 每 tick 2 µs；STEP_TICKS = 60000 ≈ 120 ms/步。
 *
 * 帧预算（115200，11.52 KB/s）：
 *   P1-3 已改成**增量重绘**：一步只发改动过的格子（约 2~3 格 ≈ 20 字节），
 *   不再整屏 350 字符重画。边框只画一次，蛇死了画面不动就完全静默。
 *   这样 120 ms 的步进间隔里串口占用从 ~30 ms 降到 <0.2 ms。
 * ============================================================================= */
#include <stdint.h>

#define TXDATA   (*(volatile uint32_t *)0x10000000u)
#define TXSTAT   (*(volatile uint32_t *)0x10000004u)
#define LED      (*(volatile uint32_t *)0x10000010u)
#define RXSTAT   (*(volatile uint32_t *)0x1000000Cu)
#define RXDATA   (*(volatile uint32_t *)0x10000008u)
#define RXPOP    (*(volatile uint32_t *)0x10000018u)
#define MTIME    (*(volatile uint32_t *)0x10000030u)

#define W        20
#define H        12
#define MAXLEN   64
#define STEP_TICKS 60000u

#define DIR_R 0
#define DIR_D 1
#define DIR_L 2
#define DIR_U 3

static uint16_t body[MAXLEN];
static uint16_t food;
static uint32_t len, score, alive, dir;
static uint32_t nseed = 12345u;

static void putc_(char c) { while (TXSTAT & 1u) ; TXDATA = (uint32_t)(uint8_t)c; }
static void puts_(const char *s) { while (*s) putc_(*s++); }
static void putdec_(uint32_t v)
{
    char b[11]; int i = 0;
    if (v == 0u) { putc_('0'); return; }
    while (v) { b[i++] = (char)('0' + v % 10u); v /= 10u; }
    while (i) putc_(b[--i]);
}

static int getc_nb(void)
{
    int c;
    if ((RXSTAT & 1u) == 0u) return -1;
    c = (int)(RXDATA & 0xFFu);
    RXPOP = 1u;
    return c;
}

/* 无符号 LCG，够用且不依赖 libc */
static uint32_t rnd(void) { nseed = nseed * 1103515245u + 12345u; return (nseed >> 16) & 0x7FFFu; }

static uint16_t mk(int x, int y) { return (uint16_t)(y * W + x); }
static int px(uint16_t p) { return p % W; }
static int py(uint16_t p) { return p / W; }

static int occupied(uint16_t p)
{
    uint32_t i;
    for (i = 0; i < len; i++) if (body[i] == p) return 1;
    return 0;
}

static void place_food(void)
{
    uint32_t guard = 0;
    do { food = mk((int)(rnd() % W), (int)(rnd() % H)); } while (occupied(food) && ++guard < 500u);
}

static void game_init(void)
{
    len = 3; score = 0; alive = 1; dir = DIR_R;
    body[0] = mk(5, 5);
    body[1] = mk(4, 5);
    body[2] = mk(3, 5);
    place_food();
}

static int hit_self(uint16_t p, int grow)
{
    uint32_t i, n = grow ? len : (len - 1u);
    for (i = 0; i < n; i++) if (body[i] == p) return 1;
    return 0;
}

static void game_step(void)
{
    int x, y; uint32_t i; uint16_t np;
    if (!alive) return;
    x = px(body[0]); y = py(body[0]);
    switch (dir) {
        case DIR_R: x++; break;
        case DIR_D: y++; break;
        case DIR_L: x--; break;
        default:    y--; break;
    }
    if (x < 0 || x >= W || y < 0 || y >= H) { alive = 0; return; }
    np = mk(x, y);
    if (hit_self(np, np == food)) { alive = 0; return; }
    if (np == food) {
        if (len < MAXLEN) len++;
        score++;
        for (i = len - 1u; i > 0; i--) body[i] = body[i - 1u];
        body[0] = np;
        place_food();
        return;
    }
    for (i = len - 1u; i > 0; i--) body[i] = body[i - 1u];
    body[0] = np;
}

/* ------------------------------------------------------------------ 增量重绘
 * P1-3：原来每帧 `ESC[H` + 整屏重画 ≈ 350 字符（115200 下 ~30 ms），每一步都刷；
 *   现在只重画**变了的格子**，用 `ESC[<row>;<col>H` 定位：
 *     · 一次移动只改 2~3 格（尾、头、新食物）→ 约 20 字节，比整屏少 94%；
 *     · 静止（蛇死了）时**一个字节都不发**，终端不会再滚；
 *     · 边框只画一次（board_draw），以后不再碰。
 *   scr[][] 记住"屏幕上现在是什么"，和本帧的新画面逐格比对。
 * ★ 坐标（1 基）：状态行 = 1；棋盘第 y 行 → 边框行 2+2y、内容行 3+2y、内容列 2+x。
 * ------------------------------------------------------------------------- */
static char scr[H][W];          /* 屏幕上当前每格显示的字符 */
static int  scr_ok;             /* 0 = 屏幕内容未知（第一次要画边框 + 全格） */
static char sline[80];          /* 上一次画的状态行 */
static int  slen;

static void at(int row, int col)
{
    putc_(0x1B); putc_('[');
    putdec_((uint32_t)row); putc_(';'); putdec_((uint32_t)col); putc_('H');
}

static int s_add(char *d, int n, const char *s) { while (*s) d[n++] = *s++; return n; }

static int s_num(char *d, int n, uint32_t v)
{
    char b[11]; int i = 0;
    if (v == 0u) b[i++] = '0';
    while (v) { b[i++] = (char)('0' + v % 10u); v /= 10u; }
    while (i) d[n++] = b[--i];
    return n;
}

static void status_draw(void)
{
    char b[80];
    int n = 0, k, same = 1;
    n = s_add(b, n, "score "); n = s_num(b, n, score);
    n = s_add(b, n, "  len "); n = s_num(b, n, len);
    if (!alive) n = s_add(b, n, "   GAME OVER (r=restart q=quit)");

    if (n == slen) {
        for (k = 0; k < n; k++) if (b[k] != sline[k]) { same = 0; break; }
        if (same) return;                       /* 状态没变：一个字节都不发 */
    }
    at(1, 1);
    for (k = 0; k < n; k++) putc_(b[k]);
    if (slen > n) { at(1, n + 1); puts_("\x1b[K"); }   /* 擦掉旧状态行的尾巴 */
    for (k = 0; k < n; k++) sline[k] = b[k];
    slen = n;
}

/* 边框只画一次 */
static void board_draw(void)
{
    int x, y;
    at(2, 1); putc_('+'); for (x = 0; x < W; x++) putc_('-'); putc_('+');
    for (y = 0; y < H; y++) {
        at(3 + 2 * y, 1);     putc_('|');
        at(3 + 2 * y, W + 2); putc_('|');
        at(4 + 2 * y, 1);     putc_('+');
        for (x = 0; x < W; x++) putc_('-');
        putc_('+');
    }
}

static void render(void)
{
    char cur[H][W];
    uint32_t i;
    int x, y;

#ifdef SNAKE_FULL_REDRAW
    /* A/B 对照用：强制整屏重画，复现 P1-3 之前的串口流量（只为量数据，不发布） */
    scr_ok = 0;
#endif

    if (!scr_ok) {
        board_draw();
        for (y = 0; y < H; y++) for (x = 0; x < W; x++) scr[y][x] = 0;
        scr_ok = 1;
    }

    status_draw();

    for (y = 0; y < H; y++) for (x = 0; x < W; x++) cur[y][x] = ' ';
    for (i = 0; i < len; i++) {
        uint16_t p = body[i];
        if (p < (uint16_t)(W * H)) cur[p / W][p % W] = 'o';
    }
    cur[body[0] / W][body[0] % W] = 'O';
    cur[food / W][food % W] = '*';

    for (y = 0; y < H; y++)
        for (x = 0; x < W; x++)
            if (scr[y][x] != cur[y][x]) {
                at(3 + 2 * y, 2 + x);
                putc_(cur[y][x]);
                scr[y][x] = cur[y][x];
            }
}

/* 带超时的取字节（ticks：500 kHz 下的 tick 数，2500 ≈ 5 ms） */
static int getc_to(uint32_t ticks)
{
    uint32_t t0 = MTIME;
    for (;;) {
        int c = getc_nb();
        if (c >= 0) return c;
        if ((uint32_t)(MTIME - t0) > ticks) return -1;
    }
}

/* 读一个方向；返回 -1 表示没有
 * ★ ESC 后面的两个字节必须**等**：115200 下相邻字节间隔 87 µs，而 read_dir 里
 *   两次 getc_nb 相隔只有几十 ns —— 不等就永远拼不出 ESC [ A（实测症状：
 *   方向键完全没反应，蛇只会一路直冲撞墙）。 */
static int read_dir(void)
{
    int c = getc_nb();
    int c2, c3;
    if (c < 0) return -1;
    if (c == 'q') return 99;
    if (c == 'r') return 98;
    if (c != 0x1B) return -1;
    c2 = getc_to(2500u);
    if (c2 < 0) return -1;
    if (c2 != '[') return -1;
    c3 = getc_to(2500u);
    if (c3 < 0) return -1;
    switch (c3) {
        case 'A': return DIR_U;
        case 'B': return DIR_D;
        case 'C': return DIR_R;
        case 'D': return DIR_L;
        default:  return -1;
    }
}

static int opposite(int a, int b)
{
    return (a == DIR_R && b == DIR_L) || (a == DIR_L && b == DIR_R) ||
           (a == DIR_U && b == DIR_D) || (a == DIR_D && b == DIR_U);
}

int main(void)
{
    uint32_t next, now;
    int d;

    puts_("\x1b[2J\x1b[?25l");        /* 清屏 + 隐藏光标 */
    game_init();
    render();
    next = MTIME + STEP_TICKS;

    for (;;) {
        d = read_dir();
        if (d == 99) break;                       /* q 退出 */
        if (d == 98) { game_init(); render(); }    /* r 重开（增量重绘会自己算差异） */
        else if (d >= 0 && !opposite(d, dir)) dir = (uint32_t)d;

        now = MTIME;
        if ((int32_t)(now - next) >= 0) {
            next = now + STEP_TICKS;
            /* ★ 只调一次 render()：增量重绘会自己判断"哪些格子变了"。
             *   死了以后画面不变 → 一个字节都不发（原来那句 need_render 是为了
             *   避免整屏重画把串口刷满，现在这个顾虑消失了）。 */
            if (alive) game_step();
            render();
            LED = (score & 0x3Fu) | (alive ? 0x40u : 0x00u);
        }
    }

    puts_("\x1b[?25h");               /* 恢复光标 */
    return 0;
}
