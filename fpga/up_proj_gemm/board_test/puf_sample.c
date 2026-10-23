/*
 * puf_sample.c -- Butterfly PUF 板卡侧采样程序（P1）
 *
 * 用途：每次冷启动后触发一次 PUF 采样，把多数表决响应与非一致掩码追加到一个
 *       文本文件里。累积多次冷启动后，把文件拷回 PC，用
 *       tools/puf_stability.py 统计逐位翻转率。
 *
 *       基地址 0xA0030000 / 64KB 来自 Vivado Address Editor。
 *       寄存器映射来自 rtl/puf_axi_lite.sv，逐条对应。
 *
 * 输出文件格式（tools/puf_stability.py 认这个格式）：
 *     # PUF_SAMPLE v1 nbits=128 nwords=4 n_samp=9 t_force=8 t_settle=64
 *     <resp_hex> <unan_hex>
 *     ...
 *   位序约定：响应是 nbits 位串，bit b 位于 word(b/32) 的第 (b%32) 位；
 *             行内十六进制**从高字到低字**打印，即 bit(nbits-1) 在最左侧。
 *   （与 tools/puf_stability.py 的解析严格一致；改这里必须同步改那里。）
 *
 * 输出刻意用 ASCII，避免串口/终端按 GBK 解析 UTF-8 出现乱码。
 *
 * 编译：gcc -O2 -o puf_sample puf_sample.c
 * 运行：
 *   sudo ./puf_sample --append /opt/fara/puf/puf_samples.txt  采样 + 追加
 *   sudo ./puf_sample --read-only                             仅读寄存器，不采样
 *   sudo ./puf_sample --m 9 --tforce 8 --tsettle 64 --append <file>
 */

#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define PUF_BASE_DEF 0xA0030000UL
#define MAP_SIZE     0x10000UL       /* 64 KB */

/* 寄存器字节偏移（rtl/puf_axi_lite.sv） */
#define R_CTRL        0x00   /* W  [0]start [1]soft_rst */
#define R_STATUS      0x04   /* R  [0]busy [1]done [2]err [7:4]state */
#define R_NBITS       0x08   /* R  PUF 位宽 */
#define R_NWORDS      0x0C   /* R  响应字数 */
#define R_N_SAMP      0x10   /* RW 采样次数 M（必须奇数） */
#define R_T_FORCE     0x14   /* RW 强制态周期数 */
#define R_T_SETTLE    0x18   /* RW 收敛等待周期数 */
#define R_VERSION     0x1C   /* R  0x00010000 */
#define R_NSAMP_DONE  0x20   /* R  实际完成采样次数 */
#define R_STABLE_CNT  0x24   /* R  稳定位数 */
#define R_IDX         0x28   /* RW 字下标 */
#define R_DATA        0x2C   /* R  该字响应 */
#define R_UNAN        0x30   /* R  该字非一致掩码 */

#define HW_VERSION    0x00010000u
#define MAX_WORD      64     /* N_BITS/32 的上限 */

static volatile uint32_t *g;

static uint32_t rd(unsigned off)             { return g[off >> 2]; }
static void     wr(unsigned off, uint32_t v) { g[off >> 2] = v; }

/*
 * 触发一次采样，把结果填进调用者给的缓冲。
 * rhex/uhex 由调用者提供，长度需 >= nwords*8 + 1。
 * 返回 0 成功；1 失败（已打印原因）。
 */
static int do_sample(int m, int tforce, int tsettle,
                     char *rhex, size_t rlen, char *uhex, size_t ulen)
{
    uint32_t nbits, nwords, st, i;
    int timeout, rpos = 0, upos = 0;
    int n;

    nbits  = rd(R_NBITS);
    nwords = rd(R_NWORDS);

    if (nwords == 0 || nwords > MAX_WORD) {
        printf("!! NWORDS=%u 不合理（上限 %d）\n", nwords, MAX_WORD);
        return 1;
    }
    if ((size_t)nwords * 8 + 1 > rlen || (size_t)nwords * 8 + 1 > ulen) {
        printf("!! 缓冲不足\n");
        return 1;
    }

    /* 配置 */
    wr(R_N_SAMP,   (uint32_t)m);
    wr(R_T_FORCE,  (uint32_t)tforce);
    wr(R_T_SETTLE, (uint32_t)tsettle);

    /* 启动 */
    wr(R_CTRL, 1u);

    /* 等 done */
    timeout = 0;
    while (timeout < 10000000) {
        st = rd(R_STATUS);
        if (st & (1u << 1)) break;                    /* done */
        if (st & (1u << 2)) {                         /* err */
            printf("!! 采样报错（M 必须为奇数且 <= 31）：STATUS=0x%08X\n", st);
            wr(R_CTRL, 0u);
            return 1;
        }
        timeout++;
    }
    if (timeout >= 10000000) {
        printf("!! 等 done 超时，STATUS=0x%08X state=%u\n",
               rd(R_STATUS), (rd(R_STATUS) >> 4) & 0xFu);
        return 1;
    }

    /* 逐字读；从高字到低字拼串，使 bit(nbits-1) 落在最左侧十六进制位 */
    rhex[0] = uhex[0] = '\0';
    for (i = nwords; i-- > 0; ) {
        wr(R_IDX, i);
        n = snprintf(rhex + rpos, rlen - rpos, "%08X", rd(R_DATA));
        if (n < 0 || (size_t)n >= rlen - rpos) return 1;
        rpos += n;

        n = snprintf(uhex + upos, ulen - upos, "%08X", rd(R_UNAN));
        if (n < 0 || (size_t)n >= ulen - upos) return 1;
        upos += n;
    }

    wr(R_CTRL, 0u);   /* 清 done */
    return 0;
}

static void print_regs(void)
{
    uint32_t st = rd(R_STATUS);
    printf("VERSION    = 0x%08X  (expect 0x%08X)\n", rd(R_VERSION), HW_VERSION);
    printf("NBITS      = %u\n", rd(R_NBITS));
    printf("NWORDS     = %u\n", rd(R_NWORDS));
    printf("N_SAMP     = %u\n", rd(R_N_SAMP));
    printf("T_FORCE    = %u\n", rd(R_T_FORCE));
    printf("T_SETTLE   = %u\n", rd(R_T_SETTLE));
    printf("STATUS     = 0x%08X  busy=%u done=%u err=%u state=%u\n",
           st, st & 1u, (st >> 1) & 1u, (st >> 2) & 1u, (st >> 4) & 0xFu);
    printf("NSAMP_DONE = %u\n", rd(R_NSAMP_DONE));
    printf("STABLE_CNT = %u\n", rd(R_STABLE_CNT));
}

int main(int argc, char **argv)
{
    unsigned long base = PUF_BASE_DEF;
    const char *append_path = NULL;
    int m = 9, tforce = 8, tsettle = 64;
    int read_only = 0, quiet = 0, i;

    char rhex[MAX_WORD * 8 + 1];
    char uhex[MAX_WORD * 8 + 1];

    for (i = 1; i < argc; i++) {
        if (!strcmp(argv[i], "--base") && i + 1 < argc)          base = strtoul(argv[++i], NULL, 0);
        else if (!strcmp(argv[i], "--append") && i + 1 < argc)   append_path = argv[++i];
        else if (!strcmp(argv[i], "--m") && i + 1 < argc)        m = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tforce") && i + 1 < argc)   tforce = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--tsettle") && i + 1 < argc)  tsettle = atoi(argv[++i]);
        else if (!strcmp(argv[i], "--read-only"))                read_only = 1;
        else if (!strcmp(argv[i], "--quiet"))                    quiet = 1;
        else {
            printf("未知参数 %s\n"
                   "用法: %s [--base 0xA0030000] [--append FILE] [--m N]\n"
                   "      [--tforce N] [--tsettle N] [--read-only] [--quiet]\n",
                   argv[i], argv[0]);
            return 2;
        }
    }

    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }
    void *p = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, base);
    if (p == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
    g = (volatile uint32_t *)p;

    printf("PUF @ 0x%08lX (mapped %lu KB)\n", base, MAP_SIZE / 1024);

    if (rd(R_VERSION) != HW_VERSION) {
        printf("!! VERSION=0x%08X 期望 0x%08X —— PUF 未挂上总线？\n"
               "   检查 Address Editor: puf_bd_0/S_AXI = 0xA0030000 / 64K\n"
               "   检查 BD: smartconnect_0/M02_AXI -> puf_bd_0/s_axi\n",
               rd(R_VERSION), HW_VERSION);
        munmap(p, MAP_SIZE); close(fd);
        return 1;
    }

    if (read_only) {
        print_regs();
        munmap(p, MAP_SIZE); close(fd);
        return 0;
    }

    /* ---- 采样 ---- */
    printf("---- sample (M=%d T_FORCE=%d T_SETTLE=%d) ----\n", m, tforce, tsettle);
    if (do_sample(m, tforce, tsettle, rhex, sizeof(rhex), uhex, sizeof(uhex)) != 0) {
        munmap(p, MAP_SIZE); close(fd);
        return 1;
    }

    if (!quiet) {
        printf("  NSAMP_DONE=%u  STABLE_CNT=%u  STATE=%u\n",
               rd(R_NSAMP_DONE), rd(R_STABLE_CNT), (rd(R_STATUS) >> 4) & 0xFu);
        printf("  resp=%s\n  unan=%s\n", rhex, uhex);
    }

    /* ---- 追加到文件 ---- */
    if (append_path) {
        FILE *f = fopen(append_path, "a");
        if (!f) { perror(append_path); munmap(p, MAP_SIZE); close(fd); return 1; }

        /* 文件为空时补一行元信息头 */
        int need_header = 0;
        FILE *chk = fopen(append_path, "r");
        if (!chk) {
            need_header = 1;
        } else {
            if (fseek(chk, 0, SEEK_END) == 0 && ftell(chk) == 0) need_header = 1;
            fclose(chk);
        }
        if (need_header) {
            fprintf(f, "# PUF_SAMPLE v1 nbits=%u nwords=%u n_samp=%d t_force=%d t_settle=%d\n",
                    rd(R_NBITS), rd(R_NWORDS), m, tforce, tsettle);
        }
        fprintf(f, "%s %s\n", rhex, uhex);
        fclose(f);
        printf("  已追加到 %s\n", append_path);
    }

    munmap(p, MAP_SIZE);
    close(fd);
    return 0;
}
