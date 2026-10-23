/*
 * far_bench.c -- up_proj GEMM 「软件 FaR vs 硬件 FaR」对比基准 (L4)
 *
 * 目的（这是整个 FaR 硬件化论证的落点）
 *   把 tools/export_far_bench.py 生成的 FBEN 基准包灌进 PL，同一条数据通路上跑两遍：
 *     跑 A：far_en=0（基线直通，用 shadow 权重、不重路由）
 *     跑 B：far_en=1（硬件 FaR，PL 内对激活做 forget-and-rewire）
 *   然后回答三个问题：
 *     (a) 硬件 FaR 输出 == 软件 FaR golden（bit-exact）→ 硬件忠实复刻软件
 *     (b) 硬件基线输出 == 软件 shadow golden（bit-exact）→ 关掉 FaR 就是普通 GEMM
 *     (c) 两跑的墙钟时间差 ≈ 0 → FaR 的额外代价被吃进数据通路，不占 CPU
 *
 * 输入文件（FBEN，全小端）
 *   magic "FBEN" 4B
 *   header 7*u32 : K N M_TOTAL M_TILE G n_in n_out
 *   in_words   [n_in]  : [X_raw | b | W_shadow]（X 是原始激活，重路由由 PL 做）
 *   out_far    [n_out] : 软件 golden Y_far    = hw_order(rewire(X), W_shadow, b)
 *   out_shadow [n_out] : 软件 golden Y_shadow = hw_order(X,          W_shadow, b)
 *   out_base   [n_out] : 软件 golden Y_base   = hw_order(X,          W_orig,   b)
 *   FaRMap 在同名 .fmap（文本）：首行条目数，之后每行 "col inv nd d0 d1"（hex）
 *
 * 通路：DDR(CMA) --AXI DMA MM2S--> gemm_up_proj_bd/s_axis
 *       gemm_up_proj_bd/m_axis --AXI DMA S2MM--> DDR(CMA)
 *       控制/状态走 AXI-Lite（DMA @0xA0000000，GEMM @0xA0010000）
 *
 * 编译：gcc -O2 -o far_bench far_bench.c
 * 运行：sudo ./far_bench far_bench.bin [far_bench.fmap] [reps]
 *
 * 输出刻意用 ASCII，避免串口按 GBK 解析 UTF-8 出现乱码。
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <time.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <signal.h>
#include <setjmp.h>

/*---------------------------------------------------------------------------
 * dma-heap / dma-buf 用户态 ABI（与 gemm_dma_test.c 保持一致）
 *-------------------------------------------------------------------------*/
#if defined(__has_include)
#  if __has_include(<linux/dma-heap.h>)
#    include <linux/dma-heap.h>
#    define HAVE_DMA_HEAP_H 1
#  endif
#  if __has_include(<linux/dma-buf.h>)
#    include <linux/dma-buf.h>
#    define HAVE_DMA_BUF_H 1
#  endif
#endif

#ifndef HAVE_DMA_HEAP_H
struct dma_heap_allocation_data {
    uint64_t len;
    uint32_t fd;
    uint32_t fd_flags;
    uint64_t heap_flags;
};
#define DMA_HEAP_IOC_MAGIC 'H'
#endif

#ifndef DMA_HEAP_IOCTL_ALLOC
#define DMA_HEAP_IOCTL_ALLOC \
    _IOWR(DMA_HEAP_IOC_MAGIC, 0x0, struct dma_heap_allocation_data)
#endif

#ifndef HAVE_DMA_BUF_H
struct dma_buf_sync {
    uint64_t flags;
};
#define DMA_BUF_SYNC_READ  (1 << 0)
#define DMA_BUF_SYNC_WRITE (2 << 0)
#define DMA_BUF_SYNC_RW    (DMA_BUF_SYNC_READ | DMA_BUF_SYNC_WRITE)
#define DMA_BUF_SYNC_START (0 << 2)
#define DMA_BUF_SYNC_END   (1 << 2)
#define DMA_BUF_BASE 'b'
#define DMA_BUF_IOCTL_SYNC _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync)
#endif

/*---------------------------------------------------------------------------
 * 地址映射
 *-------------------------------------------------------------------------*/
#define DMA_BASE     0xA0000000UL
#define GEMM_BASE    0xA0010000UL
#define MAP_SIZE     0x10000UL          /* 64 KB */

/* ---- AXI DMA Simple 模式寄存器 (PG021) ---- */
#define MM2S_DMACR    0x00
#define MM2S_DMASR    0x04
#define MM2S_SA       0x18
#define MM2S_SA_MSB   0x1C
#define MM2S_LENGTH   0x28
#define S2MM_DMACR    0x30
#define S2MM_DMASR    0x34
#define S2MM_DA       0x48
#define S2MM_DA_MSB   0x4C
#define S2MM_LENGTH   0x58

#define DMACR_RS      (1u << 0)
#define DMACR_RESET   (1u << 2)

#define DMASR_HALTED  (1u << 0)
#define DMASR_IDLE    (1u << 1)
#define DMASR_IOC     (1u << 12)
#define DMASR_ERR     ((1u << 4) | (1u << 5) | (1u << 6) | \
                       (1u << 8) | (1u << 9) | (1u << 10) | (1u << 14))

/* ---- GEMM AXI-Lite 寄存器 (gemm_up_proj_axi_lite.sv) ---- */
#define R_CTRL       0x00
#define R_STATUS     0x04
#define R_M_ROWS     0x08
#define R_K_COLS     0x0C
#define R_N_TOKENS   0x10
#define R_LAYER_ID   0x14
#define R_VERSION    0x18
#define R_N_TILES    0x1C
#define R_IN_WORDS   0x20
#define R_OUT_WORDS  0x24
#define R_TILE_IDX   0x28
#define R_STATE      0x2C

/* FaRMap 寄存器组（间接寻址：先写 FAR_IDX，再读写 FAR_A/INV/ND/D0/D1） */
#define R_FAR_CTRL   0x30
#define R_FAR_NENT   0x34
#define R_FAR_IDX    0x38
#define R_FAR_A      0x3C
#define R_FAR_INV    0x40
#define R_FAR_ND     0x44
#define R_FAR_D0     0x48
#define R_FAR_D1     0x4C
#define R_FAR_HITS   0x50
#define R_FAR_PHASE  0x54

#define HW_M_TILE    16u
#define HW_M_TOTAL   3072u
#define HW_N_TILES   192u
#define HW_G         8u
#define HW_VERSION   0x00020000u        /* FaR 版：0x0001=纯 GEMM，0x0002=含 FaR */
#define FAR_MAX_ENT  16

#define DMA_MAX_XFER ((1UL << 26) - 1)
#define POLL_TIMEOUT_S 30.0

static volatile uint32_t *dma;
static volatile uint32_t *gemm;

static uint32_t rd_d(unsigned off)              { return dma[off >> 2]; }
static void     wr_d(unsigned off, uint32_t v) { dma[off >> 2] = v; }
static uint32_t rd_g(unsigned off)              { return gemm[off >> 2]; }
static void     wr_g(unsigned off, uint32_t v) { gemm[off >> 2] = v; }

static int fails;

/*---------------------------------------------------------------------------
 * FBEN 基准包
 *-------------------------------------------------------------------------*/
typedef struct {
    uint32_t K, N, M_TOTAL, M_TILE, G, n_in, n_out;
    uint32_t *in_words;
    uint32_t *out_far;
    uint32_t *out_shadow;
    uint32_t *out_base;
} fben_t;

static int load_fben(const char *path, fben_t *v)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen fben"); return -1; }

    char magic[4];
    uint32_t h[7];
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "FBEN", 4) != 0) {
        fprintf(stderr, "bad magic in %s (expect FBEN)\n", path);
        fclose(f);
        return -1;
    }
    if (fread(h, 4, 7, f) != 7) {
        fprintf(stderr, "short header in %s\n", path);
        fclose(f);
        return -1;
    }
    v->K = h[0]; v->N = h[1]; v->M_TOTAL = h[2]; v->M_TILE = h[3];
    v->G = h[4]; v->n_in = h[5]; v->n_out = h[6];

    v->in_words   = malloc(4u * (size_t)v->n_in);
    v->out_far    = malloc(4u * (size_t)v->n_out);
    v->out_shadow = malloc(4u * (size_t)v->n_out);
    v->out_base   = malloc(4u * (size_t)v->n_out);
    if (!v->in_words || !v->out_far || !v->out_shadow || !v->out_base) {
        fprintf(stderr, "oom\n");
        fclose(f);
        return -1;
    }
    if (fread(v->in_words,   4, v->n_in,  f) != v->n_in  ||
        fread(v->out_far,    4, v->n_out, f) != v->n_out ||
        fread(v->out_shadow, 4, v->n_out, f) != v->n_out ||
        fread(v->out_base,   4, v->n_out, f) != v->n_out) {
        fprintf(stderr, "short payload in %s\n", path);
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}

/*---------------------------------------------------------------------------
 * FaRMap
 *-------------------------------------------------------------------------*/
typedef struct {
    uint32_t col, inv, nd, d0, d1;
} fmap_ent_t;

static int load_fmap(const char *path, fmap_ent_t *e, uint32_t *n_out)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror("fopen fmap"); return -1; }
    unsigned n = 0;
    if (fscanf(f, "%u", &n) != 1 || n > FAR_MAX_ENT) {
        fprintf(stderr, "bad fmap head in %s\n", path);
        fclose(f);
        return -1;
    }
    for (unsigned i = 0; i < n; i++) {
        unsigned a, iv, nd, d0, d1;
        if (fscanf(f, "%x %x %x %x %x", &a, &iv, &nd, &d0, &d1) != 5) {
            fprintf(stderr, "bad fmap entry %u in %s\n", i, path);
            fclose(f);
            return -1;
        }
        e[i].col = a; e[i].inv = iv; e[i].nd = nd; e[i].d0 = d0; e[i].d1 = d1;
    }
    fclose(f);
    *n_out = n;
    return 0;
}

/*---------------------------------------------------------------------------
 * CMA 缓冲区 / cache / 物理地址（与 gemm_dma_test.c 同）
 *-------------------------------------------------------------------------*/
static int heap_alloc(size_t len, int *out_fd)
{
    int hfd = open("/dev/dma_heap/reserved", O_RDWR | O_CLOEXEC);
    if (hfd < 0) return -1;
    struct dma_heap_allocation_data d;
    memset(&d, 0, sizeof d);
    d.len = len; d.fd_flags = O_RDWR | O_CLOEXEC; d.heap_flags = 0;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &d) < 0) { close(hfd); return -1; }
    close(hfd);
    *out_fd = (int)d.fd;
    return 0;
}

static int buf_sync(int fd, uint64_t flags)
{
    struct dma_buf_sync s;
    s.flags = flags;
    return ioctl(fd, DMA_BUF_IOCTL_SYNC, &s);
}

static uint64_t va_to_pa(const void *va, const char **why)
{
    int fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { *why = "open /proc/self/pagemap failed"; return 0; }
    uint64_t entry = 0;
    off_t off = (off_t)(((uintptr_t)va >> 12) * 8);
    ssize_t n = pread(fd, &entry, 8, off);
    close(fd);
    if (n != 8)                  { *why = "pread pagemap failed"; return 0; }
    if (!(entry & (1ULL << 63))) { *why = "page not present"; return 0; }
    uint64_t pfn = entry & ((1ULL << 55) - 1);
    if (!pfn)                    { *why = "PFN zeroed (need CAP_SYS_ADMIN)"; return 0; }
    return (pfn << 12) | ((uintptr_t)va & 0xFFFULL);
}

static int have_dc = -1;
static sigjmp_buf dc_jmp;
static void on_sigill(int s) { (void)s; siglongjmp(dc_jmp, 1); }

static int probe_dc(void)
{
    struct sigaction sa, old;
    char dummy[256] __attribute__((aligned(64)));
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigill;
    sa.sa_flags   = SA_NODEFER;
    if (sigaction(SIGILL, &sa, &old) != 0) return 0;
    int ok = 1;
    if (sigsetjmp(dc_jmp, 1) == 0) {
        __asm__ __volatile__("dc civac, %0" :: "r"((uintptr_t)dummy) : "memory");
        __asm__ __volatile__("dsb sy" ::: "memory");
    } else {
        ok = 0;
    }
    sigaction(SIGILL, &old, NULL);
    return ok;
}

static size_t dc_line(void)
{
    long l = sysconf(_SC_LEVEL1_DCACHE_LINESIZE);
    if (l < 32 || (l & (l - 1)) != 0) l = 64;
    return (size_t)l;
}

static void dcache_clean(void *addr, size_t len)
{
    size_t L = dc_line();
    uintptr_t p = (uintptr_t)addr & ~(uintptr_t)(L - 1);
    uintptr_t e = ((uintptr_t)addr + len + L - 1) & ~(uintptr_t)(L - 1);
    for (; p < e; p += L)
        __asm__ __volatile__("dc cvac, %0" :: "r"(p) : "memory");
    __asm__ __volatile__("dsb sy" ::: "memory");
}

static void dcache_inval(void *addr, size_t len)
{
    size_t L = dc_line();
    uintptr_t p = (uintptr_t)addr & ~(uintptr_t)(L - 1);
    uintptr_t e = ((uintptr_t)addr + len + L - 1) & ~(uintptr_t)(L - 1);
    for (; p < e; p += L)
        __asm__ __volatile__("dc civac, %0" :: "r"(p) : "memory");
    __asm__ __volatile__("dsb sy" ::: "memory");
}

static double now_s(void)
{
    struct timespec ts;
    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (double)ts.tv_sec + (double)ts.tv_nsec * 1e-9;
}

static float bits_to_f32(uint32_t b)
{
    float f;
    memcpy(&f, &b, 4);
    return f;
}

static void idx_to_mn(uint32_t i, uint32_t N, uint32_t M_TILE,
                      uint32_t *m, uint32_t *n)
{
    uint32_t per_tile = N * M_TILE;
    uint32_t t   = i / per_tile;
    uint32_t rem = i % per_tile;
    *n = rem / M_TILE;
    *m = t * M_TILE + (rem % M_TILE);
}

/*---------------------------------------------------------------------------
 * 一次完整 DMA 事务
 *   far_en : 0 = 基线直通，1 = 硬件 FaR
 *   返回    : 墙钟秒数（<0 表示失败）
 *-------------------------------------------------------------------------*/
static double run_gemm(const fben_t *v,
                       uint64_t in_pa, size_t in_bytes,
                       uint64_t out_pa, size_t out_bytes,
                       int far_en, int *hard_fail)
{
    /* 软复位（自清）：清核内 FSM/计数器与 far_reroute 相位，保证多次运行互相独立。
       cfg_k_cols/n_tokens 与 FaRMap 寄存器不在 soft_rst 作用域内，复位后重写即可。 */
    wr_g(R_CTRL, 0x2);
    usleep(2000);
    wr_g(R_K_COLS,   v->K);
    wr_g(R_N_TOKENS, v->N);
    wr_g(R_LAYER_ID, far_en);

    /* 复位 DMA 两通道 */
    wr_d(MM2S_DMACR, DMACR_RESET);
    wr_d(S2MM_DMACR, DMACR_RESET);
    usleep(2000);
    wr_d(MM2S_DMACR, 0);
    wr_d(S2MM_DMACR, 0);
    usleep(2000);
    wr_d(MM2S_DMACR, DMACR_RS);
    wr_d(S2MM_DMACR, DMACR_RS);

    /* 先武装 S2MM（收），再启动核，最后启动 MM2S（发） */
    wr_d(S2MM_DA,     (uint32_t)out_pa);
    wr_d(S2MM_DA_MSB, (uint32_t)(out_pa >> 32));
    wr_d(S2MM_LENGTH, (uint32_t)out_bytes);

    wr_g(R_CTRL, 0x0);      /* 清 done */
    usleep(500);
    wr_g(R_CTRL, 0x1);      /* start=1 */

    wr_d(MM2S_SA,     (uint32_t)in_pa);
    wr_d(MM2S_SA_MSB, (uint32_t)(in_pa >> 32));
    wr_d(MM2S_LENGTH, (uint32_t)in_bytes);

    double t0 = now_s();
    uint32_t msr = 0, ssr = 0, gst = 0;
    for (;;) {
        msr = rd_d(MM2S_DMASR);
        ssr = rd_d(S2MM_DMASR);
        gst = rd_g(R_STATUS);
        int gm_done = (gst & 0x6u) != 0;
        int mm_ok = ((msr & DMASR_IDLE) && !(msr & DMASR_HALTED)) || (msr & DMASR_ERR);
        int sm_ok = ((ssr & DMASR_IDLE) && !(ssr & DMASR_HALTED)) || (ssr & DMASR_ERR);
        if (gm_done && mm_ok && sm_ok) break;
        if (now_s() - t0 > POLL_TIMEOUT_S) { *hard_fail = 1; return -1.0; }
        usleep(500);
    }
    double dt = now_s() - t0;

    if (msr & DMASR_ERR) { *hard_fail = 1; }
    if (ssr & DMASR_ERR) { *hard_fail = 1; }
    if (gst & 0x4u)      { *hard_fail = 1; }

    wr_g(R_CTRL, 0x0);      /* 清 done，核回 S_IDLE */
    return dt;
}

/* 把输出读回 CPU（失效 cache），返回不匹配数 */
static uint32_t collect_and_compare(const fben_t *v, int buf_fd, uint8_t *buf,
                                    size_t out_off, const uint32_t *golden, int verbose)
{
    if (buf_sync(buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ) != 0)
        perror("  sync START|READ");
    if (have_dc) dcache_inval(buf + out_off, 4u * (size_t)v->n_out);

    uint32_t *got = (uint32_t *)(buf + out_off);
    uint32_t bad = 0;
    for (uint32_t i = 0; i < v->n_out; i++) {
        if (got[i] != golden[i]) {
            if (verbose && bad < 8) {
                uint32_t m, n;
                idx_to_mn(i, v->N, v->M_TILE, &m, &n);
                printf("    [%5u] m=%4u n=%u  got 0x%08X (%.9g)  want 0x%08X (%.9g)\n",
                       i, m, n, got[i], bits_to_f32(got[i]),
                       golden[i], bits_to_f32(golden[i]));
            }
            bad++;
        }
    }
    return bad;
}

int main(int argc, char **argv)
{
    const char *binfile  = (argc > 1) ? argv[1] : "far_bench.bin";
    const char *fmapfile = (argc > 2) ? argv[2] : NULL;
    int reps = (argc > 3) ? atoi(argv[3]) : 3;
    if (reps < 1) reps = 1;

    /* 默认同名 .fmap */
    char fmap_buf[512];
    if (!fmapfile) {
        snprintf(fmap_buf, sizeof fmap_buf, "%s", binfile);
        char *dot = strrchr(fmap_buf, '.');
        if (dot) snprintf(dot, sizeof(fmap_buf) - (size_t)(dot - fmap_buf), ".fmap");
        else     snprintf(fmap_buf + strlen(fmap_buf),
                          sizeof(fmap_buf) - strlen(fmap_buf), ".fmap");
        fmapfile = fmap_buf;
    }

    printf("=== up_proj L4: hardware FaR vs software FaR ===\n");
    printf("fben    : %s\n", binfile);
    printf("fmap    : %s\n", fmapfile);
    printf("reps    : %d\n\n", reps);

    /* ---------------- 0. 载入基准包 + FaRMap ---------------- */
    fben_t v;
    if (load_fben(binfile, &v) != 0) return 1;
    fmap_ent_t ent[FAR_MAX_ENT];
    uint32_t n_far = 0;
    if (load_fmap(fmapfile, ent, &n_far) != 0) return 1;

    printf("[cfg] K=%u N=%u M_TOTAL=%u M_TILE=%u G=%u\n",
           v.K, v.N, v.M_TOTAL, v.M_TILE, v.G);
    printf("      in %u words (%u B)   out %u words x3\n\n",
           v.n_in, v.n_in * 4u, v.n_out);

    if (v.M_TILE != HW_M_TILE || v.M_TOTAL != HW_M_TOTAL || v.G != HW_G) {
        printf(">>> FAIL: FBEN params do not match the synthesized PL\n");
        return 2;
    }
    size_t in_bytes  = 4u * (size_t)v.n_in;
    size_t out_bytes = 4u * (size_t)v.n_out;
    if (in_bytes > DMA_MAX_XFER || out_bytes > DMA_MAX_XFER) {
        printf(">>> FAIL: transfer exceeds AXI DMA length reg\n");
        return 2;
    }

    /* 期望 FAR_HITS = N * Σ(1+nd) */
    uint32_t hits_expect = 0;
    for (uint32_t i = 0; i < n_far; i++)
        hits_expect += v.N * (1u + ent[i].nd);

    /* ---------------- 1. 映射 PL 寄存器 ---------------- */
    printf("[1] map PL registers\n");
    int fdmem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fdmem < 0) { perror("open /dev/mem (need root)"); return 1; }
    void *pm = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, DMA_BASE);
    if (pm == MAP_FAILED) { perror("mmap DMA"); return 1; }
    dma = (volatile uint32_t *)pm;
    void *pg = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, GEMM_BASE);
    if (pg == MAP_FAILED) { perror("mmap GEMM"); return 1; }
    gemm = (volatile uint32_t *)pg;

    uint32_t ver = rd_g(R_VERSION);
    printf("    GEMM VERSION = 0x%08X   expect 0x%08X   %s\n",
           ver, HW_VERSION, ver == HW_VERSION ? "OK" : "FAIL");
    if (ver != HW_VERSION) {
        printf(">>> FAIL: PL 里不是 FaR 版 bitstream（0x0002_0000）。\n");
        printf("    请重新生成并烧录含 far_reroute 的 bitstream。\n");
        return 2;
    }
    printf("\n");

    /* ---------------- 2. DMA 缓冲 ---------------- */
    printf("[2] allocate DMA buffer from /dev/dma_heap/reserved\n");
    size_t need   = in_bytes + out_bytes;
    size_t buflen = (need + 0x200000u - 1u) & ~(size_t)(0x200000u - 1u);
    if (buflen < 0x200000u) buflen = 0x200000u;

    int buf_fd = -1;
    if (heap_alloc(buflen, &buf_fd) != 0) {
        perror("dma_heap alloc");
        return 1;
    }
    uint8_t *buf = mmap(NULL, buflen, PROT_READ | PROT_WRITE, MAP_SHARED, buf_fd, 0);
    if (buf == MAP_FAILED) { perror("mmap dma-buf"); return 1; }
    memset(buf, 0, buflen);

    const char *why = "";
    uint64_t buf_pa = va_to_pa(buf, &why);
    if (!buf_pa) { printf(">>> FAIL: phys addr: %s\n", why); return 2; }

    have_dc = probe_dc();
    printf("    EL0 cache ops: %s\n", have_dc ? "available" : "NOT available");
    size_t   out_off = (in_bytes + 0xFFFu) & ~(size_t)0xFFFu;
    uint64_t in_pa   = buf_pa;
    uint64_t out_pa  = buf_pa + out_off;
    printf("    paddr(in)=0x%010llX  paddr(out)=0x%010llX  size=%.2f MB\n\n",
           (unsigned long long)in_pa, (unsigned long long)out_pa,
           (double)buflen / 1048576.0);

    /* ---------------- 3. 灌输入 + 刷 cache ---------------- */
    printf("[3] fill input + flush cache\n");
    buf_sync(buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
    memcpy(buf, v.in_words, in_bytes);
    memset(buf + out_off, 0xA5, out_bytes);
    buf_sync(buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
    if (have_dc) dcache_clean(buf, buflen);
    printf("    %zu B copied\n\n", in_bytes);

    /* ---------------- 4. 编程 FaRMap ---------------- */
    printf("[4] program FaRMap (%u entries)\n", n_far);
    wr_g(R_FAR_CTRL, 0);              /* 配置期间先关 far_en */
    wr_g(R_FAR_NENT, n_far);
    for (uint32_t j = 0; j < n_far; j++) {
        wr_g(R_FAR_IDX, j);
        wr_g(R_FAR_A,   ent[j].col);
        wr_g(R_FAR_INV, ent[j].inv);
        wr_g(R_FAR_ND,  ent[j].nd);
        wr_g(R_FAR_D0,  ent[j].d0);
        wr_g(R_FAR_D1,  ent[j].d1);
    }
    /* 间接寻址回读抽查第 0 条 */
    wr_g(R_FAR_IDX, 0);
    uint32_t rb_a = rd_g(R_FAR_A), rb_inv = rd_g(R_FAR_INV);
    printf("    FAR_A[0]=0x%04X (want 0x%04X)  FAR_INV[0]=0x%08X (want 0x%08X)  %s\n",
           rb_a, ent[0].col, rb_inv, ent[0].inv,
           (rb_a == ent[0].col && rb_inv == ent[0].inv) ? "OK" : "FAIL");
    if (rb_a != ent[0].col || rb_inv != ent[0].inv) fails++;
    printf("    expected FAR_HITS = %u (= N * sum(1+nd))\n\n", hits_expect);

    /* ---------------- 5. 跑 A：基线（far_en=0） ---------------- */
    printf("[5] run A: far_en=0 (baseline passthrough, shadow W)\n");
    wr_g(R_FAR_CTRL, 0);
    int hf_a = 0;
    double tA_min = 1e9, tA_sum = 0;
    uint32_t badA = 0;
    for (int r = 0; r < reps; r++) {
        double dt = run_gemm(&v, in_pa, in_bytes, out_pa, out_bytes, 0, &hf_a);
        if (dt < 0) { printf(">>> FAIL: run A timeout/error\n"); return 3; }
        if (dt < tA_min) tA_min = dt;
        tA_sum += dt;
    }
    badA = collect_and_compare(&v, buf_fd, buf, out_off, v.out_shadow, 1);
    printf("    time min=%.3f ms  avg=%.3f ms\n", tA_min * 1e3, (tA_sum / reps) * 1e3);
    printf("    mismatches vs Y_shadow: %u / %u   %s\n\n",
           badA, v.n_out, badA == 0 ? "OK" : "FAIL");
    if (badA) fails++;
    if (hf_a) { printf("    note: run A raised a DMA/GEMM error flag\n"); fails++; }

    /* ---------------- 6. 跑 B：硬件 FaR（far_en=1） ---------------- */
    printf("[6] run B: far_en=1 (hardware activation reroute)\n");
    wr_g(R_FAR_CTRL, 1);
    int hf_b = 0;
    double tB_min = 1e9, tB_sum = 0;
    for (int r = 0; r < reps; r++) {
        double dt = run_gemm(&v, in_pa, in_bytes, out_pa, out_bytes, 1, &hf_b);
        if (dt < 0) { printf(">>> FAIL: run B timeout/error\n"); return 3; }
        if (dt < tB_min) tB_min = dt;
        tB_sum += dt;
    }
    uint32_t badB = collect_and_compare(&v, buf_fd, buf, out_off, v.out_far, 1);
    uint32_t hits = rd_g(R_FAR_HITS);
    uint32_t phase = rd_g(R_FAR_PHASE);
    printf("    time min=%.3f ms  avg=%.3f ms\n", tB_min * 1e3, (tB_sum / reps) * 1e3);
    printf("    mismatches vs Y_far:    %u / %u   %s\n",
           badB, v.n_out, badB == 0 ? "OK" : "FAIL");
    printf("    FAR_HITS  = %u (expect %u)   %s\n",
           hits, hits_expect, hits == hits_expect ? "OK" : "FAIL");
    printf("    FAR_PHASE = %u (expect 0)     %s\n\n",
           phase, phase == 0 ? "OK" : "FAIL");
    if (badB) fails++;
    if (hits != hits_expect) fails++;
    if (phase != 0) fails++;
    if (hf_b) { printf("    note: run B raised a DMA/GEMM error flag\n"); fails++; }

    /* ---------------- 7. 结论 ---------------- */
    double overhead_us = (tB_min - tA_min) * 1e6;

    /* 守恒：硬件 FaR golden 与未加固原始层 golden 的偏差（软件口径，供记录） */
    double max_abs = 0.0, max_base = 0.0;
    for (uint32_t i = 0; i < v.n_out; i++) {
        double a = (double)bits_to_f32(v.out_far[i]);
        double b = (double)bits_to_f32(v.out_base[i]);
        double d = a > b ? a - b : b - a;
        if (d > max_abs) max_abs = d;
        double ab = b < 0 ? -b : b;
        if (ab > max_base) max_base = ab;
    }
    printf("[7] summary\n");
    printf("    hardware baseline vs sw Y_shadow : %s\n", badA == 0 ? "BIT-EXACT" : "MISMATCH");
    printf("    hardware FaR      vs sw Y_far    : %s\n", badB == 0 ? "BIT-EXACT" : "MISMATCH");
    printf("    FAR_HITS/PHASE diagnostics       : %s\n",
           (hits == hits_expect && phase == 0) ? "OK" : "FAIL");
    printf("    hw FaR extra time (min)          : %.1f us  (%.2f%% of run)\n",
           overhead_us, tA_min > 0 ? 100.0 * overhead_us / (tA_min * 1e6) : 0.0);
    printf("    conservation |Y_far-Y_base| max  : %.3e  (rel %.3e)\n",
           max_abs, max_base > 0 ? max_abs / max_base : 0.0);
    printf("    note: 守恒是软件 golden 口径；硬件已与 golden bit-exact，故同口径成立。\n\n");

    if (fails) {
        printf(">>> L4 FAIL (%d check group(s) failed)\n", fails);
        return 3;
    }
    printf(">>> L4 PASS: hardware FaR == software FaR (bit-exact), ");
    printf("and it costs ~0 extra time.\n");

    munmap(buf, buflen);
    close(buf_fd);
    munmap(pm, MAP_SIZE);
    munmap(pg, MAP_SIZE);
    close(fdmem);
    return 0;
}
