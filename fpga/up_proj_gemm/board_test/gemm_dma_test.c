/*
 * gemm_dma_test.c -- up_proj GEMM 端到端 DMA 验证 (L3)
 *
 * 目标：把 tools/gen_golden_vectors.py 生成的激励包（--bin 输出）灌进 PL，
 *       跑完一次完整 GEMM，再把 PL 吐出的 Y 与 Python golden 逐 bit 比对。
 *
 * 通路：  DDR(CMA) --AXI DMA MM2S--> gemm_up_proj_bd/s_axis
 *         gemm_up_proj_bd/m_axis --AXI DMA S2MM--> DDR(CMA)
 *         控制/状态走 AXI-Lite (0xA0010000)
 *
 * 地址（Vivado Address Editor）：
 *   axi_dma_0/S_AXI_LITE     0xA0000000 / 64K   (Simple 模式, PG021)
 *   gemm_up_proj_bd_0/S_AXI  0xA0010000 / 64K
 *
 * 为什么用 /dev/dma_heap/reserved：
 *   PL 侧的裸 AXI DMA 需要"物理连续 + 物理地址"的缓冲区。板上没有
 *   u-dma-buf / dma-proxy 模块，但内核开了 CMA (cma=1200M) 并注册了
 *   dma-heap。流程是：
 *     open /dev/dma_heap/reserved -> ioctl(ALLOC) 拿 dma-buf fd
 *     -> mmap 拿虚拟地址 -> 读 /proc/self/pagemap 反查物理地址
 *   缓存一致性：CMA 页在用户态是 cached 映射，而 PL 的裸 AXI DMA 不参与
 *   cache 一致性。常规做法是 DMA_BUF_IOCTL_SYNC：
 *     写输入后  SYNC_END|WRITE   刷 cache 给设备看
 *     读输出前  SYNC_START|READ  使 cache 失效，读到 DMA 写回的新数据
 *   但若内核把 dma-heap 设备判为 coherent（dma_default_coherent），该 ioctl
 *   会退化成 no-op，CPU 就一直读自己的脏行、写出的数据也到不了 DRAM。
 *   所以这里额外用 EL0 的 DC CVAC / DC CIVAC 自己维护一遍，
 *   见下方 dcache_clean / dcache_inval。
 *
 * 编译：gcc -O2 -o gemm_dma_test gemm_dma_test.c
 * 运行：sudo ./gemm_dma_test gemm_vectors.bin [dump_out.bin]
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
 * dma-heap / dma-buf 用户态 ABI
 * 优先用系统头；老镜像没有这些头时用等价的内联定义（结构与 ioctl 号一致）
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

/* 内核 uapi 里的宏名是 DMA_HEAP_IOCTL_ALLOC，不是 DMA_HEAP_IOC_ALLOC。
   两种拼法都兜住，免得跟着内核版本改来改去。 */
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
#define R_CTRL       0x00   /* W [0]start [1]soft_rst [2]irq_en      */
#define R_STATUS     0x04   /* R [0]busy [1]done [2]err [7:4]state   */
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

/* 与综合时锁死的参数比对（gemm_up_proj_core.sv 默认值） */
#define HW_M_TILE    16u
#define HW_M_TOTAL   3072u
#define HW_N_TILES   192u
#define HW_G         8u
#define HW_VERSION   0x00020000u        /* FaR 版：0x0001=纯 GEMM，0x0002=含 far_reroute */

/* AXI DMA 的 Buffer Length Register 位宽（BD: c_sg_length_width=26） */
#define DMA_MAX_XFER ((1UL << 26) - 1)

#define POLL_TIMEOUT_S 20.0

static volatile uint32_t *dma;
static volatile uint32_t *gemm;

static uint32_t rd_d(unsigned off)              { return dma[off >> 2]; }
static void     wr_d(unsigned off, uint32_t v) { dma[off >> 2] = v; }
static uint32_t rd_g(unsigned off)              { return gemm[off >> 2]; }
static void     wr_g(unsigned off, uint32_t v)  { gemm[off >> 2] = v; }

static int fails;

/*---------------------------------------------------------------------------
 * 激励包
 *-------------------------------------------------------------------------*/
typedef struct {
    uint32_t K, N, M_TOTAL, M_TILE, G, n_in, n_out;
    uint32_t *in_words;
    uint32_t *out_words;
} vec_t;

static int load_vectors(const char *path, vec_t *v)
{
    FILE *f = fopen(path, "rb");
    if (!f) { perror("fopen vectors"); return -1; }

    char magic[4];
    uint32_t h[7];
    if (fread(magic, 1, 4, f) != 4 || memcmp(magic, "GEMV", 4) != 0) {
        fprintf(stderr, "bad magic in %s (expect GEMV)\n", path);
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

    v->in_words  = malloc(4u * (size_t)v->n_in);
    v->out_words = malloc(4u * (size_t)v->n_out);
    if (!v->in_words || !v->out_words) {
        fprintf(stderr, "oom\n");
        fclose(f);
        return -1;
    }
    if (fread(v->in_words, 4, v->n_in, f) != v->n_in ||
        fread(v->out_words, 4, v->n_out, f) != v->n_out) {
        fprintf(stderr, "short payload in %s\n", path);
        fclose(f);
        return -1;
    }
    fclose(f);
    return 0;
}

/*---------------------------------------------------------------------------
 * CMA 缓冲区
 *-------------------------------------------------------------------------*/
static int heap_alloc(size_t len, int *out_fd)
{
    int hfd = open("/dev/dma_heap/reserved", O_RDWR | O_CLOEXEC);
    if (hfd < 0) return -1;

    struct dma_heap_allocation_data d;
    memset(&d, 0, sizeof d);
    d.len        = len;
    d.fd_flags   = O_RDWR | O_CLOEXEC;
    d.heap_flags = 0;

    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &d) < 0) {
        close(hfd);
        return -1;
    }
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

/* 虚拟地址 -> 物理地址（需 root；dma-buf 的 CMA 页是普通 RAM 页，
 * pagemap 能给出有效 PFN）。
 * 注意：pagemap 读的是页表，mmap 之后必须先把页 fault 进来（写一次），
 * 否则 present 位是 0，这里只会返回 0。失败原因通过 why 带出。 */
static uint64_t va_to_pa(const void *va, const char **why)
{
    int fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { *why = "open /proc/self/pagemap failed"; return 0; }

    uint64_t entry = 0;
    off_t off = (off_t)(((uintptr_t)va >> 12) * 8);
    ssize_t n = pread(fd, &entry, 8, off);
    close(fd);
    if (n != 8)                  { *why = "pread pagemap failed"; return 0; }
    if (!(entry & (1ULL << 63))) { *why = "page not present (not faulted in)"; return 0; }
    uint64_t pfn = entry & ((1ULL << 55) - 1);
    if (!pfn)                    { *why = "PFN zeroed by kernel (need CAP_SYS_ADMIN)"; return 0; }
    return (pfn << 12) | ((uintptr_t)va & 0xFFFULL);
}

/* CMA 分配本身保证物理连续，但地址算错不会报错、只会静默踩坏内存，
 * 所以抽查首/中/尾三页确认一遍。 */
static int check_contig(const uint8_t *buf, size_t len, uint64_t base, const char **why)
{
    size_t offs[3];
    offs[0] = 0;
    offs[1] = (len / 2) & ~(size_t)0xFFF;
    offs[2] = (len - 0x1000) & ~(size_t)0xFFF;

    for (int i = 0; i < 3; i++) {
        uint64_t pa = va_to_pa(buf + offs[i], why);
        if (!pa) return -1;
        if (pa != base + offs[i]) {
            *why = "buffer not physically contiguous";
            printf("    page @0x%08zX: pa=0x%010llX  expect 0x%010llX\n",
                   offs[i], (unsigned long long)pa,
                   (unsigned long long)(base + offs[i]));
            return -1;
        }
    }
    return 0;
}

/*---------------------------------------------------------------------------
 * cache 维护（不依赖内核的 dma-buf sync）
 *
 * arm64 的 EL0 允许执行 DC CVAC / DC CIVAC —— SCTLR_EL1.UCI，JIT 的
 * __clear_cache 就靠这一位。UCI 若被关掉会触发 SIGILL，用 sigsetjmp
 * 探一次，不可用就退回 ioctl。
 *-------------------------------------------------------------------------*/
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
    if (l < 32 || (l & (l - 1)) != 0) l = 64;   /* 不可信时按 A53 的 64B 用 */
    return (size_t)l;
}

/* 把 [addr, addr+len) 的脏行写回 PoC —— CPU 写完、设备读之前用 */
static void dcache_clean(void *addr, size_t len)
{
    size_t L = dc_line();
    uintptr_t p = (uintptr_t)addr & ~(uintptr_t)(L - 1);
    uintptr_t e = ((uintptr_t)addr + len + L - 1) & ~(uintptr_t)(L - 1);
    for (; p < e; p += L)
        __asm__ __volatile__("dc cvac, %0" :: "r"(p) : "memory");
    __asm__ __volatile__("dsb sy" ::: "memory");
}

/* 丢弃 [addr, addr+len) 的行，强制下次读回到 PoC —— 设备写完、CPU 读之前用。
   调用前必须保证这些行是干净的，否则会丢掉尚未写回的 CPU 数据。 */
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

/* 输出字下标 -> (m, n)，与 core 的输出布局契约一致 */
static void idx_to_mn(uint32_t i, uint32_t N, uint32_t M_TILE,
                      uint32_t *m, uint32_t *n)
{
    uint32_t per_tile = N * M_TILE;
    uint32_t t   = i / per_tile;
    uint32_t rem = i % per_tile;
    *n = rem / M_TILE;
    *m = t * M_TILE + (rem % M_TILE);
}

int main(int argc, char **argv)
{
    const char *vecfile = (argc > 1) ? argv[1] : "gemm_vectors.bin";
    const char *dumpfile = (argc > 2) ? argv[2] : NULL;

    printf("=== up_proj GEMM L3: DMA end-to-end vs golden ===\n");
    printf("vectors : %s\n\n", vecfile);

    /* ---------------- 0. 激励包 ---------------- */
    vec_t v;
    if (load_vectors(vecfile, &v) != 0) return 1;

    printf("[cfg] K=%u N=%u M_TOTAL=%u M_TILE=%u G=%u\n",
           v.K, v.N, v.M_TOTAL, v.M_TILE, v.G);
    printf("      in %u words (%u B)   out %u words (%u B)\n\n",
           v.n_in, v.n_in * 4u, v.n_out, v.n_out * 4u);

    if (v.M_TILE != HW_M_TILE || v.M_TOTAL != HW_M_TOTAL || v.G != HW_G) {
        printf(">>> FAIL: vector file params do not match the synthesized PL\n");
        printf("    PL is fixed at M_TILE=%u M_TOTAL=%u G=%u\n",
               HW_M_TILE, HW_M_TOTAL, HW_G);
        printf("    regenerate with: --m-tile %u --m-total %u --g %u\n",
               HW_M_TILE, HW_M_TOTAL, HW_G);
        return 2;
    }

    size_t in_bytes  = 4u * (size_t)v.n_in;
    size_t out_bytes = 4u * (size_t)v.n_out;
    if (in_bytes > DMA_MAX_XFER || out_bytes > DMA_MAX_XFER) {
        printf(">>> FAIL: single transfer exceeds AXI DMA length reg (%lu B)\n",
               DMA_MAX_XFER);
        printf("    in=%zu out=%zu\n", in_bytes, out_bytes);
        return 2;
    }

    /* ---------------- 1. 映射 PL 寄存器 ---------------- */
    printf("[1] map PL registers\n");
    int fdmem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fdmem < 0) { perror("open /dev/mem (need root)"); return 1; }

    void *pm = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fdmem, DMA_BASE);
    if (pm == MAP_FAILED) { perror("mmap DMA"); return 1; }
    dma = (volatile uint32_t *)pm;

    void *pg = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED,
                    fdmem, GEMM_BASE);
    if (pg == MAP_FAILED) { perror("mmap GEMM"); return 1; }
    gemm = (volatile uint32_t *)pg;

    uint32_t ver = rd_g(R_VERSION);
    printf("    GEMM VERSION = 0x%08X   expect 0x%08X   %s\n",
           ver, HW_VERSION, ver == HW_VERSION ? "OK" : "FAIL");
    if (ver != HW_VERSION) {
        printf(">>> FAIL: GEMM not responding. Check fpga_manager state = operating\n");
        return 2;
    }
    printf("    GEMM M_ROWS = %u   N_TILES = %u\n",
           rd_g(R_M_ROWS), rd_g(R_N_TILES));

    /* DMA 地址位宽探测：32 位地址的 IP 没有 SA_MSB 寄存器（读回 0） */
    wr_d(MM2S_SA_MSB, 0x12345678u);
    uint32_t msb_rb = rd_d(MM2S_SA_MSB);
    int dma64 = (msb_rb == 0x12345678u);
    wr_d(MM2S_SA_MSB, 0);
    printf("    DMA address width: %s\n", dma64 ? "64-bit" : "32-bit");
    printf("\n");

    /* ---------------- 2. CMA 缓冲区 ---------------- */
    printf("[2] allocate DMA buffer from /dev/dma_heap/reserved\n");
    size_t need   = in_bytes + out_bytes;
    size_t buflen = (need + 0x200000u - 1u) & ~(size_t)(0x200000u - 1u);
    if (buflen < 0x200000u) buflen = 0x200000u;

    int buf_fd = -1;
    if (heap_alloc(buflen, &buf_fd) != 0) {
        perror("dma_heap alloc (/dev/dma_heap/reserved)");
        printf("    check: ls /dev/dma_heap/  and  cat /proc/cmdline (needs cma=)\n");
        return 1;
    }
    uint8_t *buf = mmap(NULL, buflen, PROT_READ | PROT_WRITE, MAP_SHARED,
                        buf_fd, 0);
    if (buf == MAP_FAILED) { perror("mmap dma-buf"); return 1; }

    /* 先整段触摸一遍，把页表项 fault 出来，否则 pagemap 读到的是 not-present */
    memset(buf, 0, buflen);

    const char *why = "";
    uint64_t buf_pa = va_to_pa(buf, &why);
    if (!buf_pa) {
        printf(">>> FAIL: cannot resolve phys addr: %s\n", why);
        printf("    1) must run as root (sudo)\n");
        printf("    2) if still 0, use the u-dma-buf module (sysfs exposes phys_addr)\n");
        return 2;
    }
    if (check_contig(buf, buflen, buf_pa, &why) != 0) {
        printf(">>> FAIL: %s\n", why);
        return 2;
    }
    have_dc = probe_dc();
    printf("    EL0 cache ops (dc cvac/civac): %s\n",
           have_dc ? "available" : "NOT available");
    size_t   out_off = (in_bytes + 0xFFFu) & ~(size_t)0xFFFu;   /* 4K 对齐 */
    uint64_t in_pa   = buf_pa;
    uint64_t out_pa  = buf_pa + out_off;

    printf("    vaddr = %p\n", (void *)buf);
    printf("    paddr(in)  = 0x%010llX\n", (unsigned long long)in_pa);
    printf("    paddr(out) = 0x%010llX\n", (unsigned long long)out_pa);
    printf("    size  = %.2f MB\n", (double)buflen / 1048576.0);

    if (in_pa > 0xFFFFFFFFULL && !dma64) {
        printf(">>> FAIL: buffer phys addr > 4GB but AXI DMA is 32-bit addressed\n");
        printf("    fix: pin CMA below 2GB, e.g. kernel arg cma=1024M@0x30000000\n");
        return 2;
    }
    printf("\n");

    /* ---------------- 3. 灌输入 + 刷 cache ---------------- */
    printf("[3] fill input + flush cache\n");
    if (buf_sync(buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE) != 0)
        perror("  sync START|WRITE");
    memcpy(buf, v.in_words, in_bytes);
    memset(buf + out_off, 0xA5, out_bytes);      /* 先涂毒，便于识别未写入 */
    if (buf_sync(buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) != 0)
        perror("  sync END|WRITE");
    if (have_dc) dcache_clean(buf, buflen);      /* 上面两个 ioctl 可能是 no-op */
    printf("    %zu B copied, cache %s\n\n", in_bytes,
           have_dc ? "cleaned by hand" : "flushed via ioctl only");

    /* ---------------- 4. 配置 GEMM ---------------- */
    printf("[4] configure GEMM\n");
    wr_g(R_CTRL, 0x2);          /* soft_rst（自清） */
    usleep(2000);
    wr_g(R_K_COLS,   v.K);
    wr_g(R_N_TOKENS, v.N);
    wr_g(R_LAYER_ID, 0);
    printf("    K_COLS   write %u -> read %u   %s\n", v.K,
           rd_g(R_K_COLS), rd_g(R_K_COLS) == v.K ? "OK" : "FAIL");
    printf("    N_TOKENS write %u -> read %u   %s\n", v.N,
           rd_g(R_N_TOKENS), rd_g(R_N_TOKENS) == v.N ? "OK" : "FAIL");
    if (rd_g(R_K_COLS) != v.K || rd_g(R_N_TOKENS) != v.N) fails++;
    printf("\n");

    /* ---------------- 5. 复位 DMA，武装两通道 ---------------- */
    printf("[5] arm DMA + start GEMM\n");
    wr_d(MM2S_DMACR, DMACR_RESET);
    wr_d(S2MM_DMACR, DMACR_RESET);
    usleep(2000);
    wr_d(MM2S_DMACR, 0);
    wr_d(S2MM_DMACR, 0);
    usleep(2000);

    wr_d(MM2S_DMACR, DMACR_RS);
    wr_d(S2MM_DMACR, DMACR_RS);

    /* 先武装 S2MM（收），再启动核，最后启动 MM2S（发）：
       否则 GEMM 在 S_OUT 等不到 tready 会一直挂着 */
    wr_d(S2MM_DA,     (uint32_t)out_pa);
    wr_d(S2MM_DA_MSB, (uint32_t)(out_pa >> 32));
    wr_d(S2MM_LENGTH, (uint32_t)out_bytes);

    wr_g(R_CTRL, 0x1);          /* start=1（电平） */

    wr_d(MM2S_SA,     (uint32_t)in_pa);
    wr_d(MM2S_SA_MSB, (uint32_t)(in_pa >> 32));
    wr_d(MM2S_LENGTH, (uint32_t)in_bytes);

    printf("    S2MM DA=0x%010llX LEN=%zu\n",
           (unsigned long long)out_pa, out_bytes);
    printf("    MM2S SA=0x%010llX LEN=%zu\n",
           (unsigned long long)in_pa, in_bytes);
    printf("\n");

    /* ---------------- 6. 等完成 ---------------- */
    printf("[6] wait for completion ...\n");
    double t0 = now_s();
    uint32_t msr = 0, ssr = 0, gst = 0;
    int timed_out = 0;

    for (;;) {
        msr = rd_d(MM2S_DMASR);
        ssr = rd_d(S2MM_DMASR);
        gst = rd_g(R_STATUS);

        /* 完成判据以 GEMM done/err 为主：核跑完就说明两路 DMA 都已收工
           （最后一批输入在末趟 S_LOAD_W 被吃光，最后一批输出在 S_OUT 被收走）。
           DMA 侧用 Idle 而不是 IOC 位，避免依赖 IOC 状态位的使能方式。 */
        int gm_done = (gst & 0x6u) != 0;                     /* done | err */
        int mm_ok   = ((msr & DMASR_IDLE) && !(msr & DMASR_HALTED))
                      || (msr & DMASR_ERR);
        int sm_ok   = ((ssr & DMASR_IDLE) && !(ssr & DMASR_HALTED))
                      || (ssr & DMASR_ERR);

        if (gm_done && mm_ok && sm_ok) break;

        if (now_s() - t0 > POLL_TIMEOUT_S) { timed_out = 1; break; }
        usleep(1000);
    }
    double dt = now_s() - t0;

    printf("    elapsed %.1f ms%s\n", dt * 1e3, timed_out ? "  (TIMEOUT)" : "");
    printf("    MM2S_DMASR = 0x%08X  Halted=%u Idle=%u IOC=%u Err=0x%X\n",
           msr, msr & 1u, (msr >> 1) & 1u, (msr >> 12) & 1u, msr & DMASR_ERR);
    printf("    S2MM_DMASR = 0x%08X  Halted=%u Idle=%u IOC=%u Err=0x%X\n",
           ssr, ssr & 1u, (ssr >> 1) & 1u, (ssr >> 12) & 1u, ssr & DMASR_ERR);
    printf("    GEMM STATUS= 0x%08X  busy=%u done=%u err=%u state=%u\n",
           gst, gst & 1u, (gst >> 1) & 1u, (gst >> 2) & 1u, (gst >> 4) & 0xFu);
    printf("    IN_WORDS = %u (expect %u)\n", rd_g(R_IN_WORDS), v.n_in);
    printf("    OUT_WORDS= %u (expect %u)\n", rd_g(R_OUT_WORDS), v.n_out);
    printf("    TILE_IDX = %u (expect %u)\n", rd_g(R_TILE_IDX), HW_N_TILES - 1);
    printf("    GEMM STATE=%u\n", rd_g(R_STATE));
    printf("\n");

    int hard_fail = 0;
    if (timed_out) { printf(">>> TIMEOUT: transfer did not complete\n"); hard_fail = 1; }
    if (msr & DMASR_ERR) { printf(">>> MM2S error (DMASR=0x%08X)\n", msr); hard_fail = 1; }
    if (ssr & DMASR_ERR) { printf(">>> S2MM error (DMASR=0x%08X)\n", ssr); hard_fail = 1; }
    if (gst & 0x4u) {
        printf(">>> GEMM err=1: in_cnt != in_total, or last beat had no tlast\n");
        hard_fail = 1;
    }

    /* 清 done，让核回 S_IDLE */
    wr_g(R_CTRL, 0x0);

    /* ---------------- 7. 读回输出并比对 ---------------- */
    printf("[7] compare Y against golden\n");

    /* 先按当前 cache 内容看一眼，再失效后看一眼：两者不同就坐实了
       "ioctl 没起作用、CPU 一直读自己的脏行"。 */
    uint32_t peek_cached = ((volatile uint32_t *)(buf + out_off))[0];

    if (buf_sync(buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ) != 0)
        perror("  sync START|READ");
    if (have_dc) dcache_inval(buf + out_off, out_bytes);

    uint32_t peek_dram = ((volatile uint32_t *)(buf + out_off))[0];
    printf("    Y[0]: cached view = 0x%08X   after invalidate = 0x%08X%s\n",
           peek_cached, peek_dram,
           (peek_cached != peek_dram) ? "   <== cache incoherence CONFIRMED" : "");

    uint32_t *got = (uint32_t *)(buf + out_off);
    uint32_t bad = 0;
    uint32_t ulp_max = 0;
    const uint32_t SHOW = 8;

    for (uint32_t i = 0; i < v.n_out; i++) {
        if (got[i] != v.out_words[i]) {
            if (bad < SHOW) {
                uint32_t m, n;
                idx_to_mn(i, v.N, v.M_TILE, &m, &n);
                printf("    [%5u] m=%4u n=%u  got 0x%08X (%.9g)  "
                       "want 0x%08X (%.9g)\n",
                       i, m, n, got[i], bits_to_f32(got[i]),
                       v.out_words[i], bits_to_f32(v.out_words[i]));
            } else if (bad == SHOW) {
                printf("    ... (more mismatches suppressed)\n");
            }
            bad++;
            uint32_t d = got[i] > v.out_words[i] ? got[i] - v.out_words[i]
                                                 : v.out_words[i] - got[i];
            if (d > ulp_max) ulp_max = d;
        }
    }
    buf_sync(buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);

    if (dumpfile) {
        FILE *fo = fopen(dumpfile, "wb");
        if (fo) {
            fwrite(got, 4, v.n_out, fo);
            fclose(fo);
            printf("    raw Y dumped to %s (%u B)\n", dumpfile, v.n_out * 4u);
        }
    }

    printf("    mismatches: %u / %u\n", bad, v.n_out);
    if (bad) printf("    max |bit-pattern| distance: %u\n", ulp_max);
    printf("\n");

    /* ---------------- 8. 结论 ---------------- */
    if (hard_fail || bad || fails) {
        printf(">>> L3 FAIL\n");
        if (bad && !hard_fail) {
            printf("    PL produced output but values differ. Check:\n");
            printf("    1) accum order contract: G=%u, ADD_LAT=4, MUL_LAT=8 vs RTL\n",
                   v.G);
            printf("    2) weight tile order: pass t uses W[t*M_TILE .. +M_TILE)[*]\n");
            printf("    3) vector file came from the same gen_golden_vectors.py\n");
        }
        return 3;
    }

    printf(">>> L3 PASS: %u/%u output words bit-exact vs Python golden\n",
           v.n_out, v.n_out);
    printf("    GEMM datapath + DMA path + accumulation order all correct.\n");

    munmap(buf, buflen);
    close(buf_fd);
    munmap(pm, MAP_SIZE);
    munmap(pg, MAP_SIZE);
    close(fdmem);
    return 0;
}
