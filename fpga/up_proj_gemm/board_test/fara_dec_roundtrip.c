/*
 * fara_dec_roundtrip.c -- provisioning round-trip 验证（供板模式）
 *
 * 目的：在冻结比特流上，验证 PUF -> FE -> KDF -> key_mgr -> AES-256-CTR
 *       整条密钥/解密链在真实冷启动响应下工作正常。
 *
 * 通路（route_mode=1 供板模式，绕开 GEMM）：
 *   DDR(CMA) --AXI DMA MM2S--> puf_dec_bd/s_axis ([X|b|W_enc] 拼接流)
 *            --wdec: X/b 直通, W 经 AES-CTR--> axis_route2(mode=1) --> S2MM --> DDR
 *   CPU 比对收到的 [X|b|W_dec] 与明文 [X|b|W]。
 *
 * 前置：
 *   1) fara-bitstream.service 已加载冻结比特流（GEMM VERSION=0x00020000）
 *   2) PC 端 enroll_gen.py 已产出 fara_dec_config.txt（mask/helper/k/salt/purpose/
 *      nonce/ctr_init/plain_words），weight_encrypt.py 已产出 W_enc.bin（nonce 一致）
 *
 * 激励文件（同目录）：
 *   fara_dec_config.txt   key=value 文本（ASCII）
 *   b.bin                 3072 words 明文 b（12,288 B）
 *   W_enc.bin             2,359,296 words 密文 W（9,437,184 B）
 *   W.bin                 2,359,296 words 明文 W（比对基准）
 *   X 段由本程序用 0xC0DEC0DE pattern 生成（768 words，验证直通）
 *
 * 编译：gcc -O2 -o fara_dec_roundtrip fara_dec_roundtrip.c
 * 运行：sudo ./fara_dec_roundtrip
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
#include <signal.h>
#include <setjmp.h>

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
struct dma_buf_sync { uint64_t flags; };
#define DMA_BUF_SYNC_READ  (1 << 0)
#define DMA_BUF_SYNC_WRITE (2 << 0)
#define DMA_BUF_SYNC_START (0 << 2)
#define DMA_BUF_SYNC_END   (1 << 2)
#define DMA_BUF_BASE 'b'
#define DMA_BUF_IOCTL_SYNC _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync)
#endif

/*---------------------------------------------------------------------------
 * 地址映射
 *-------------------------------------------------------------------------*/
#define DMA_BASE     0xA0000000UL
#define DEC_BASE     0xA0020000UL
#define MAP_SIZE     0x10000UL

/* ---- AXI DMA Simple 模式 (PG021) ---- */
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
#define DMASR_ERR     ((1u << 4) | (1u << 5) | (1u << 6) | \
                       (1u << 8) | (1u << 9) | (1u << 10) | (1u << 14))

/* ---- puf_dec AXI-Lite 寄存器 (puf_dec_axi_lite.sv) ---- */
#define D_CTRL        0x00   /* [0]fe_start [2]soft_rst [3]ctr_load [4]dbg_use_sw_resp */
#define D_STATUS      0x04   /* [0]fe_busy [1]fe_done [2]fe_err [3]kdf_busy
                                 [4]kdf_done [5]key_locked [6]aes_key_ready
                                 [7]route_mode [15:8]fe_k_used */
#define D_VERSION     0x08
#define D_CTRL2       0x0C   /* [0]route_mode [1]sw_key_load */
#define D_MASK0       0x10   /* 0x10..0x1C */
#define D_FE_K        0x20
#define D_SALT0       0x24   /* 0x24..0x30 */
#define D_PURP0       0x34   /* 0x34..0x40 */
#define D_NONCE0      0x44   /* 0x44..0x4C */
#define D_CTR_INIT    0x50
#define D_PLAIN_WORDS 0x54
#define D_HELP0       0x88   /* 0x88..0x94 */

#define DEC_VERSION   0x00030000u

#define K_WORDS       768u           /* X: N=1, K=768 */
#define B_WORDS       3072u          /* b: M_TOTAL */
#define W_WORDS       2359296u       /* W: 3072*768 */
#define PLAIN_WORDS   (K_WORDS + B_WORDS)
#define IN_BYTES      ((K_WORDS + B_WORDS + W_WORDS) * 4u)

#define DMA_MAX_XFER  ((1UL << 26) - 1)
#define FE_TIMEOUT_S  2.0
#define DMA_TIMEOUT_S 30.0

static volatile uint32_t *dma;
static volatile uint32_t *dec;

static uint32_t rd_d(unsigned off)             { return dma[off >> 2]; }
static void     wr_d(unsigned off, uint32_t v) { dma[off >> 2] = v; }
static uint32_t rd_c(unsigned off)             { return dec[off >> 2]; }
static void     wr_c(unsigned off, uint32_t v) { dec[off >> 2] = v; }

/*---------------------------------------------------------------------------
 * config：key=value 文本，128-bit 大数按“最高字在前”的 32-hex 书写
 * （与采样行/JSON 同一口径）。NONCE 为 12 字节 24-hex，文件序 b0..b11。
 *-------------------------------------------------------------------------*/
typedef struct {
    uint32_t mask[4];      /* [0]=cfg_mask[31:0] .. [3]=cfg_mask[127:96] */
    uint32_t helper[4];
    uint32_t k;
    uint32_t salt[4];
    uint32_t purpose[4];
    uint8_t  nonce[12];
    uint32_t ctr_init;
    uint32_t plain_words;
    uint32_t route_mode;
} cfg_t;

static uint32_t hex_word(const char *s)   /* 8 个 hex 字符 -> u32 */
{
    uint32_t v = 0;
    for (int i = 0; i < 8; i++) {
        char c = s[i];
        v <<= 4;
        if (c >= '0' && c <= '9')      v |= (uint32_t)(c - '0');
        else if (c >= 'a' && c <= 'f') v |= (uint32_t)(c - 'a' + 10);
        else if (c >= 'A' && c <= 'F') v |= (uint32_t)(c - 'A' + 10);
        else { fprintf(stderr, "bad hex char '%c'\n", c); exit(2); }
    }
    return v;
}

/* 32-hex 的 128-bit 大数：文件序最高字在前 -> words[3]=最高字 */
static void parse_w128(const char *s, uint32_t words[4])
{
    words[3] = hex_word(s +  0);
    words[2] = hex_word(s +  8);
    words[1] = hex_word(s + 16);
    words[0] = hex_word(s + 24);
}

static int load_cfg(const char *path, cfg_t *c)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror("open config"); return -1; }
    char line[512];
    int have = 0, need = 9;
    while (fgets(line, sizeof line, f)) {
        char *nl = strchr(line, '\n'); if (nl) *nl = 0;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        const char *k = line, *v = eq + 1;
        if      (!strcmp(k, "MASK"))        { parse_w128(v, c->mask);        have++; }
        else if (!strcmp(k, "HELPER"))      { parse_w128(v, c->helper);      have++; }
        else if (!strcmp(k, "K"))           { c->k = (uint32_t)strtoul(v, 0, 0);  have++; }
        else if (!strcmp(k, "SALT"))        { parse_w128(v, c->salt);        have++; }
        else if (!strcmp(k, "PURPOSE"))     { parse_w128(v, c->purpose);     have++; }
        else if (!strcmp(k, "NONCE")) {
            if (strlen(v) != 24) { fprintf(stderr, "NONCE needs 24 hex\n"); return -1; }
            for (int i = 0; i < 12; i++) {
                char t[3] = { v[2*i], v[2*i+1], 0 };
                c->nonce[i] = (uint8_t)strtoul(t, 0, 16);
            }
            have++;
        }
        else if (!strcmp(k, "CTR_INIT"))    { c->ctr_init = (uint32_t)strtoul(v, 0, 0); have++; }
        else if (!strcmp(k, "PLAIN_WORDS")) { c->plain_words = (uint32_t)strtoul(v, 0, 0); have++; }
        else if (!strcmp(k, "ROUTE_MODE"))  { c->route_mode = (uint32_t)strtoul(v, 0, 0); have++; }
    }
    fclose(f);
    if (have != need) { fprintf(stderr, "config: %d/%d keys\n", have, need); return -1; }
    return 0;
}

/*---------------------------------------------------------------------------
 * CMA / cache（与 gemm_dma_test.c 相同的实现）
 *-------------------------------------------------------------------------*/
static int heap_alloc(size_t len, int *out_fd)
{
    int hfd = open("/dev/dma_heap/reserved", O_RDWR | O_CLOEXEC);
    if (hfd < 0) return -1;
    struct dma_heap_allocation_data d;
    memset(&d, 0, sizeof d);
    d.len = len; d.fd_flags = O_RDWR | O_CLOEXEC;
    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &d) < 0) { close(hfd); return -1; }
    close(hfd);
    *out_fd = (int)d.fd;
    return 0;
}

static int buf_sync(int fd, uint64_t flags)
{
    struct dma_buf_sync s; s.flags = flags;
    return ioctl(fd, DMA_BUF_IOCTL_SYNC, &s);
}

static uint64_t va_to_pa(const void *va, const char **why)
{
    int fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { *why = "open pagemap failed"; return 0; }
    uint64_t entry = 0;
    off_t off = (off_t)(((uintptr_t)va >> 12) * 8);
    ssize_t n = pread(fd, &entry, 8, off);
    close(fd);
    if (n != 8)                  { *why = "pread failed"; return 0; }
    if (!(entry & (1ULL << 63))) { *why = "page not present"; return 0; }
    uint64_t pfn = entry & ((1ULL << 55) - 1);
    if (!pfn)                    { *why = "PFN hidden (need root)"; return 0; }
    return (pfn << 12) | ((uintptr_t)va & 0xFFFULL);
}

static int check_contig(const uint8_t *buf, size_t len, uint64_t base, const char **why)
{
    size_t offs[3] = { 0, (len / 2) & ~(size_t)0xFFF, (len - 0x1000) & ~(size_t)0xFFF };
    for (int i = 0; i < 3; i++) {
        uint64_t pa = va_to_pa(buf + offs[i], why);
        if (!pa || pa != base + offs[i]) return -1;
    }
    return 0;
}

static int have_dc = -1;
static sigjmp_buf dc_jmp;
static void on_sigill(int s) { (void)s; siglongjmp(dc_jmp, 1); }

static int probe_dc(void)
{
    struct sigaction sa, old;
    char dummy[256] __attribute__((aligned(64)));
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigill; sa.sa_flags = SA_NODEFER;
    if (sigaction(SIGILL, &sa, &old) != 0) return 0;
    int ok = 1;
    if (sigsetjmp(dc_jmp, 1) == 0) {
        __asm__ __volatile__("dc civac, %0" :: "r"((uintptr_t)dummy) : "memory");
        __asm__ __volatile__("dsb sy" ::: "memory");
    } else ok = 0;
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

int main(void)
{
    printf("=== fara provisioning round-trip (route_mode=1) ===\n");

    /* ---------------- 0. config + 激励 ---------------- */
    cfg_t c;
    memset(&c, 0, sizeof c);
    if (load_cfg("fara_dec_config.txt", &c) != 0) return 2;
    printf("[cfg] k=%u plain_words=%u route_mode=%u ctr_init=%u\n",
           c.k, c.plain_words, c.route_mode, c.ctr_init);

    uint32_t *b_in   = malloc(4u * B_WORDS);
    uint32_t *w_enc  = malloc(4u * W_WORDS);
    uint32_t *w_ref  = malloc(4u * W_WORDS);
    if (!b_in || !w_enc || !w_ref) { fprintf(stderr, "oom\n"); return 1; }

    FILE *f;
    #define LOAD(name, arr, n) do { \
        f = fopen(name, "rb"); \
        if (!f) { perror("open " name); return 2; } \
        if (fread(arr, 4, n, f) != (n)) { fprintf(stderr, "short %s\n", name); return 2; } \
        fclose(f); } while (0)
    LOAD("b.bin",   b_in,  B_WORDS);
    LOAD("W_enc.bin", w_enc, W_WORDS);
    LOAD("W.bin",   w_ref, W_WORDS);
    #undef LOAD

    size_t in_bytes  = IN_BYTES;
    if (in_bytes > DMA_MAX_XFER) { printf(">>> FAIL: transfer too big\n"); return 2; }

    /* ---------------- 1. 映射寄存器 ---------------- */
    int fdmem = open("/dev/mem", O_RDWR | O_SYNC);
    if (fdmem < 0) { perror("open /dev/mem (need root)"); return 1; }
    dma = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, DMA_BASE);
    if (dma == MAP_FAILED) { perror("mmap DMA"); return 1; }
    dec = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, DEC_BASE);
    if (dec == MAP_FAILED) { perror("mmap DEC"); return 1; }

    uint32_t ver = rd_c(D_VERSION);
    printf("[1] DEC VERSION = 0x%08X expect 0x%08X  %s\n",
           ver, DEC_VERSION, ver == DEC_VERSION ? "OK" : "FAIL");
    if (ver != DEC_VERSION) {
        printf(">>> FAIL: dec block not responding (wrong bitstream?)\n");
        return 2;
    }

    /* ---------------- 2. 配置 FE/KDF 并派生密钥 ---------------- */
    printf("[2] program FE/KDF config, start derivation\n");
    wr_c(D_CTRL, 0x4u);                       /* soft_rst（自清） */
    usleep(2000);
    for (int i = 0; i < 4; i++) {
        wr_c(D_MASK0 + 4*i,  c.mask[i]);
        wr_c(D_HELP0 + 4*i,  c.helper[i]);
        wr_c(D_SALT0 + 4*i,  c.salt[i]);
        wr_c(D_PURP0 + 4*i,  c.purpose[i]);
    }
    wr_c(D_FE_K, c.k & 0xFFu);
    wr_c(D_CTRL2, c.route_mode & 1u);         /* route_mode（0 运行期 / 1 供板） */

    /* 回读抽查（写通性） */
    if (rd_c(D_MASK0) != c.mask[0]) { printf(">>> FAIL: MASK0 readback\n"); return 2; }
    if (rd_c(D_HELP0) != c.helper[0]) { printf(">>> FAIL: HELP0 readback\n"); return 2; }

    wr_c(D_CTRL, 0x1u);                       /* fe_start = 1（电平） */

    double t0 = now_s();
    uint32_t st = 0;
    for (;;) {
        st = rd_c(D_STATUS);
        if (st & 0x2u) break;                 /* fe_done */
        if (st & 0x4u) { printf(">>> FAIL: FE err (status=0x%08X)\n", st); return 3; }
        if (now_s() - t0 > FE_TIMEOUT_S) {
            printf(">>> FAIL: FE timeout (status=0x%08X)\n", st); return 3;
        }
        usleep(100);
    }
    printf("    fe_done  (k_used=%u, %.1f ms)\n", (st >> 8) & 0xFFu,
           (now_s() - t0) * 1e3);
    wr_c(D_CTRL, 0x0u);                       /* 清 fe_start/fe_done */

    t0 = now_s();
    for (;;) {
        st = rd_c(D_STATUS);
        if (st & 0x40u) break;                /* aes_key_ready */
        if (now_s() - t0 > FE_TIMEOUT_S) {
            printf(">>> FAIL: key not ready (status=0x%08X)\n", st); return 3;
        }
        usleep(100);
    }
    printf("    aes_key_ready  key_locked=%u kdf_done=%u  %.1f ms\n",
           (st >> 5) & 1u, (st >> 4) & 1u, (now_s() - t0) * 1e3);
    if (!(st & 0x20u)) { printf(">>> FAIL: key not locked\n"); return 3; }

    /* nonce / ctr / plain_words（ctr_load 在 DMA 启动前打脉冲） */
    for (int i = 0; i < 3; i++) {
        uint32_t w = (uint32_t)c.nonce[4*i] | ((uint32_t)c.nonce[4*i+1] << 8)
                   | ((uint32_t)c.nonce[4*i+2] << 16) | ((uint32_t)c.nonce[4*i+3] << 24);
        wr_c(D_NONCE0 + 4*i, w);
    }
    wr_c(D_CTR_INIT, c.ctr_init);
    wr_c(D_PLAIN_WORDS, c.plain_words);
    printf("    nonce=%02X%02X%02X... ctr_init=%u plain_words=%u\n",
           c.nonce[0], c.nonce[1], c.nonce[2], c.ctr_init, c.plain_words);

    /* ---------------- 3. CMA 缓冲区 ---------------- */
    printf("[3] allocate DMA buffer\n");
    size_t buflen = (2 * in_bytes + 0x200000u - 1u) & ~(size_t)(0x200000u - 1u);
    int buf_fd = -1;
    if (heap_alloc(buflen, &buf_fd) != 0) {
        perror("dma_heap alloc"); return 1;
    }
    uint8_t *buf = mmap(NULL, buflen, PROT_READ | PROT_WRITE, MAP_SHARED, buf_fd, 0);
    if (buf == MAP_FAILED) { perror("mmap dma-buf"); return 1; }
    memset(buf, 0, buflen);

    const char *why = "";
    uint64_t buf_pa = va_to_pa(buf, &why);
    if (!buf_pa || check_contig(buf, buflen, buf_pa, &why) != 0) {
        printf(">>> FAIL: %s\n", why); return 2;
    }
    have_dc = probe_dc();

    size_t out_off = (in_bytes + 0xFFFu) & ~(size_t)0xFFFu;
    uint64_t in_pa  = buf_pa;
    uint64_t out_pa = buf_pa + out_off;

    /* 输入流：[X pattern | b | W_enc] */
    uint32_t *inw = (uint32_t *)buf;
    for (uint32_t i = 0; i < K_WORDS; i++) inw[i] = 0xC0DEC0DEu;
    memcpy(inw + K_WORDS, b_in, 4u * B_WORDS);
    memcpy(inw + K_WORDS + B_WORDS, w_enc, 4u * W_WORDS);
    memset(buf + out_off, 0xA5, in_bytes);

    if (buf_sync(buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE) != 0)
        perror("  sync START|WRITE");
    if (buf_sync(buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) != 0)
        perror("  sync END|WRITE");
    if (have_dc) dcache_clean(buf, out_off + in_bytes);
    printf("    in %.2f MB, buffer %.2f MB, EL0 cache ops %s\n",
           (double)in_bytes / 1048576.0, (double)buflen / 1048576.0,
           have_dc ? "available" : "unavailable");

    /* ---------------- 4. DMA round-trip ---------------- */
    printf("[4] arm DMA, ctr_load, start MM2S\n");
    wr_d(MM2S_DMACR, DMACR_RESET);
    wr_d(S2MM_DMACR, DMACR_RESET);
    usleep(2000);
    wr_d(MM2S_DMACR, 0); wr_d(S2MM_DMACR, 0);
    usleep(2000);
    wr_d(MM2S_DMACR, DMACR_RS);
    wr_d(S2MM_DMACR, DMACR_RS);

    wr_d(S2MM_DA,     (uint32_t)out_pa);
    wr_d(S2MM_DA_MSB, (uint32_t)(out_pa >> 32));
    wr_d(S2MM_LENGTH, (uint32_t)in_bytes);

    wr_c(D_CTRL, 0x8u);                       /* ctr_load（自清脉冲） */

    wr_d(MM2S_SA,     (uint32_t)in_pa);
    wr_d(MM2S_SA_MSB, (uint32_t)(in_pa >> 32));
    wr_d(MM2S_LENGTH, (uint32_t)in_bytes);

    t0 = now_s();
    uint32_t msr = 0, ssr = 0;
    int timed_out = 0;
    for (;;) {
        msr = rd_d(MM2S_DMASR);
        ssr = rd_d(S2MM_DMASR);
        int mm_ok = ((msr & DMASR_IDLE) && !(msr & DMASR_HALTED)) || (msr & DMASR_ERR);
        int sm_ok = ((ssr & DMASR_IDLE) && !(ssr & DMASR_HALTED)) || (ssr & DMASR_ERR);
        if (mm_ok && sm_ok) break;
        if (now_s() - t0 > DMA_TIMEOUT_S) { timed_out = 1; break; }
        usleep(1000);
    }
    printf("    elapsed %.1f ms%s\n", (now_s() - t0) * 1e3,
           timed_out ? "  (TIMEOUT)" : "");
    printf("    MM2S_DMASR=0x%08X S2MM_DMASR=0x%08X\n", msr, ssr);
    if (timed_out || (msr & DMASR_ERR) || (ssr & DMASR_ERR)) {
        printf(">>> FAIL: DMA error/timeout\n"); return 3;
    }

    /* ---------------- 5. 比对 ---------------- */
    printf("[5] compare decrypted stream vs plaintext\n");
    if (buf_sync(buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ) != 0)
        perror("  sync START|READ");
    if (have_dc) dcache_inval(buf + out_off, in_bytes);
    if (buf_sync(buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ) != 0)
        perror("  sync END|READ");

    const uint32_t *outw = (const uint32_t *)(buf + out_off);
    int fails = 0;
    fails += memcmp(outw, inw, 4u * (K_WORDS + B_WORDS)) != 0;   /* X/b 直通 */
    fails += memcmp(outw + K_WORDS + B_WORDS, w_ref, 4u * W_WORDS) != 0;
    if (fails) {
        size_t nw = K_WORDS + B_WORDS + W_WORDS;
        for (size_t i = 0; i < nw; i++) {
            if (outw[i] != inw[i] && i < K_WORDS + B_WORDS) {
                printf("    first plain mismatch @word %zu: got %08X want %08X\n",
                       i, outw[i], inw[i]); break;
            }
        }
        for (size_t i = K_WORDS + B_WORDS; i < nw; i++) {
            if (outw[i] != w_ref[i - K_WORDS - B_WORDS]) {
                printf("    first W mismatch @word %zu (W[%zu]): got %08X want %08X\n",
                       i, i - K_WORDS - B_WORDS, outw[i],
                       w_ref[i - K_WORDS - B_WORDS]);
                break;
            }
        }
    }

    /* 恢复运行期选路 */
    wr_c(D_CTRL2, 0x0u);

    printf("\n");
    if (fails == 0) {
        printf("=== ROUND-TRIP PASS: FE->KDF->AES-CTR verified on real PUF response ===\n");
        return 0;
    }
    printf("=== ROUND-TRIP FAIL (%d segment(s)) ===\n", fails);
    return 3;
}
