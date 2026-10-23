/*
 * fara-resident.c -- up_proj 权重常驻守护
 *
 * 目的
 *   把 up_proj 的 W/b/cfg 一次性放进一块「物理连续 + 物理地址固定」的内存里，
 *   然后进程常驻不退出，让这块内存一直不被释放。之后任何需要喂 PL 侧 AXI DMA
 *   的程序（推理服务、L3 测试）只要读 /run/fara-resident.json 拿物理地址即可，
 *   不必再搬 9.4 MB 权重。
 *
 * 为什么是 dma_heap 而不是 u-dma-buf
 *   dma_heap 是内核自带、板上已开（cma=1200M），gemm_dma_test 的 L3 就是走这条路
 *   验证通过的；u-dma-buf 需要额外编译内核模块（要匹配 Xilinx 内核头文件），
 *   风险高。dma_heap 的唯一缺点是 fd 一关缓冲就释放 —— 所以本程序常驻不退出来
 *   解决这一点。物理地址从 pagemap 反查，开机后固定不变。
 *
 * 零 SD 卡写入
 *   本程序只写两类目标：/dev/dma_heap（内存）与 /run（tmpfs）。源文件来自
 *   /dev/shm（tmpfs）。rootfs(ext4/SD) 全程不落一个字节。
 *
 * 用法
 *   sudo ./fara-resident [/dev/shm/fara-models]
 *     SRC 目录需含 board_W_*.bin / board_b_*.bin / board_cfg_*.json
 *   前台常驻；systemd 下用 Type=simple 直接跑。
 *
 * 退出码：0 正常常驻后被信号终止  1 环境/参数错  2 源文件错  3 校验失败
 *
 * 编译：cc -O2 -o fara-resident fara-resident.c
 */

#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>
#include <signal.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>

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
struct dma_buf_sync { uint64_t flags; };
#define DMA_BUF_SYNC_READ  (1 << 0)
#define DMA_BUF_SYNC_WRITE (2 << 0)
#define DMA_BUF_SYNC_RW    (DMA_BUF_SYNC_READ | DMA_BUF_SYNC_WRITE)
#define DMA_BUF_SYNC_START (0 << 2)
#define DMA_BUF_SYNC_END   (1 << 2)
#define DMA_BUF_BASE 'b'
#define DMA_BUF_IOCTL_SYNC _IOW(DMA_BUF_BASE, 0, struct dma_buf_sync)
#endif

/*---------------------------------------------------------------------------
 * 布局约定（必须与 fara-load-weights.sh / PS 侧测试程序一致）
 *-------------------------------------------------------------------------*/
#define BUF_BYTES 10485760UL   /* 10 MB，够放 W+b+cfg 且留余量 */

#define W_OFF   0UL
#define B_OFF   9437184UL      /* W 结束处 */
#define C_OFF   9449472UL      /* b 结束处 */

#define W_BYTES 9437184UL
#define B_BYTES 12288UL

static const char *W_NAME = "board_W_transformer_h_0_mlp_c_fc.bin";
static const char *B_NAME = "board_b_transformer_h_0_mlp_c_fc.bin";
static const char *C_NAME = "board_cfg_transformer_h_0_mlp_c_fc.json";

static const char *OUT_JSON = "/run/fara-resident.json";

/*---------------------------------------------------------------------------
 * SHA-256（自包含，用于「源文件 == 缓冲回读」的一致性校验）
 *-------------------------------------------------------------------------*/
typedef struct { uint32_t h[8]; uint64_t len; uint8_t blk[64]; size_t n; } sha256_ctx;

static const uint32_t K256[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
};

#define ROR(x,n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(sha256_ctx *c, const uint8_t *p)
{
    uint32_t w[64], a, b, d, e, f, g, hh, t1, t2;
    int i;
    for (i = 0; i < 16; i++)
        w[i] = ((uint32_t)p[4*i] << 24) | ((uint32_t)p[4*i+1] << 16) |
               ((uint32_t)p[4*i+2] << 8) | (uint32_t)p[4*i+3];
    for (i = 16; i < 64; i++) {
        uint32_t s0 = ROR(w[i-15],7) ^ ROR(w[i-15],18) ^ (w[i-15] >> 3);
        uint32_t s1 = ROR(w[i-2],17) ^ ROR(w[i-2],19) ^ (w[i-2] >> 10);
        w[i] = w[i-16] + s0 + w[i-7] + s1;
    }
    a = c->h[0]; b = c->h[1]; d = c->h[3]; e = c->h[4];
    f = c->h[5]; g = c->h[6]; hh = c->h[7];
    {
        uint32_t cc = c->h[2];
        for (i = 0; i < 64; i++) {
            uint32_t S1 = ROR(e,6) ^ ROR(e,11) ^ ROR(e,25);
            uint32_t ch = (e & f) ^ ((~e) & g);
            t1 = hh + S1 + ch + K256[i] + w[i];
            uint32_t S0 = ROR(a,2) ^ ROR(a,13) ^ ROR(a,22);
            uint32_t mj = (a & b) ^ (a & cc) ^ (b & cc);
            t2 = S0 + mj;
            hh = g; g = f; f = e; e = d + t1;
            d = cc; cc = b; b = a; a = t1 + t2;
        }
        c->h[2] += cc;
    }
    c->h[0] += a; c->h[1] += b; c->h[3] += d; c->h[4] += e;
    c->h[5] += f; c->h[6] += g; c->h[7] += hh;
}

static void sha256_init(sha256_ctx *c)
{
    c->h[0]=0x6a09e667; c->h[1]=0xbb67ae85; c->h[2]=0x3c6ef372; c->h[3]=0xa54ff53a;
    c->h[4]=0x510e527f; c->h[5]=0x9b05688c; c->h[6]=0x1f83d9ab; c->h[7]=0x5be0cd19;
    c->len = 0; c->n = 0;
}

static void sha256_update(sha256_ctx *c, const void *data, size_t len)
{
    const uint8_t *p = data;
    c->len += len;
    while (len--) {
        c->blk[c->n++] = *p++;
        if (c->n == 64) { sha256_block(c, c->blk); c->n = 0; }
    }
}

static void sha256_final(sha256_ctx *c, uint8_t out[32])
{
    uint64_t bits = c->len * 8;
    uint8_t pad = 0x80;
    sha256_update(c, &pad, 1);
    {
        uint8_t z = 0;
        while (c->n != 56) sha256_update(c, &z, 1);
    }
    {
        uint8_t lb[8];
        int i;
        for (i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8*i));
        sha256_update(c, lb, 8);
    }
    {
        int i;
        for (i = 0; i < 8; i++) {
            out[4*i]   = (uint8_t)(c->h[i] >> 24);
            out[4*i+1] = (uint8_t)(c->h[i] >> 16);
            out[4*i+2] = (uint8_t)(c->h[i] >> 8);
            out[4*i+3] = (uint8_t)(c->h[i]);
        }
    }
}

static void sha256_hex(const uint8_t d[32], char out[65])
{
    static const char *hx = "0123456789abcdef";
    int i;
    for (i = 0; i < 32; i++) { out[2*i] = hx[d[i] >> 4]; out[2*i+1] = hx[d[i] & 15]; }
    out[64] = 0;
}

/*---------------------------------------------------------------------------
 * 缓冲区
 *-------------------------------------------------------------------------*/
static int buf_sync(int fd, uint64_t flags)
{
    struct dma_buf_sync s;
    s.flags = flags;
    return ioctl(fd, DMA_BUF_IOCTL_SYNC, &s);
}

static int heap_alloc(size_t len, int *out_fd)
{
    int hfd = open("/dev/dma_heap/reserved", O_RDWR | O_CLOEXEC);
    if (hfd < 0) return -1;

    struct dma_heap_allocation_data d;
    memset(&d, 0, sizeof d);
    d.len        = len;
    d.fd_flags   = O_RDWR | O_CLOEXEC;
    d.heap_flags = 0;

    if (ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &d) < 0) { close(hfd); return -1; }
    close(hfd);
    *out_fd = (int)d.fd;
    return 0;
}

/* 虚拟地址 -> 物理地址（需 root；读 /proc/self/pagemap） */
static uint64_t va_to_pa(const void *va, const char **why)
{
    int fd = open("/proc/self/pagemap", O_RDONLY | O_CLOEXEC);
    if (fd < 0) { *why = "open pagemap failed"; return 0; }

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

/*---------------------------------------------------------------------------
 * 工具
 *-------------------------------------------------------------------------*/
static uint64_t file_size(const char *p, int *ok)
{
    struct stat st;
    *ok = (stat(p, &st) == 0) ? 1 : 0;
    return *ok ? (uint64_t)st.st_size : 0;
}

static int read_whole(const char *p, void *dst, size_t n)
{
    FILE *f = fopen(p, "rb");
    if (!f) { perror(p); return -1; }
    size_t got = fread(dst, 1, n, f);
    fclose(f);
    if (got != n) { fprintf(stderr, "%s: short read %zu != %zu\n", p, got, n); return -1; }
    return 0;
}

static int sha256_file(const char *p, char hex[65])
{
    FILE *f = fopen(p, "rb");
    static uint8_t chunk[65536];
    sha256_ctx c;
    uint8_t d[32];
    size_t got;

    if (!f) { perror(p); return -1; }
    sha256_init(&c);
    while ((got = fread(chunk, 1, sizeof chunk, f)) > 0) sha256_update(&c, chunk, got);
    fclose(f);
    sha256_final(&c, d);
    sha256_hex(d, hex);
    return 0;
}

static int sha256_mem(const void *p, size_t n, char hex[65])
{
    sha256_ctx c;
    uint8_t d[32];
    sha256_init(&c);
    sha256_update(&c, p, n);
    sha256_final(&c, d);
    sha256_hex(d, hex);
    return 0;
}

/*---------------------------------------------------------------------------
 * 主流程
 *-------------------------------------------------------------------------*/
static volatile sig_atomic_t stop_flag = 0;
static void on_sig(int s) { (void)s; stop_flag = 1; }

int main(int argc, char **argv)
{
    const char *src = (argc > 1) ? argv[1] : "/dev/shm/fara-models";

    char wp[512], bp[512], cp[512];
    snprintf(wp, sizeof wp, "%s/%s", src, W_NAME);
    snprintf(bp, sizeof bp, "%s/%s", src, B_NAME);
    snprintf(cp, sizeof cp, "%s/%s", src, C_NAME);

    printf("=== fara-resident: up_proj 权重常驻 ===\n");
    printf("源目录 : %s\n", src);

    /* ---- 0. 源文件检查（先卡大小，别让截断文件进缓冲）---- */
    int ok = 0;
    uint64_t wsz = file_size(wp, &ok);
    if (!ok) { fprintf(stderr, "缺文件 %s\n", wp); return 2; }
    uint64_t bsz = file_size(bp, &ok);
    if (!ok) { fprintf(stderr, "缺文件 %s\n", bp); return 2; }
    uint64_t csz = file_size(cp, &ok);
    if (!ok) { fprintf(stderr, "缺文件 %s\n", cp); return 2; }

    if (wsz != W_BYTES) {
        fprintf(stderr, "W 大小不符: %llu != %lu（下载/拷贝被截断？）\n",
                (unsigned long long)wsz, W_BYTES);
        return 2;
    }
    if (bsz != B_BYTES) {
        fprintf(stderr, "b 大小不符: %llu != %lu\n", (unsigned long long)bsz, B_BYTES);
        return 2;
    }
    if (C_OFF + csz > BUF_BYTES) {
        fprintf(stderr, "cfg 超出缓冲: %lu + %llu > %lu\n",
                C_OFF, (unsigned long long)csz, BUF_BYTES);
        return 2;
    }
    printf("源大小 : W=%llu B  b=%llu B  cfg=%llu B\n",
           (unsigned long long)wsz, (unsigned long long)bsz, (unsigned long long)csz);

    /* ---- 1. 分配物理连续缓冲 ---- */
    int fd = -1;
    if (heap_alloc(BUF_BYTES, &fd) != 0) {
        fprintf(stderr, "dma_heap 分配失败: %s\n", strerror(errno));
        fprintf(stderr, "检查 /dev/dma_heap/reserved 是否存在\n");
        return 1;
    }
    void *buf = mmap(NULL, BUF_BYTES, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    if (buf == MAP_FAILED) { perror("mmap"); close(fd); return 1; }

    /* 全部写一遍，把页 fault 进来（pagemap 才读得到 PFN）*/
    memset(buf, 0, BUF_BYTES);

    const char *why = "";
    uint64_t pa = va_to_pa(buf, &why);
    if (!pa) {
        fprintf(stderr, "取物理地址失败: %s\n", why);
        fprintf(stderr, "需要用 root 运行（读 pagemap 需 CAP_SYS_ADMIN）\n");
        munmap(buf, BUF_BYTES); close(fd); return 1;
    }
    /* 抽查首/中/尾三页，确认确实物理连续（算错地址不会报错，只会静默踩内存）*/
    {
        size_t offs[3];
        int i;
        offs[0] = 0;
        offs[1] = (BUF_BYTES / 2) & ~(size_t)0xFFF;
        offs[2] = (BUF_BYTES - 0x1000) & ~(size_t)0xFFF;
        for (i = 0; i < 3; i++) {
            uint64_t p = va_to_pa((const uint8_t *)buf + offs[i], &why);
            if (p != pa + offs[i]) {
                fprintf(stderr, "缓冲非物理连续 @0x%zX: pa=0x%llX 期望 0x%llX (%s)\n",
                        offs[i], (unsigned long long)p,
                        (unsigned long long)(pa + offs[i]), why);
                munmap(buf, BUF_BYTES); close(fd); return 1;
            }
        }
    }
    printf("缓冲   : %lu B @ phys 0x%010llX\n",
           BUF_BYTES, (unsigned long long)pa);

    /* ---- 2. 载入权重 ---- */
    uint8_t *base = buf;
    if (read_whole(wp, base + W_OFF, (size_t)wsz) != 0) goto fail;
    if (read_whole(bp, base + B_OFF, (size_t)bsz) != 0) goto fail;
    if (read_whole(cp, base + C_OFF, (size_t)csz) != 0) goto fail;

    /* CPU 写完、设备读之前：把脏行写回 PoC。走内核 dma-buf sync 最省事，
       失败也不致命——下面还有一次显式回读校验兜底。*/
    (void)buf_sync(fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);

    /* ---- 3. 回读校验：源文件 sha256 == 缓冲回读 sha256 ---- */
    {
        char h_src[65], h_dst[65];
        if (sha256_file(wp, h_src) != 0) goto fail;
        if (sha256_mem(base + W_OFF, (size_t)wsz, h_dst) != 0) goto fail;
        if (strcmp(h_src, h_dst) != 0) {
            fprintf(stderr, "W 校验失败\n  src=%s\n  dst=%s\n", h_src, h_dst);
            goto fail_verify;
        }
        printf("W sha256 OK: %s\n", h_dst);

        if (sha256_file(bp, h_src) != 0) goto fail;
        if (sha256_mem(base + B_OFF, (size_t)bsz, h_dst) != 0) goto fail;
        if (strcmp(h_src, h_dst) != 0) {
            fprintf(stderr, "b 校验失败\n  src=%s\n  dst=%s\n", h_src, h_dst);
            goto fail_verify;
        }
        printf("b sha256 OK: %s\n", h_dst);
    }

    /* ---- 4. 公布物理地址（供推理/测试程序读取）---- */
    {
        FILE *f = fopen(OUT_JSON, "w");
        if (!f) { perror(OUT_JSON); goto fail; }
        fprintf(f,
            "{\n"
            "  \"phys_addr\": %llu,\n"
            "  \"phys_addr_hex\": \"0x%010llX\",\n"
            "  \"size\": %lu,\n"
            "  \"layout\": { \"W\": %lu, \"b\": %lu, \"cfg\": %lu },\n"
            "  \"bytes\":  { \"W\": %llu, \"b\": %llu, \"cfg\": %llu },\n"
            "  \"pid\": %d\n"
            "}\n",
            (unsigned long long)pa, (unsigned long long)pa,
            BUF_BYTES, W_OFF, B_OFF, C_OFF,
            (unsigned long long)wsz, (unsigned long long)bsz, (unsigned long long)csz,
            (int)getpid());
        fclose(f);
    }
    printf("布局   : W @ +%lu  b @ +%lu  cfg @ +%lu\n", W_OFF, B_OFF, C_OFF);
    printf("地址表 : %s\n", OUT_JSON);
    printf("\n[fara] 权重已常驻（phys 0x%010llX）。本进程保持运行以持有该缓冲。\n",
           (unsigned long long)pa);
    printf("       后续推理只需搬激活 X，源文件与 SD 卡不再参与。\n");
    fflush(stdout);

    /* ---- 5. 常驻：持有 fd 不放 ---- */
    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);
    while (!stop_flag) pause();

    printf("[fara] 收到信号，释放缓冲并退出。\n");
    munmap(buf, BUF_BYTES);
    close(fd);
    unlink(OUT_JSON);
    return 0;

fail_verify:
    munmap(buf, BUF_BYTES); close(fd); return 3;
fail:
    munmap(buf, BUF_BYTES); close(fd); return 2;
}
