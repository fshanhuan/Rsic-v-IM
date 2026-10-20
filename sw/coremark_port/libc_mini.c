/* =============================================================================
 * sw/coremark_port/libc_mini.c -- 极简 libc（-nostdlib 下 gcc 会隐式调用这些）
 * -----------------------------------------------------------------------------
 * gcc 在 -ffreestanding 下仍会把结构体赋值/数组清零展开成 memcpy/memset 调用，
 * 所以即使不 include <string.h> 也必须提供。全部按 4 字节为主，慢但够用；
 * 它们不在 CoreMark 的计时区间热点里（除了 memset 清数据块，占比很小）。
 * ★ 编译时必须带 -fno-builtin，否则 gcc 会把本文件的 memcpy 递归成自己。
 * ============================================================================= */
typedef unsigned int size_t_;

void *memcpy(void *dst, const void *src, size_t_ n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    while (n--)
        *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t_ n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;
    if (d < s)
        while (n--)
            *d++ = *s++;
    else
    {
        d += n;
        s += n;
        while (n--)
            *--d = *--s;
    }
    return dst;
}

void *memset(void *dst, int c, size_t_ n)
{
    unsigned char *d = (unsigned char *)dst;
    while (n--)
        *d++ = (unsigned char)c;
    return dst;
}

int memcmp(const void *a, const void *b, size_t_ n)
{
    const unsigned char *x = (const unsigned char *)a;
    const unsigned char *y = (const unsigned char *)b;
    while (n--)
    {
        if (*x != *y)
            return (int)*x - (int)*y;
        x++;
        y++;
    }
    return 0;
}

size_t_ strlen(const char *s)
{
    const char *p = s;
    while (*p)
        p++;
    return (size_t_)(p - s);
}

int strcmp(const char *a, const char *b)
{
    while (*a && *a == *b)
    {
        a++;
        b++;
    }
    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

/* modf：vendor 的 cvt.c（ee_printf 打 %f）唯一需要的外部数学函数。
 * 本核无 FPU，但 gcc 会用 libgcc 的软双精度例程生成这段代码。
 * 定义域注意：这里用 "转 long long 再转回" 取整，double 超过 2^63 才有问题，
 * CoreMark 报告里的分数远小于该范围。 */
double modf(double x, double *iptr)
{
    double i = (double)(long long)x;   /* 向零截断，符合 modf 定义 */
    *iptr = i;
    return x - i;
}
