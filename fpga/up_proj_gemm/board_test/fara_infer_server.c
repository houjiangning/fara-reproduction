/*
 * fara_infer_server.c -- up_proj 安全权重服务（PUF 门禁 + 解密 + 硬件 FaR 推理 TCP）
 *
 * 定位（7-3 版，取代「从 /dev/shm 读明文 W」的旧模式）
 *   板卡上只有密文（7-2 provisioning 后明文 W 已销毁）。本进程开机时：
 *     1. 采样 PUF 响应 R_t（仅内存，绝不写 SD）；
 *     2. FE/KDF 派生密钥（PL 内部，密钥不出 PL）；
 *     3. 解封 canary.bin（PL AES 引擎，CTR 同一运算）-> 校验 magic +
 *        HD 门禁（R_t 与封印参考在 66 个选中位上的汉明距离）；
 *     4. HD 通过后经 wdec 流解密 [X|b|W_enc] -> 权重进常驻 dma_heap 缓冲；
 *     5. probe 推理（固定 X_probe）比对 SHA256(Y) 与封印值 -> Canary 确认；
 *     6. 全部通过才开 TCP 服务；失败则清权重、退出（fail-closed）。
 *
 *   对外开 TCP，收一条激活 X（N 个 token × 768 维 fp32），
 *   走 DMA -> PL(GEMM+far_reroute) -> DMA 拿回 Y，原样回给 PC。
 *   PC 侧 fara_offload_e2e.py 把 GPT-2 的 transformer.h.0.mlp.c_fc 接到这里。
 *
 * 为什么输入流要补零到 N_MAX=32
 *   RTL 的输入流是**一条连续流** [X(N*K) | b(M) | W(M*K)]，b/W 的起始偏移
 *   由 N 决定（见 gemm_up_proj_core.sv 文件头布局契约）。若 N 每次变，b/W
 *   就得跟着挪 9.4 MB —— 那正是「常驻」要避免的。
 *   所以固定 X 区 = N_MAX*K，把 b/W 钉在 X 区之后；每次只改写 X 区前 N*K 字，
 *   其余补 0，并把 N_TOKENS 设成 N_MAX。c_fc 是逐 token 的线性层，
 *   补零 token 的输出各走各的、不影响真实 token，回读时只取前 N 行即可。
 *
 * 权重来源（enc-dir，默认 /opt/fara/models）
 *     board_W_transformer_h_0_mlp_c_fc.enc    AES-256-CTR 密文 W
 *     board_b_transformer_h_0_mlp_c_fc.bin    明文 b（设计如此，wdec 直通）
 * puf-dir（默认 /opt/fara/puf）
 *     fara_dec_config.txt                     FE/KDF/AES 配置（公开 helper）
 *     canary.bin                              封印锚点（--seal 一次性生成）
 *     fara_canary_config.txt                  canary nonce / 采样参数 / 门限
 *
 * HD 门禁策略（canary 永远是最终仲裁）
 *     HD <= T_CLEAN(1)          干净放行
 *     T_CLEAN < HD <= T_REFUSE(3) 记 WARNING，由 canary 仲裁后放行
 *     HD > T_REFUSE             重采样重试；3 次仍超限 -> 拒绝启动（不解密）
 *   依据：enrollment 32 条冷启动在选中位上 HD 全 0，71e 复测集 <=1。
 *
 * 协议（小端，长连接，一条请求一条响应，与旧版完全一致）
 *   req: "FARQ" u32 mode(=0 基线/far_en=0, 1 硬件 FaR) u32 n_far u32 n_tok u32 rsv
 *        n_far × (u32 col, u32 inv_bits, u32 nd, u32 d0, u32 d1)
 *        n_tok × K u32  (X 行主序 fp32)
 *   rsp: "FARS" u32 status(0=ok) u32 n_tok u32 m_total u32 far_hits
 *        u32 far_phase u32 elapsed_ms u32 rsv
 *        n_tok × M_TOTAL u32  (Y 行主序 [n][m] fp32)
 *
 * 用法
 *   sudo ./fara_infer_server                          # 服务（安全启动 + TCP）
 *   sudo ./fara_infer_server --selftest               # 服务 + 本地自检后退出
 *   sudo ./fara_infer_server --seal --ref66=F         # 一次性封印（生成 canary.bin）
 *
 * 编译：gcc -O2 -o fara_infer_server fara_infer_server.c
 * 输出 ASCII，避免串口按 GBK 解析 UTF-8 乱码。
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
#include <signal.h>
#include <setjmp.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <sys/select.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

/*---------------------------------------------------------------------------
 * dma-heap / dma-buf 用户态 ABI（与 gemm_dma_test.c / far_bench.c 一致）
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
 * PL 地址与寄存器（与 gemm_dma_test.c / far_bench.c 完全一致）
 *-------------------------------------------------------------------------*/
#define DMA_BASE     0xA0000000UL
#define GEMM_BASE    0xA0010000UL
#define MAP_SIZE     0x10000UL

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
#define HW_K         768u
#define HW_N_MAX     32u
#define HW_VERSION   0x00020000u
#define FAR_MAX_ENT  16

/*---------------------------------------------------------------------------
 * puf_dec 解密块（puf_dec_axi_lite.sv，7-2 provisioning 已冻结）与
 * Butterfly PUF（puf_axi_lite.sv）寄存器
 *-------------------------------------------------------------------------*/
#define DEC_BASE     0xA0020000UL
#define PUF_BASE     0xA0030000UL

/* ---- puf_dec AXI-Lite ---- */
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

/* ---- PUF AXI-Lite（puf_axi_lite.sv / puf_sample.c）---- */
#define P_CTRL        0x00   /* W [0]start [1]soft_rst */
#define P_STATUS      0x04   /* R [0]busy [1]done [2]err [7:4]state */
#define P_NBITS       0x08
#define P_NWORDS      0x0C
#define P_N_SAMP      0x10
#define P_T_FORCE     0x14
#define P_T_SETTLE    0x18
#define P_VERSION     0x1C
#define P_NSAMP_DONE  0x20
#define P_STABLE_CNT  0x24
#define P_IDX         0x28
#define P_DATA        0x2C
#define PUF_VERSION   0x00010000u

/*---------------------------------------------------------------------------
 * canary 封印锚点
 *   blob 64B：[0..3]"FRS1" [4..7]ver [8..16]ref66(9B) [17..19]pad
 *             [20..51]sha256(Y_probe) [52..63]rsv
 *   canary.bin = blob XOR keystream(AES-256-CTR, canary nonce, ctr0)
 *   canary nonce 必须与权重 nonce 不同（防同一 keystream 的已知明文攻击）
 *-------------------------------------------------------------------------*/
#define CANARY_MAGIC  "FRS1"
#define CANARY_VER    1u
#define CANARY_BLOB_BYTES  64u
#define NSEL_BITS     66u          /* k=22 -> 3k */
#define SEC_ATTEMPTS  3            /* 采样/派生/解封/Canary 最大尝试次数 */

/* probe 推理的固定 X：fp32 精确值 1.0, 2.0, ..., 64.0 循环（确定性、无舍入） */
#define PROBE_X(k_)   (0x3F800000u + (uint32_t)((k_) % 64u) * 0x00800000u)

/*---------------------------------------------------------------------------
 * 缓冲布局（本文件独有：X 区在最前，b/W 钉在后面）
 *   [ X : N_MAX*K 字 ] [ b : M_TOTAL 字 ] [ W : M_TOTAL*K 字 ]
 *-------------------------------------------------------------------------*/
#define X_WORDS   (HW_N_MAX * HW_K)                 /* 24576 */
#define X_BYTES   (X_WORDS * 4u)                    /* 98304 */
#define B_BYTES   (HW_M_TOTAL * 4u)                 /* 12288 */
#define W_BYTES   (HW_M_TOTAL * HW_K * 4u)          /* 9437184 */
#define IN_WORDS  (X_WORDS + HW_M_TOTAL + HW_M_TOTAL * HW_K)   /* 2386944 */
#define IN_BYTES  (IN_WORDS * 4u)                   /* 9547776 */
#define OUT_WORDS (HW_N_MAX * HW_M_TOTAL)           /* 98304 */
#define OUT_BYTES (OUT_WORDS * 4u)                  /* 393216 */

/* b / W 在缓冲里的字节偏移（X 区之后，固定不变） */
#define B_OFF     X_BYTES
#define W_OFF     (X_BYTES + B_BYTES)

#define DMA_MAX_XFER ((1UL << 26) - 1)

#define POLL_TIMEOUT_S 30.0
#define DEF_PORT       9000

static const char *W_ENC_NAME = "board_W_transformer_h_0_mlp_c_fc.enc";
static const char *B_NAME     = "board_b_transformer_h_0_mlp_c_fc.bin";
static const char *OUT_JSON   = "/run/fara-infer.json";

/* 默认目录（可被 --enc-dir= / --puf-dir= 覆盖） */
static const char *g_enc_dir = "/opt/fara/models";
static const char *g_puf_dir = "/opt/fara/puf";

/*---------------------------------------------------------------------------
 * PL 寄存器 / DMA
 *-------------------------------------------------------------------------*/
static volatile uint32_t *dma;
static volatile uint32_t *gemm;
static volatile uint32_t *dec;
static volatile uint32_t *puf;

/*---------------------------------------------------------------------------
 * 请求/响应头（全部 u32，无对齐填充问题）
 *-------------------------------------------------------------------------*/
typedef struct {
    char     magic[4];     /* "FARQ" */
    uint32_t mode;         /* 0=baseline 1=hardware FaR */
    uint32_t n_far;
    uint32_t n_tok;
    uint32_t rsv;
} req_hdr_t;

typedef struct {
    char     magic[4];     /* "FARS" */
    uint32_t status;       /* 0=ok */
    uint32_t n_tok;
    uint32_t m_total;
    uint32_t far_hits;
    uint32_t far_phase;
    uint32_t elapsed_ms;
    uint32_t rsv;
} rsp_hdr_t;

/*---------------------------------------------------------------------------
 * FARC 控制协议（8-x 实时集成）：与 FARQ 同一端口，按 magic 分流
 *   请求 20B："FARC" op p0 p1 p2   响应 12B："FARC" status n_words + n_words*4
 *   op: 1=STATUS  2=FLIP(idx,bit)  3=RESTORE  4=WIPE
 * 约束：只动运行期 DDR 明文工作副本（等价攻击者物理位翻转的执行器）；
 *       攻击决策/搜索全部在 PC；不碰 SD 密文 / 密钥材料 / RTL。
 *-------------------------------------------------------------------------*/
typedef struct {
    char     magic[4];     /* "FARC" */
    uint32_t op;
    uint32_t p0;
    uint32_t p1;
    uint32_t p2;
} ctrl_req_t;

#define FARC_STATUS   1u
#define FARC_FLIP     2u
#define FARC_RESTORE  3u
#define FARC_WIPE     4u

/* 启动链现场（STATUS 面板数据源） */
typedef struct {
    uint32_t boot_ok;        /* 最近一次 secure_boot 结果 */
    uint32_t hd_final;       /* 最后一次放行的选中位 HD */
    uint32_t fe_k_used;
    uint32_t dec_ms_x100;    /* 最近一次流解密耗时 ×100 */
    uint32_t n_flips;        /* 累计 FLIP 次数 */
    uint32_t wiped;          /* 常驻明文 W 当前是否被清零 */
    uint32_t boot_count;     /* 进程内成功 secure_boot 次数 */
    uint32_t attempts;       /* 最近一次成功所用尝试次数 */
    uint32_t w_dirty;        /* W 变更后 hash 待重算 */
    uint32_t w_hash[8];      /* sha256(常驻明文 W)（防篡改视图；wiped 时为 0） */
    uint32_t enc_hash[8];    /* sha256(SD 密文 W.enc)（静态加密指纹） */
} boot_info_t;

static boot_info_t g_bi;

/*---------------------------------------------------------------------------
 * SHA-256（自包含，给证据留痕用）
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
    uint8_t pad = 0x80, z = 0, lb[8];
    int i;
    sha256_update(c, &pad, 1);
    while (c->n != 56) sha256_update(c, &z, 1);
    for (i = 0; i < 8; i++) lb[i] = (uint8_t)(bits >> (56 - 8*i));
    sha256_update(c, lb, 8);
    for (i = 0; i < 8; i++) {
        out[4*i]   = (uint8_t)(c->h[i] >> 24);
        out[4*i+1] = (uint8_t)(c->h[i] >> 16);
        out[4*i+2] = (uint8_t)(c->h[i] >> 8);
        out[4*i+3] = (uint8_t)(c->h[i]);
    }
}

static void sha256_hex(const uint8_t d[32], char out[65])
{
    static const char *hx = "0123456789abcdef";
    int i;
    for (i = 0; i < 32; i++) { out[2*i] = hx[d[i] >> 4]; out[2*i+1] = hx[d[i] & 15]; }
    out[64] = 0;
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

static void sha256_mem(const void *p, size_t n, char hex[65])
{
    sha256_ctx c;
    uint8_t d[32];
    sha256_init(&c);
    sha256_update(&c, p, n);
    sha256_final(&c, d);
    sha256_hex(d, hex);
}

/* 原始 8 字摘要（大端字序，与 hex 一致），供 STATUS 载荷传输 */
static void sha256_raw_words(const void *p, size_t n, uint32_t out[8])
{
    sha256_ctx c;
    uint8_t d[32];
    int i;
    sha256_init(&c);
    sha256_update(&c, p, n);
    sha256_final(&c, d);
    for (i = 0; i < 8; i++)
        out[i] = ((uint32_t)d[4*i] << 24) | ((uint32_t)d[4*i+1] << 16) |
                 ((uint32_t)d[4*i+2] << 8) | (uint32_t)d[4*i+3];
}

static int sha256_file_raw(const char *path, uint32_t out[8])
{
    FILE *f = fopen(path, "rb");
    uint8_t buf[65536];
    sha256_ctx c;
    uint8_t d[32];
    size_t n;
    int i;
    if (!f) return -1;
    sha256_init(&c);
    while ((n = fread(buf, 1, sizeof buf, f)) > 0) sha256_update(&c, buf, n);
    if (ferror(f)) { fclose(f); return -1; }
    fclose(f);
    sha256_final(&c, d);
    for (i = 0; i < 8; i++)
        out[i] = ((uint32_t)d[4*i] << 24) | ((uint32_t)d[4*i+1] << 16) |
                 ((uint32_t)d[4*i+2] << 8) | (uint32_t)d[4*i+3];
    return 0;
}

/*---------------------------------------------------------------------------
 * PL 寄存器 / DMA
 *-------------------------------------------------------------------------*/
static uint32_t rd_d(unsigned off)              { return dma[off >> 2]; }
static void     wr_d(unsigned off, uint32_t v) { dma[off >> 2] = v; }
static uint32_t rd_g(unsigned off)              { return gemm[off >> 2]; }
static void     wr_g(unsigned off, uint32_t v) { gemm[off >> 2] = v; }
static uint32_t rd_c(unsigned off)              { return dec[off >> 2]; }
static void     wr_c(unsigned off, uint32_t v) { dec[off >> 2] = v; }
static uint32_t rd_p(unsigned off)              { return puf[off >> 2]; }
static void     wr_p(unsigned off, uint32_t v) { puf[off >> 2] = v; }

static int heap_alloc(size_t len, int *out_fd)
{
    int hfd = open("/dev/dma_heap/reserved", O_RDWR | O_CLOEXEC);
    struct dma_heap_allocation_data d;
    if (hfd < 0) return -1;
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
    uint64_t entry = 0;
    off_t off;
    ssize_t n;
    uint64_t pfn;
    if (fd < 0) { *why = "open pagemap failed"; return 0; }
    off = (off_t)(((uintptr_t)va >> 12) * 8);
    n = pread(fd, &entry, 8, off);
    close(fd);
    if (n != 8)                  { *why = "pread pagemap failed"; return 0; }
    if (!(entry & (1ULL << 63))) { *why = "page not present"; return 0; }
    pfn = entry & ((1ULL << 55) - 1);
    if (!pfn)                    { *why = "PFN zeroed (need CAP_SYS_ADMIN)"; return 0; }
    return (pfn << 12) | ((uintptr_t)va & 0xFFFULL);
}

/* EL0 cache 维护（内核 dma-buf sync 可能是 no-op，必须自己兜一层） */
static int have_dc = -1;
static sigjmp_buf dc_jmp;
static void on_sigill(int s) { (void)s; siglongjmp(dc_jmp, 1); }

static int probe_dc(void)
{
    struct sigaction sa, old;
    char dummy[256] __attribute__((aligned(64)));
    int ok = 1;
    memset(&sa, 0, sizeof sa);
    sa.sa_handler = on_sigill;
    sa.sa_flags   = SA_NODEFER;
    if (sigaction(SIGILL, &sa, &old) != 0) return 0;
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

static float bits_to_f32(uint32_t b) { float f; memcpy(&f, &b, 4); return f; }

/*---------------------------------------------------------------------------
 * 全局运行态
 *-------------------------------------------------------------------------*/
static int      g_buf_fd = -1;
static uint8_t *g_buf    = NULL;
static size_t   g_buflen = 0;
static uint64_t g_pa     = 0;
static uint64_t g_in_pa  = 0;
static uint64_t g_out_pa = 0;
static volatile sig_atomic_t g_stop = 0;
static void on_sig(int s) { (void)s; g_stop = 1; }

/* 编程 FaRMap（间接寻址）。返回 0 成功。 */
static int program_farmap(const uint32_t *ent, uint32_t n_far)
{
    uint32_t j;
    if (n_far > FAR_MAX_ENT) return -1;
    wr_g(R_FAR_CTRL, 0);
    wr_g(R_FAR_NENT, n_far);
    for (j = 0; j < n_far; j++) {
        const uint32_t *e = ent + 5 * j;
        wr_g(R_FAR_IDX, j);
        wr_g(R_FAR_A,   e[0]);
        wr_g(R_FAR_INV, e[1]);
        wr_g(R_FAR_ND,  e[2]);
        wr_g(R_FAR_D0,  e[3]);
        wr_g(R_FAR_D1,  e[4]);
    }
    return 0;
}

/*
 * 跑一次完整事务（N_TOKENS 固定 N_MAX）。
 * 返回 0 成功；<0 失败。*elapsed_ms 回填耗时。
 */
static int run_once(int far_en, uint32_t *far_hits, uint32_t *far_phase,
                    double *elapsed_ms)
{
    uint32_t msr = 0, ssr = 0, gst = 0;
    double t0;
    int timed_out = 0;

    /* X 区已由调用方写好并刷过 cache；这里只管硬件时序 */
    wr_g(R_CTRL, 0x2);              /* soft_rst（自清），清 FSM 与 rewire 相位 */
    usleep(2000);
    wr_g(R_K_COLS,   HW_K);
    wr_g(R_N_TOKENS, HW_N_MAX);
    wr_g(R_LAYER_ID, far_en);
    /* far_en 在 soft_rst 之后写死：soft_rst 只清 core FSM / rewire 相位，
       不动 FaRMap 寄存器，但这里显式重写一次，杜绝顺序假设 */
    wr_g(R_FAR_CTRL, far_en ? 1u : 0u);

    wr_d(MM2S_DMACR, DMACR_RESET);
    wr_d(S2MM_DMACR, DMACR_RESET);
    usleep(2000);
    wr_d(MM2S_DMACR, 0);
    wr_d(S2MM_DMACR, 0);
    usleep(2000);
    wr_d(MM2S_DMACR, DMACR_RS);
    wr_d(S2MM_DMACR, DMACR_RS);

    /* 先武装 S2MM（收），再启动核，最后启动 MM2S（发） */
    wr_d(S2MM_DA,     (uint32_t)g_out_pa);
    wr_d(S2MM_DA_MSB, (uint32_t)(g_out_pa >> 32));
    wr_d(S2MM_LENGTH, (uint32_t)OUT_BYTES);

    wr_g(R_CTRL, 0x0);
    usleep(500);
    wr_g(R_CTRL, 0x1);              /* start=1 */

    wr_d(MM2S_SA,     (uint32_t)g_in_pa);
    wr_d(MM2S_SA_MSB, (uint32_t)(g_in_pa >> 32));
    wr_d(MM2S_LENGTH, (uint32_t)IN_BYTES);

    t0 = now_s();
    for (;;) {
        int gm_done, mm_ok, sm_ok;
        msr = rd_d(MM2S_DMASR);
        ssr = rd_d(S2MM_DMASR);
        gst = rd_g(R_STATUS);
        gm_done = (gst & 0x6u) != 0;
        mm_ok = ((msr & DMASR_IDLE) && !(msr & DMASR_HALTED)) || (msr & DMASR_ERR);
        sm_ok = ((ssr & DMASR_IDLE) && !(ssr & DMASR_HALTED)) || (ssr & DMASR_ERR);
        if (gm_done && mm_ok && sm_ok) break;
        if (now_s() - t0 > POLL_TIMEOUT_S) { timed_out = 1; break; }
        usleep(500);
    }
    *elapsed_ms = (now_s() - t0) * 1e3;

    if (far_hits)  *far_hits  = rd_g(R_FAR_HITS);
    if (far_phase) *far_phase = rd_g(R_FAR_PHASE);

    wr_g(R_CTRL, 0x0);              /* 清 done */

    if (timed_out) return -1;
    if (msr & DMASR_ERR) return -2;
    if (ssr & DMASR_ERR) return -3;
    if (gst & 0x4u) return -4;      /* err: in_cnt != in_total 或 last beat 无 tlast */
    return 0;
}

/* 把 X 写进 X 区（前 n_tok 行有效，其余补 0），刷 cache */
static void load_x(const uint32_t *x_words, uint32_t n_tok)
{
    uint32_t *xbuf = (uint32_t *)g_buf;
    size_t used = (size_t)n_tok * HW_K * 4u;
    memcpy(xbuf, x_words, used);
    if (used < X_BYTES) memset((uint8_t *)xbuf + used, 0, X_BYTES - used);
    if (buf_sync(g_buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) != 0)
        perror("  sync END|WRITE");
    if (have_dc) dcache_clean(g_buf, X_BYTES);
}

/* 从 out 区取回前 n_tok 行 Y（硬件是 [tile][token][m]，这里转成 [token][m] 行主序） */
static void collect_y(uint32_t *y_out, uint32_t n_tok)
{
    const uint32_t *raw;
    uint32_t i, per = HW_N_MAX * HW_M_TILE;
    if (buf_sync(g_buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ) != 0)
        perror("  sync START|READ");
    if (have_dc) dcache_inval(g_buf + IN_BYTES, OUT_BYTES);
    raw = (const uint32_t *)(g_buf + IN_BYTES);
    for (i = 0; i < OUT_WORDS; i++) {
        uint32_t t = i / per, rem = i % per;
        uint32_t n = rem / HW_M_TILE, ml = rem % HW_M_TILE;
        uint32_t m = t * HW_M_TILE + ml;
        if (n < n_tok) y_out[(size_t)n * HW_M_TOTAL + m] = raw[i];
    }
    buf_sync(g_buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
}

/*---------------------------------------------------------------------------
 * 7-3 安全启动：配置解析 / PUF 采样 / FE-KDF / wdec 流解密 / canary 封印
 *   寄存器序列与 fara_dec_roundtrip.c（7-2 实测通过）逐条一致
 *-------------------------------------------------------------------------*/
#define SEC_X_WORDS     768u                          /* 解密流 X 段（N=1） */
#define SEC_B_WORDS     HW_M_TOTAL                    /* 3072 */
#define SEC_W_WORDS     (HW_M_TOTAL * HW_K)           /* 2359296 */
#define SEC_PLAIN_WORDS (SEC_X_WORDS + SEC_B_WORDS)   /* 3840，与 provisioning 一致 */
#define SEC_STREAM_BYTES ((SEC_X_WORDS + SEC_B_WORDS + SEC_W_WORDS) * 4u)

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
} dec_cfg_t;

typedef struct {
    uint8_t  nonce[12];    /* canary 专用 nonce（必须 != 权重 nonce） */
    uint32_t samp_m, tforce, tsettle;
    uint32_t t_clean, t_refuse;
} can_cfg_t;

static dec_cfg_t g_dc;    /* RESTORE 复用 secure_boot 所需的全局配置 */
static can_cfg_t g_cc;

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

/* 32-hex 的 128-bit 大数：文件序最高字在前 -> words[3]=最高字（与 PC 端一致） */
static void parse_w128(const char *s, uint32_t words[4])
{
    words[3] = hex_word(s +  0);
    words[2] = hex_word(s +  8);
    words[1] = hex_word(s + 16);
    words[0] = hex_word(s + 24);
}

static int load_cfg(const char *path, dec_cfg_t *c)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror("open dec config"); return -1; }
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
            if (strlen(v) != 24) { fprintf(stderr, "NONCE needs 24 hex\n"); fclose(f); return -1; }
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
    if (have != need) { fprintf(stderr, "dec config: %d/%d keys\n", have, need); return -1; }
    return 0;
}

static int load_can_cfg(const char *path, can_cfg_t *c)
{
    FILE *f = fopen(path, "r");
    if (!f) { perror("open canary config"); return -1; }
    char line[512];
    int have = 0, need = 6;
    memset(c, 0, sizeof *c);
    while (fgets(line, sizeof line, f)) {
        char *nl = strchr(line, '\n'); if (nl) *nl = 0;
        char *eq = strchr(line, '=');
        if (!eq) continue;
        *eq = 0;
        const char *k = line, *v = eq + 1;
        if (!strcmp(k, "CANARY_NONCE")) {
            if (strlen(v) != 24) { fprintf(stderr, "CANARY_NONCE needs 24 hex\n"); fclose(f); return -1; }
            for (int i = 0; i < 12; i++) {
                char t[3] = { v[2*i], v[2*i+1], 0 };
                c->nonce[i] = (uint8_t)strtoul(t, 0, 16);
            }
            have++;
        }
        else if (!strcmp(k, "SAMP_M"))      { c->samp_m   = (uint32_t)strtoul(v, 0, 0); have++; }
        else if (!strcmp(k, "SAMP_TFORCE")) { c->tforce   = (uint32_t)strtoul(v, 0, 0); have++; }
        else if (!strcmp(k, "SAMP_TSETTLE")){ c->tsettle  = (uint32_t)strtoul(v, 0, 0); have++; }
        else if (!strcmp(k, "T_CLEAN"))     { c->t_clean  = (uint32_t)strtoul(v, 0, 0); have++; }
        else if (!strcmp(k, "T_REFUSE"))    { c->t_refuse = (uint32_t)strtoul(v, 0, 0); have++; }
    }
    fclose(f);
    if (have != need) { fprintf(stderr, "canary config: %d/%d keys\n", have, need); return -1; }
    return 0;
}

/* PUF 触发一次采样，读回 128-bit 响应（words[j]=word j，j=3 为最高字）。
   只进内存，绝不落盘。错误路径必须 soft_rst，否则 S_ERR 粘滞。 */
static int puf_capture(const can_cfg_t *cc, uint32_t words[4])
{
    if (rd_p(P_VERSION) != PUF_VERSION) {
        fprintf(stderr, "[sec] PUF VERSION=0x%08X expect 0x%08X\n",
                rd_p(P_VERSION), PUF_VERSION);
        return -1;
    }
    wr_p(P_N_SAMP,   cc->samp_m);
    wr_p(P_T_FORCE,  cc->tforce);
    wr_p(P_T_SETTLE, cc->tsettle);
    wr_p(P_CTRL, 1u);
    double t0 = now_s();
    uint32_t st;
    for (;;) {
        st = rd_p(P_STATUS);
        if (st & (1u << 1)) break;                        /* done */
        if (st & (1u << 2)) {                             /* err */
            fprintf(stderr, "[sec] PUF err state=%u STATUS=0x%08X\n",
                    (st >> 4) & 0xFu, st);
            wr_p(P_CTRL, 2u); usleep(100); wr_p(P_CTRL, 0u);
            return -1;
        }
        if (now_s() - t0 > 5.0) {
            fprintf(stderr, "[sec] PUF timeout\n");
            wr_p(P_CTRL, 2u); usleep(100); wr_p(P_CTRL, 0u);
            return -1;
        }
        usleep(100);
    }
    for (uint32_t i = 0; i < 4; i++) {
        wr_p(P_IDX, i);
        words[i] = rd_p(P_DATA);
    }
    wr_p(P_CTRL, 0u);                                     /* 清 done */
    return 0;
}

/* FE/KDF 派生密钥（PL 内部，密钥不出 PL）。成功后 route_mode 保持 1。 */
static int dec_derive(const dec_cfg_t *c, uint32_t *k_used)
{
    if (rd_c(D_VERSION) != DEC_VERSION) {
        fprintf(stderr, "[sec] DEC VERSION=0x%08X expect 0x%08X\n",
                rd_c(D_VERSION), DEC_VERSION);
        return -1;
    }
    wr_c(D_CTRL, 0x4u);                                   /* soft_rst 自清 */
    usleep(2000);
    for (int i = 0; i < 4; i++) {
        wr_c(D_MASK0 + 4*i, c->mask[i]);
        wr_c(D_HELP0  + 4*i, c->helper[i]);
        wr_c(D_SALT0  + 4*i, c->salt[i]);
        wr_c(D_PURP0  + 4*i, c->purpose[i]);
    }
    wr_c(D_FE_K, c->k & 0xFFu);
    wr_c(D_CTRL2, 1u);                                    /* route_mode=1（wdec） */

    wr_c(D_CTRL, 0x1u);                                   /* fe_start 电平 */
    double t0 = now_s();
    uint32_t st;
    for (;;) {
        st = rd_c(D_STATUS);
        if (st & 0x2u) break;                             /* fe_done */
        if (st & 0x4u) {
            fprintf(stderr, "[sec] FE err status=0x%08X\n", st);
            wr_c(D_CTRL, 0x4u); usleep(100); wr_c(D_CTRL, 0x0u);
            wr_c(D_CTRL2, 0x0u);
            return -1;
        }
        if (now_s() - t0 > 2.0) {
            fprintf(stderr, "[sec] FE timeout status=0x%08X\n", st);
            wr_c(D_CTRL, 0x4u); usleep(100); wr_c(D_CTRL, 0x0u);
            wr_c(D_CTRL2, 0x0u);
            return -1;
        }
        usleep(100);
    }
    wr_c(D_CTRL, 0x0u);                                   /* 清 fe_start/fe_done */
    for (;;) {
        st = rd_c(D_STATUS);
        if (st & 0x40u) break;                            /* aes_key_ready */
        if (now_s() - t0 > 2.0) {
            fprintf(stderr, "[sec] key not ready status=0x%08X\n", st);
            wr_c(D_CTRL2, 0x0u);
            return -1;
        }
        usleep(100);
    }
    if (!(st & 0x20u)) { fprintf(stderr, "[sec] key not locked\n"); wr_c(D_CTRL2, 0x0u); return -1; }
    if (k_used) *k_used = (st >> 8) & 0xFFu;
    return 0;
}

/* 一次 wdec 流通过（CTR 对称：同 nonce/ctr 下 加密==解密）。
   调用方负责 D_CTRL2 的 route_mode 与缓冲 cache 维护。 */
static int wdec_pass(const uint8_t *nonce12, uint32_t ctr_init, uint32_t plain_words,
                     uint64_t in_pa, uint64_t out_pa, uint32_t bytes)
{
    for (int i = 0; i < 3; i++) {
        uint32_t w = (uint32_t)nonce12[4*i] | ((uint32_t)nonce12[4*i+1] << 8)
                   | ((uint32_t)nonce12[4*i+2] << 16) | ((uint32_t)nonce12[4*i+3] << 24);
        wr_c(D_NONCE0 + 4*i, w);
    }
    wr_c(D_CTR_INIT, ctr_init);
    wr_c(D_PLAIN_WORDS, plain_words);

    wr_d(MM2S_DMACR, DMACR_RESET);
    wr_d(S2MM_DMACR, DMACR_RESET);
    usleep(2000);
    wr_d(MM2S_DMACR, 0); wr_d(S2MM_DMACR, 0);
    usleep(2000);
    wr_d(MM2S_DMACR, DMACR_RS);
    wr_d(S2MM_DMACR, DMACR_RS);

    wr_d(S2MM_DA,     (uint32_t)out_pa);
    wr_d(S2MM_DA_MSB, (uint32_t)(out_pa >> 32));
    wr_d(S2MM_LENGTH, bytes);

    wr_c(D_CTRL, 0x8u);                                   /* ctr_load 脉冲 */

    wr_d(MM2S_SA,     (uint32_t)in_pa);
    wr_d(MM2S_SA_MSB, (uint32_t)(in_pa >> 32));
    wr_d(MM2S_LENGTH, bytes);

    double t0 = now_s();
    uint32_t msr = 0, ssr = 0;
    for (;;) {
        msr = rd_d(MM2S_DMASR);
        ssr = rd_d(S2MM_DMASR);
        int mm_ok = ((msr & DMASR_IDLE) && !(msr & DMASR_HALTED)) || (msr & DMASR_ERR);
        int sm_ok = ((ssr & DMASR_IDLE) && !(ssr & DMASR_HALTED)) || (ssr & DMASR_ERR);
        if (mm_ok && sm_ok) break;
        if (now_s() - t0 > POLL_TIMEOUT_S) return -1;
        usleep(500);
    }
    if (msr & DMASR_ERR) return -2;
    if (ssr & DMASR_ERR) return -3;
    return 0;
}

/* 选中位 HD：resp 的前 NSEL_BITS 个 mask=1 位 vs ref66 打包位（bit n = 第 n 个选中位） */
static uint32_t hd_sel66(const dec_cfg_t *dc, const uint32_t *resp, const uint8_t *ref66)
{
    uint32_t hd = 0, n = 0;
    for (uint32_t b = 0; b < 128u && n < NSEL_BITS; b++) {
        if ((dc->mask[b >> 5] >> (b & 31)) & 1u) {
            uint32_t rb = (resp[b >> 5] >> (b & 31)) & 1u;
            uint32_t rr = (ref66[n >> 3] >> (n & 7)) & 1u;
            hd += (rb != rr);
            n++;
        }
    }
    return hd;
}

static uint32_t popcnt128(const uint32_t *w)
{
    uint32_t c = 0;
    for (int i = 0; i < 4; i++) {
        uint32_t v = w[i];
        while (v) { c += v & 1u; v >>= 1; }
    }
    return c;
}

/* 覆写清零（防优化掉） */
static void secure_wipe(void *p, size_t n)
{
    volatile uint8_t *q = (volatile uint8_t *)p;
    while (n--) *q++ = 0;
    __asm__ __volatile__("" ::: "memory");
}

/*---------------------------------------------------------------------------
 * scratch 缓冲（解密/封印流用，分配一次，启动链结束后释放）
 *-------------------------------------------------------------------------*/
static int      g_scr_fd = -1;
static uint8_t *g_scr    = NULL;
static size_t   g_scr_len = 0;
static uint64_t g_scr_in_pa = 0, g_scr_out_pa = 0;

static int scratch_alloc(void)
{
    g_scr_len = (2u * SEC_STREAM_BYTES + 0x200000u - 1u) & ~(size_t)(0x200000u - 1u);
    if (heap_alloc(g_scr_len, &g_scr_fd) != 0) {
        fprintf(stderr, "[sec] scratch dma_heap alloc failed: %s\n", strerror(errno));
        return -1;
    }
    g_scr = mmap(NULL, g_scr_len, PROT_READ | PROT_WRITE, MAP_SHARED, g_scr_fd, 0);
    if (g_scr == MAP_FAILED) { g_scr = NULL; close(g_scr_fd); g_scr_fd = -1; return -1; }
    memset(g_scr, 0, g_scr_len);
    const char *why = "";
    uint64_t pa = va_to_pa(g_scr, &why);
    if (!pa) { fprintf(stderr, "[sec] scratch pa: %s\n", why); return -1; }
    /* 物理连续性抽查：首/中/尾三页 */
    {
        size_t offs[3] = { 0, (g_scr_len / 2) & ~(size_t)0xFFF, (g_scr_len - 0x1000) & ~(size_t)0xFFF };
        for (int i = 0; i < 3; i++) {
            uint64_t p = va_to_pa(g_scr + offs[i], &why);
            if (p != pa + offs[i]) {
                fprintf(stderr, "[sec] scratch not contiguous @0x%zX\n", offs[i]);
                return -1;
            }
        }
    }
    g_scr_in_pa  = pa;
    g_scr_out_pa = pa + ((SEC_STREAM_BYTES + 0xFFFu) & ~(uint64_t)0xFFFu);
    have_dc = have_dc < 0 ? probe_dc() : have_dc;
    printf("[sec] scratch %zu B @ 0x%010llX (out @0x%010llX)\n",
           g_scr_len, (unsigned long long)g_scr_in_pa, (unsigned long long)g_scr_out_pa);
    return 0;
}

static void scratch_free(void)
{
    if (g_scr) {
        secure_wipe(g_scr, g_scr_len);                    /* 明文不残留 */
        buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
        munmap(g_scr, g_scr_len);
        g_scr = NULL;
    }
    if (g_scr_fd >= 0) { close(g_scr_fd); g_scr_fd = -1; }
    g_scr_in_pa = g_scr_out_pa = 0;
}

/* 把解密输出中的 b/W 拷进常驻缓冲并做 cache 维护 */
static int install_weights_from(const uint8_t *out_region)
{
    const uint32_t *outw = (const uint32_t *)out_region;
    memcpy(g_buf + B_OFF, outw + SEC_X_WORDS, B_BYTES);
    memcpy(g_buf + W_OFF, outw + SEC_PLAIN_WORDS, W_BYTES);
    if (buf_sync(g_buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE) != 0) perror("  sync");
    if (buf_sync(g_buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE) != 0) perror("  sync");
    if (have_dc) dcache_clean(g_buf + B_OFF, B_BYTES + W_BYTES);
    return 0;
}

/* probe 推理：固定 X_probe -> GEMM -> SHA256(Y 行 0)，hex 写入 out_hex[65] */
static int probe_infer(char out_hex[65])
{
    uint32_t xw[HW_K];
    for (uint32_t k = 0; k < HW_K; k++) xw[k] = PROBE_X(k);
    wr_g(R_FAR_CTRL, 0);
    load_x(xw, 1);
    uint32_t hits = 0, phase = 0;
    double ms = 0;
    int st = run_once(0, &hits, &phase, &ms);
    if (st != 0) {
        fprintf(stderr, "[sec] probe GEMM failed st=%d\n", st);
        return -1;
    }
    uint32_t *yw = malloc(OUT_BYTES);
    if (!yw) return -1;
    collect_y(yw, 1);
    sha256_mem(yw, HW_M_TOTAL * 4u, out_hex);
    free(yw);
    printf("[sec] probe done %.1f ms  sha256(Y0)=%s\n", ms, out_hex);
    return 0;
}

static void wipe_resident_w(void)
{
    secure_wipe(g_buf + W_OFF, W_BYTES);
    (void)buf_sync(g_buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
    if (have_dc) dcache_clean(g_buf + W_OFF, W_BYTES);
    g_bi.wiped = 1;
    g_bi.w_dirty = 1;
}

/*---------------------------------------------------------------------------
 * 安全启动主链（每次上电执行）
 *   返回 0 = 权重已解密并经 canary 确认；-1 = 拒绝启动（权重已清零）
 *-------------------------------------------------------------------------*/
static int secure_boot(const dec_cfg_t *dc, const can_cfg_t *cc)
{
    char wp[512], bp[512], cp[512];
    snprintf(wp, sizeof wp, "%s/%s", g_enc_dir, W_ENC_NAME);
    snprintf(bp, sizeof bp, "%s/%s", g_enc_dir, B_NAME);
    snprintf(cp, sizeof cp, "%s/canary.bin", g_puf_dir);

    /* ---- 源文件检查 ---- */
    uint8_t can_cipher[CANARY_BLOB_BYTES];
    {
        struct stat st;
        if (stat(wp, &st) != 0 || st.st_size != (off_t)W_BYTES) {
            fprintf(stderr, "[sec] %s 缺失或大小不符\n", wp); return -1;
        }
        if (stat(bp, &st) != 0 || st.st_size != (off_t)B_BYTES) {
            fprintf(stderr, "[sec] %s 缺失或大小不符\n", bp); return -1;
        }
        FILE *f = fopen(cp, "rb");
        if (!f || fread(can_cipher, 1, sizeof can_cipher, f) != sizeof can_cipher) {
            fprintf(stderr, "[sec] %s 缺失（先跑 --seal）\n", cp);
            if (f) fclose(f);
            return -1;
        }
        fclose(f);
    }
    /* mask 选中位必须 >= 3k（前 66 个 mask=1 位参与编码，与 sel_positions 升序口径一致） */
    if (popcnt128(dc->mask) < NSEL_BITS || dc->k != 22) {
        fprintf(stderr, "[sec] mask popcnt/k mismatch (%u/%u)\n",
                popcnt128(dc->mask), dc->k);
        return -1;
    }

    if (scratch_alloc() != 0) { scratch_free(); return -1; }

    FILE *fb = fopen(bp, "rb");
    if (!fb) { perror(bp); scratch_free(); return -1; }
    FILE *fw = fopen(wp, "rb");
    if (!fw) { perror(wp); fclose(fb); scratch_free(); return -1; }

    int ok = 0;
    g_bi.boot_ok = 0;                       /* RESTORE 期间 STATUS 可见中间态 */
    for (int att = 1; att <= SEC_ATTEMPTS && !ok; att++) {
        printf("[sec] === secure attempt %d/%d ===\n", att, SEC_ATTEMPTS);

        /* 1. PUF 采样（仅内存；响应是密钥等价物，绝不打印/落盘） */
        uint32_t resp[4];
        if (puf_capture(cc, resp) != 0) continue;
        printf("[sec] puf sampled, stable=%u\n", rd_p(P_STABLE_CNT));

        /* 2. FE/KDF（PL 内派生） */
        uint32_t k_used = 0;
        if (dec_derive(dc, &k_used) != 0) continue;
        printf("[sec] fe_done k_used=%u\n", k_used);

        /* 3. 解封 canary.bin（小流，CTR 对称） */
        {
            uint8_t blob[CANARY_BLOB_BYTES];
            memcpy(g_scr, can_cipher, sizeof can_cipher);
            memset(g_scr + sizeof can_cipher, 0, 64);
            (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
            (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
            if (have_dc) dcache_clean(g_scr, 128);
            wr_c(D_CTRL2, 1u);
            int rc = wdec_pass(cc->nonce, 0, 0, g_scr_in_pa, g_scr_out_pa,
                               CANARY_BLOB_BYTES);
            wr_c(D_CTRL2, 0u);
            if (rc != 0) { fprintf(stderr, "[sec] unseal DMA fail rc=%d\n", rc); continue; }
            (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
            if (have_dc) dcache_inval(g_scr + (g_scr_out_pa - g_scr_in_pa), 64);
            (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
            memcpy(blob, g_scr + (g_scr_out_pa - g_scr_in_pa), sizeof blob);
            if (memcmp(blob, CANARY_MAGIC, 4) != 0 ||
                blob[4] != 0 || blob[5] != 0 || blob[6] != 0 ||
                blob[7] != (uint8_t)CANARY_VER) {
                fprintf(stderr, "[sec] canary magic/version mismatch (key drift or corrupted)\n");
                continue;
            }
            printf("[sec] canary unsealed\n");

            /* 4. HD 门禁 */
            uint32_t hd = hd_sel66(dc, resp, blob + 8);
            g_bi.hd_final = hd;
            if (hd > cc->t_refuse) {
                printf("[sec] HD=%u > T_REFUSE=%u, retry\n", hd, cc->t_refuse);
                continue;
            }
            if (hd > cc->t_clean)
                printf("[sec] WARNING HD=%u in (T_CLEAN..T_REFUSE], canary arbitrates\n", hd);
            else
                printf("[sec] HD=%u <= T_CLEAN, clean path\n", hd);

            /* 5. 解密权重流 [X|b|W_enc] -> [X|b|W_dec] */
            {
                uint32_t *inw = (uint32_t *)g_scr;
                for (uint32_t i = 0; i < SEC_X_WORDS; i++) inw[i] = 0xC0DEC0DEu;
                if (fseek(fb, 0, SEEK_SET) != 0 ||
                    fread(inw + SEC_X_WORDS, 1, B_BYTES, fb) != B_BYTES) {
                    fprintf(stderr, "[sec] read b failed\n"); continue;
                }
                if (fseek(fw, 0, SEEK_SET) != 0 ||
                    fread(inw + SEC_PLAIN_WORDS, 1, W_BYTES, fw) != W_BYTES) {
                    fprintf(stderr, "[sec] read W_enc failed\n"); continue;
                }
                (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
                (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
                if (have_dc) dcache_clean(g_scr, SEC_STREAM_BYTES);
                wr_c(D_CTRL2, 1u);
                double t0 = now_s();
                rc = wdec_pass(dc->nonce, dc->ctr_init, dc->plain_words,
                               g_scr_in_pa, g_scr_out_pa, SEC_STREAM_BYTES);
                double dec_ms = (now_s() - t0) * 1e3;
                wr_c(D_CTRL2, 0u);
                if (rc != 0) { fprintf(stderr, "[sec] decrypt DMA fail rc=%d\n", rc); continue; }
                (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
                if (have_dc) dcache_inval(g_scr + (g_scr_out_pa - g_scr_in_pa), SEC_STREAM_BYTES);
                (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
                install_weights_from(g_scr + (g_scr_out_pa - g_scr_in_pa));
                /* 明文 W 立即清出 scratch（常驻区副本由失败路径负责清） */
                secure_wipe(g_scr + (g_scr_out_pa - g_scr_in_pa), SEC_STREAM_BYTES);
                (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
                /* 关键：wdec 永远串在 DMA->GEMM 通路上（axis_route2 只管输出选路）。
                   probe/推理/L3 的流是明文，必须置全直通，否则 word>=plain_words
                   的数据被 XOR keystream（表现为确定但错误 / 全 NaN）。 */
                wr_c(D_PLAIN_WORDS, 0xFFFFFFFFu);
                g_bi.dec_ms_x100 = (uint32_t)(dec_ms * 100.0 + 0.5);
                g_bi.fe_k_used   = k_used;
                printf("[sec] weights decrypted+installed (%.1f ms)\n", dec_ms);
            }

            /* 6. Canary：probe 推理比对封印的 SHA256(Y) */
            {
                char yhex[65];
                if (probe_infer(yhex) != 0) { wipe_resident_w(); continue; }
                char want[65];
                for (int i = 0; i < 32; i++) snprintf(want + 2*i, 3, "%02x", blob[20 + i]);
                want[64] = 0;
                if (strcmp(yhex, want) != 0) {
                    fprintf(stderr, "[sec] CANARY FAIL: Y hash mismatch\n");
                    wipe_resident_w();
                    continue;
                }
                printf("[sec] canary hash match\n");
            }
            ok = 1;
            g_bi.boot_ok   = 1;
            g_bi.boot_count++;
            g_bi.attempts  = (uint32_t)att;
            g_bi.wiped     = 0;
            g_bi.w_dirty   = 1;
        }
    }

    fclose(fb);
    fclose(fw);
    scratch_free();

    if (!ok) {
        fprintf(stderr, "[sec] SECURE BOOT REFUSED after %d attempts (weights wiped)\n",
                SEC_ATTEMPTS);
        wipe_resident_w();
        return -1;
    }
    return 0;
}

/*---------------------------------------------------------------------------
 * --seal：一次性封印（生成 canary.bin + fara_canary_config.txt）
 *   前置：ref66 文件（/dev/shm，用后即焚）；密文 W + b 在 enc-dir；
 *   流程：采样 -> FE/KDF -> 解密 -> probe 推理 -> blob 封印 -> 回读自校验
 *-------------------------------------------------------------------------*/
static int do_seal(const dec_cfg_t *dc, const char *ref66_path)
{
    char wp[512], bp[512], cp[512], kp[512];
    snprintf(wp, sizeof wp, "%s/%s", g_enc_dir, W_ENC_NAME);
    snprintf(bp, sizeof bp, "%s/%s", g_enc_dir, B_NAME);
    snprintf(cp, sizeof cp, "%s/canary.bin", g_puf_dir);
    snprintf(kp, sizeof kp, "%s/%s", g_puf_dir, "fara_canary_config.txt");

    /* ref66：17 个 hex（66 bit），bit i = 第 i 个选中位 */
    uint8_t ref66[9];
    {
        FILE *f = fopen(ref66_path, "r");
        if (!f) { perror("open ref66"); return -1; }
        char ln[128];
        if (!fgets(ln, sizeof ln, f)) { fprintf(stderr, "ref66 empty\n"); fclose(f); return -1; }
        fclose(f);
        char *s = ln; while (*s == ' ' || *s == '\t') s++;
        size_t L = strcspn(s, " \t\r\n");
        if (L != 17) { fprintf(stderr, "ref66 needs 17 hex, got %zu\n", L); return -1; }
        for (size_t j = 0; j < 17; j++) {
            char c = s[j];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F'))) {
                fprintf(stderr, "ref66 bad hex char '%c'\n", c);
                return -1;
            }
        }
        s[L] = 0;
        uint64_t v = strtoull(s, NULL, 16);
        for (int i = 0; i < 9; i++) ref66[i] = (uint8_t)((v >> (8 * i)) & 0xFFu);
    }
    /* mask 选中位 >= 3k（前 66 个 mask=1 位参与编码） */
    if (popcnt128(dc->mask) < NSEL_BITS || dc->k != 22) {
        fprintf(stderr, "[seal] mask popcnt/k mismatch\n"); return -1;
    }

    /* canary nonce：权重 nonce 最高字节翻转（确定性派生、必然不同） */
    can_cfg_t cc;
    memset(&cc, 0, sizeof cc);
    memcpy(cc.nonce, dc->nonce, 12);
    cc.nonce[0] ^= 0x80u;
    cc.samp_m = 31; cc.tforce = 8; cc.tsettle = 64;      /* 与 enrollment 同参数 */
    cc.t_clean = 1; cc.t_refuse = 3;

    struct stat st;
    if (stat(wp, &st) != 0 || st.st_size != (off_t)W_BYTES) { fprintf(stderr, "[seal] %s?\n", wp); return -1; }
    if (stat(bp, &st) != 0 || st.st_size != (off_t)B_BYTES) { fprintf(stderr, "[seal] %s?\n", bp); return -1; }

    if (scratch_alloc() != 0) { scratch_free(); return -1; }

    /* 1. 采样 + FE/KDF */
    uint32_t resp[4];
    if (puf_capture(&cc, resp) != 0) { scratch_free(); return -1; }
    uint32_t k_used = 0;
    if (dec_derive(dc, &k_used) != 0) { scratch_free(); return -1; }
    printf("[seal] fe_done k_used=%u\n", k_used);

    /* 2. 解密权重 -> 常驻缓冲 */
    {
        uint32_t *inw = (uint32_t *)g_scr;
        FILE *fb = fopen(bp, "rb");
        FILE *fw = fopen(wp, "rb");
        if (!fb || !fw) { perror("[seal] open model"); if (fb) fclose(fb); if (fw) fclose(fw); scratch_free(); return -1; }
        for (uint32_t i = 0; i < SEC_X_WORDS; i++) inw[i] = 0xC0DEC0DEu;
        if (fread(inw + SEC_X_WORDS, 1, B_BYTES, fb) != B_BYTES ||
            fread(inw + SEC_PLAIN_WORDS, 1, W_BYTES, fw) != W_BYTES) {
            fprintf(stderr, "[seal] short read\n"); fclose(fb); fclose(fw); scratch_free(); return -1;
        }
        fclose(fb); fclose(fw);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
        if (have_dc) dcache_clean(g_scr, SEC_STREAM_BYTES);
        wr_c(D_CTRL2, 1u);
        int rc = wdec_pass(dc->nonce, dc->ctr_init, dc->plain_words,
                           g_scr_in_pa, g_scr_out_pa, SEC_STREAM_BYTES);
        wr_c(D_CTRL2, 0u);                                /* GEMM probe 需要 route0 */
        if (rc != 0) { fprintf(stderr, "[seal] decrypt fail rc=%d\n", rc); scratch_free(); return -1; }
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
        if (have_dc) dcache_inval(g_scr + (g_scr_out_pa - g_scr_in_pa), SEC_STREAM_BYTES);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
        install_weights_from(g_scr + (g_scr_out_pa - g_scr_in_pa));
        secure_wipe(g_scr + (g_scr_out_pa - g_scr_in_pa), SEC_STREAM_BYTES);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
        /* probe 前必须全直通（wdec 串在通路上，见 secure_boot 注释） */
        wr_c(D_PLAIN_WORDS, 0xFFFFFFFFu);
        printf("[seal] weights decrypted+installed\n");
    }

    /* 3. probe 推理 */
    char yhex[65];
    if (probe_infer(yhex) != 0) { wr_c(D_CTRL2, 0u); scratch_free(); wipe_resident_w(); return -1; }

    /* 4. 构造 blob 并封印（加密与解密同一运算，输出即密文） */
    uint8_t blob[CANARY_BLOB_BYTES], cipher[CANARY_BLOB_BYTES];
    memset(blob, 0, sizeof blob);
    memcpy(blob, CANARY_MAGIC, 4);
    blob[7] = (uint8_t)CANARY_VER;
    memcpy(blob + 8, ref66, 9);
    {
        uint8_t yraw[32];
        for (int i = 0; i < 32; i++) { char t[3] = { yhex[2*i], yhex[2*i+1], 0 }; yraw[i] = (uint8_t)strtoul(t, 0, 16); }
        memcpy(blob + 20, yraw, 32);
    }
    memcpy(g_scr, blob, sizeof blob);
    memset(g_scr + sizeof blob, 0, 64);
    (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
    (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
    if (have_dc) dcache_clean(g_scr, 128);
    wr_c(D_CTRL2, 1u);
    int rc = wdec_pass(cc.nonce, 0, 0, g_scr_in_pa, g_scr_out_pa, CANARY_BLOB_BYTES);
    if (rc != 0) { fprintf(stderr, "[seal] seal fail rc=%d\n", rc); wr_c(D_CTRL2, 0u); scratch_free(); wipe_resident_w(); return -1; }

    /* 5. 回读自校验：把密文再过一遍引擎，必须还原出 blob */
    {
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
        if (have_dc) dcache_inval(g_scr + (g_scr_out_pa - g_scr_in_pa), 64);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
        memcpy(cipher, g_scr + (g_scr_out_pa - g_scr_in_pa), sizeof cipher);

        memcpy(g_scr, cipher, sizeof cipher);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
        if (have_dc) dcache_clean(g_scr, 128);
        rc = wdec_pass(cc.nonce, 0, 0, g_scr_in_pa, g_scr_out_pa, CANARY_BLOB_BYTES);
        wr_c(D_CTRL2, 0u);
        if (rc != 0) { fprintf(stderr, "[seal] verify fail rc=%d\n", rc); scratch_free(); wipe_resident_w(); return -1; }
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_READ);
        if (have_dc) dcache_inval(g_scr + (g_scr_out_pa - g_scr_in_pa), 64);
        (void)buf_sync(g_scr_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_READ);
        if (memcmp(g_scr + (g_scr_out_pa - g_scr_in_pa), blob, sizeof blob) != 0) {
            fprintf(stderr, "[seal] VERIFY FAIL: round-trip mismatch\n");
            scratch_free(); wipe_resident_w(); return -1;
        }
    }
    printf("[seal] round-trip verify OK\n");

    /* 6. 落盘（root 目录，程序以 root 运行） */
    {
        FILE *f = fopen(cp, "wb");
        if (!f || fwrite(cipher, 1, sizeof cipher, f) != sizeof cipher) {
            perror(cp); if (f) fclose(f); scratch_free(); wipe_resident_w(); return -1;
        }
        fclose(f);
        f = fopen(kp, "w");
        if (!f) { perror(kp); scratch_free(); wipe_resident_w(); return -1; }
        fprintf(f, "# generated by fara_infer_server --seal\n");
        fprintf(f, "CANARY_NONCE=");
        for (int i = 0; i < 12; i++) fprintf(f, "%02x", cc.nonce[i]);
        fprintf(f, "\nSAMP_M=%u\nSAMP_TFORCE=%u\nSAMP_TSETTLE=%u\n", cc.samp_m, cc.tforce, cc.tsettle);
        fprintf(f, "T_CLEAN=%u\nT_REFUSE=%u\n", cc.t_clean, cc.t_refuse);
        fclose(f);
    }
    {
        char chex[65];
        sha256_mem(cipher, sizeof cipher, chex);
        printf("[seal] canary.bin sha256=%s\n", chex);
        printf("[seal] probe sha256(Y0)=%s\n", yhex);
    }

    scratch_free();
    wipe_resident_w();                                    /* seal 模式不留明文 */
    printf("[seal] DONE. ref66 载体文件务必立即销毁。\n");
    return 0;
}

/*---------------------------------------------------------------------------
 * socket 收发
 *-------------------------------------------------------------------------*/
static int recv_all(int fd, void *buf, size_t n)
{
    uint8_t *p = buf;
    while (n) {
        ssize_t r = recv(fd, p, n, 0);
        if (r == 0) return -1;
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        p += r; n -= (size_t)r;
    }
    return 0;
}

static int send_all(int fd, const void *buf, size_t n)
{
    const uint8_t *p = buf;
    while (n) {
        ssize_t r = send(fd, p, n, MSG_NOSIGNAL);
        if (r < 0) { if (errno == EINTR) continue; return -1; }
        p += r; n -= (size_t)r;
    }
    return 0;
}

/*---------------------------------------------------------------------------
 * FARC 控制处理（8-x 实时集成）
 *   STATUS   启动链现场 + W/密文双 hash（防篡改视图）
 *   FLIP     对常驻明文 W 指定位翻转（模拟攻击者物理位注入的执行端）
 *   WIPE     清零常驻明文 W（演示"明文丢失"）
 *   RESTORE  重新走完整 secure_boot（PUF 采样→FE/KDF→解密→Canary）
 *-------------------------------------------------------------------------*/
static int send_ctrl(int cfd, uint32_t status, const uint32_t *w, uint32_t n)
{
    uint32_t h[3];
    memcpy((char *)h, "FARC", 4);
    h[1] = status;
    h[2] = n;
    if (send_all(cfd, h, sizeof h) != 0) return -1;
    if (n && send_all(cfd, w, (size_t)n * 4u) != 0) return -1;
    return 0;
}

static void w_hash_refresh(void)
{
    if (!g_bi.w_dirty) return;
    if (g_bi.wiped) memset(g_bi.w_hash, 0, sizeof g_bi.w_hash);
    else sha256_raw_words(g_buf + W_OFF, W_BYTES, g_bi.w_hash);
    g_bi.w_dirty = 0;
}

/* STATUS 载荷 24 字：0..7 现场 / 8..15 W hash / 16..23 SD 密文 hash */
static void ctrl_status_words(uint32_t w[24])
{
    memset(w, 0, 24u * 4u);
    w_hash_refresh();
    w[0] = g_bi.boot_ok;
    w[1] = g_bi.hd_final;
    w[2] = g_bi.fe_k_used;
    w[3] = g_bi.dec_ms_x100;
    w[4] = g_bi.n_flips;
    w[5] = g_bi.wiped;
    w[6] = g_bi.boot_count;
    w[7] = g_bi.attempts;
    memcpy(w + 8,  g_bi.w_hash, 32u);
    memcpy(w + 16, g_bi.enc_hash, 32u);
}

/* 返回 0 = 连接继续；-1 = 断开 */
static int handle_ctrl(int cfd, const ctrl_req_t *cq)
{
    uint32_t w[24];

    switch (cq->op) {
    case FARC_STATUS:
        ctrl_status_words(w);
        return send_ctrl(cfd, 0, w, 24) == 0 ? 0 : -1;

    case FARC_FLIP: {
        uint32_t idx = cq->p0, bit = cq->p1;
        if (cq->p2 != 0 || idx >= HW_M_TOTAL * HW_K || bit >= 32) {
            return send_ctrl(cfd, 1, NULL, 0) == 0 ? 0 : -1;   /* 1=参数拒绝 */
        }
        {
            uint32_t *wp  = (uint32_t *)(g_buf + W_OFF);
            uint32_t  old = wp[idx];
            wp[idx] = old ^ (1u << bit);
            /* PS 写的是 cache 副本，GEMM 走 DMA 读 DDR —— 必须推到内存 */
            (void)buf_sync(g_buf_fd, DMA_BUF_SYNC_START | DMA_BUF_SYNC_WRITE);
            (void)buf_sync(g_buf_fd, DMA_BUF_SYNC_END | DMA_BUF_SYNC_WRITE);
            if (have_dc) dcache_clean(g_buf + W_OFF + (size_t)idx * 4u, 4);
            g_bi.n_flips++;
            g_bi.w_dirty = 1;
            w[0] = idx;
            w[1] = old;
            w[2] = wp[idx];
        }
        return send_ctrl(cfd, 0, w, 3) == 0 ? 0 : -1;
    }

    case FARC_WIPE:
        wipe_resident_w();
        w[0] = 1;
        return send_ctrl(cfd, 0, w, 1) == 0 ? 0 : -1;

    case FARC_RESTORE: {
        /* 完整重走安全启动：采样→派生→解封→HD门禁→解密→Canary（≈100ms） */
        int st = secure_boot(&g_dc, &g_cc);
        ctrl_status_words(w);
        return send_ctrl(cfd, st == 0 ? 0 : 2, w, 24) == 0 ? 0 : -1;  /* 2=拒绝 */
    }

    default:
        return send_ctrl(cfd, 1, NULL, 0) == 0 ? 0 : -1;
    }
}

static int handle_conn(int cfd)
{
    req_hdr_t rh;
    uint32_t ent[FAR_MAX_ENT * 5];
    uint32_t *x_words = NULL;
    uint32_t *y_words = NULL;
    int rc = 0;

    for (;;) {
        rsp_hdr_t sh;
        uint32_t far_hits = 0, far_phase = 0;
        double ms = 0.0;
        int st;

        if (recv_all(cfd, &rh, sizeof rh) != 0) break;      /* 对端关闭 */
        if (memcmp(rh.magic, "FARC", 4) == 0) {             /* 控制报文 */
            ctrl_req_t cq;
            memcpy(cq.magic, rh.magic, 4);
            cq.op = rh.mode; cq.p0 = rh.n_far; cq.p1 = rh.n_tok; cq.p2 = rh.rsv;
            if (handle_ctrl(cfd, &cq) != 0) break;
            continue;
        }
        if (memcmp(rh.magic, "FARQ", 4) != 0) {
            fprintf(stderr, "[srv] bad req magic\n");
            break;
        }
        if (rh.n_far > FAR_MAX_ENT || rh.n_tok == 0 || rh.n_tok > HW_N_MAX) {
            fprintf(stderr, "[srv] bad params n_far=%u n_tok=%u\n", rh.n_far, rh.n_tok);
            memset(&sh, 0, sizeof sh);
            memcpy(sh.magic, "FARS", 4);
            sh.status = 1;
            send_all(cfd, &sh, sizeof sh);
            break;
        }
        if (rh.n_far && recv_all(cfd, ent, 5u * 4u * rh.n_far) != 0) break;

        if (!x_words) x_words = malloc(X_BYTES);
        if (!y_words) y_words = malloc(OUT_BYTES);
        if (!x_words || !y_words) { fprintf(stderr, "[srv] oom\n"); rc = -1; break; }

        if (recv_all(cfd, x_words, (size_t)rh.n_tok * HW_K * 4u) != 0) break;

        program_farmap(ent, rh.n_far);
        wr_g(R_FAR_CTRL, rh.mode ? 1u : 0u);
        load_x(x_words, rh.n_tok);

        st = run_once(rh.mode ? 1 : 0, &far_hits, &far_phase, &ms);
        collect_y(y_words, rh.n_tok);

        memset(&sh, 0, sizeof sh);
        memcpy(sh.magic, "FARS", 4);
        sh.status     = (st == 0) ? 0u : (uint32_t)(-st);
        sh.n_tok      = rh.n_tok;
        sh.m_total    = HW_M_TOTAL;
        sh.far_hits   = far_hits;
        sh.far_phase  = far_phase;
        sh.elapsed_ms = (uint32_t)(ms + 0.5);
        if (send_all(cfd, &sh, sizeof sh) != 0) break;
        if (sh.status == 0 &&
            send_all(cfd, y_words, (size_t)rh.n_tok * HW_M_TOTAL * 4u) != 0) break;
    }

    free(x_words);
    free(y_words);
    return rc;
}

/*---------------------------------------------------------------------------
 * 主流程
 *-------------------------------------------------------------------------*/
int main(int argc, char **argv)
{
    int port = DEF_PORT;
    int selftest = 0, seal = 0;
    const char *ref66_path = NULL;
    int i;

    for (i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--selftest") == 0) selftest = 1;
        else if (strcmp(argv[i], "--seal") == 0) seal = 1;
        else if (strncmp(argv[i], "--port=", 7) == 0) port = atoi(argv[i] + 7);
        else if (strncmp(argv[i], "--src=", 6) == 0) g_enc_dir = argv[i] + 6;
        else if (strncmp(argv[i], "--enc-dir=", 10) == 0) g_enc_dir = argv[i] + 10;
        else if (strncmp(argv[i], "--puf-dir=", 10) == 0) g_puf_dir = argv[i] + 10;
        else if (strncmp(argv[i], "--ref66=", 8) == 0) ref66_path = argv[i] + 8;
        else if (argv[i][0] != '-') g_enc_dir = argv[i];
    }

    printf("=== fara_infer_server: 安全权重（PUF门禁+解密+canary）+ 硬件 FaR 推理 ===\n");
    printf("enc-dir : %s\npuf-dir : %s\n", g_enc_dir, g_puf_dir);
    if (seal && !ref66_path) {
        fprintf(stderr, "--seal 需要 --ref66=<file>（/dev/shm 下，用后即焚）\n");
        return 2;
    }

    /* ---- 0. 配置加载：dec 必需；canary 配置仅服务模式需要 ---- */
    dec_cfg_t dc;
    memset(&dc, 0, sizeof dc);
    {
        char p[512];
        snprintf(p, sizeof p, "%s/fara_dec_config.txt", g_puf_dir);
        if (load_cfg(p, &dc) != 0) return 2;
        printf("[cfg] k=%u plain_words=%u ctr_init=%u\n",
               dc.k, dc.plain_words, dc.ctr_init);
    }
    can_cfg_t cc;
    memset(&cc, 0, sizeof cc);
    if (!seal) {
        char p[512];
        snprintf(p, sizeof p, "%s/fara_canary_config.txt", g_puf_dir);
        if (load_can_cfg(p, &cc) != 0) {
            fprintf(stderr, "[cfg] canary config 缺失（先跑 --seal）\n");
            return 2;
        }
        printf("[cfg] canary T_CLEAN=%u T_REFUSE=%u M=%u\n",
               cc.t_clean, cc.t_refuse, cc.samp_m);
    }
    g_dc = dc;      /* 供 RESTORE（FARC）复用 secure_boot */
    g_cc = cc;

    /* ---- 1. dma_heap 常驻缓冲 ---- */
    g_buflen = IN_BYTES + OUT_BYTES;
    g_buflen = (g_buflen + 0x200000u - 1u) & ~(size_t)(0x200000u - 1u);
    if (g_buflen < 0x200000u) g_buflen = 0x200000u;

    if (heap_alloc(g_buflen, &g_buf_fd) != 0) {
        fprintf(stderr, "[srv] dma_heap 分配失败: %s\n", strerror(errno));
        return 1;
    }
    g_buf = mmap(NULL, g_buflen, PROT_READ | PROT_WRITE, MAP_SHARED, g_buf_fd, 0);
    if (g_buf == MAP_FAILED) { perror("mmap"); return 1; }
    memset(g_buf, 0, g_buflen);

    {
        const char *why = "";
        g_pa = va_to_pa(g_buf, &why);
        if (!g_pa) { fprintf(stderr, "[srv] 取物理地址失败: %s（需 root）\n", why); return 1; }
    }
    g_in_pa  = g_pa;
    g_out_pa = g_pa + IN_BYTES;
    have_dc  = probe_dc();

    printf("[srv] 缓冲 %zu B @ phys 0x%010llX  (in +%u, out @+%u)  EL0cache=%s\n",
           g_buflen, (unsigned long long)g_pa, (unsigned)IN_BYTES,
           (unsigned)IN_BYTES, have_dc ? "yes" : "no");

    /* ---- 2. 映射 PL 寄存器（DMA / GEMM / puf_dec / PUF）---- */
    {
        int fdmem = open("/dev/mem", O_RDWR | O_SYNC);
        void *pm, *pg, *pc, *pp;
        uint32_t ver;
        if (fdmem < 0) { perror("open /dev/mem (need root)"); return 1; }
        pm = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, DMA_BASE);
        if (pm == MAP_FAILED) { perror("mmap DMA"); return 1; }
        dma = (volatile uint32_t *)pm;
        pg = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, GEMM_BASE);
        if (pg == MAP_FAILED) { perror("mmap GEMM"); return 1; }
        gemm = (volatile uint32_t *)pg;
        pc = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, DEC_BASE);
        if (pc == MAP_FAILED) { perror("mmap DEC"); return 1; }
        dec = (volatile uint32_t *)pc;
        pp = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fdmem, PUF_BASE);
        if (pp == MAP_FAILED) { perror("mmap PUF"); return 1; }
        puf = (volatile uint32_t *)pp;

        ver = rd_g(R_VERSION);
        printf("[srv] GEMM VERSION = 0x%08X  expect 0x%08X  %s\n",
               ver, HW_VERSION, ver == HW_VERSION ? "OK" : "FAIL");
        if (ver != HW_VERSION) {
            fprintf(stderr, "[srv] PL 不是 FaR 版 bitstream（需 0x0002_0000）\n");
            return 2;
        }
        printf("[srv] DEC VERSION = 0x%08X  expect 0x%08X  %s\n",
               rd_c(D_VERSION), DEC_VERSION,
               rd_c(D_VERSION) == DEC_VERSION ? "OK" : "FAIL");
        printf("[srv] PUF VERSION = 0x%08X  expect 0x%08X  %s\n",
               rd_p(P_VERSION), PUF_VERSION,
               rd_p(P_VERSION) == PUF_VERSION ? "OK" : "FAIL");
        printf("[srv] M_ROWS=%u  N_TILES=%u\n", rd_g(R_M_ROWS), rd_g(R_N_TILES));
    }

    /* ---- 3. 安全启动：seal（一次性）或 PUF门禁+解密+canary ---- */
    if (seal) {
        if (do_seal(&dc, ref66_path) != 0) {
            fprintf(stderr, "[srv] SEAL FAILED\n");
            return 3;
        }
        printf("[srv] seal 完成，退出（服务模式另次启动）\n");
        munmap(g_buf, g_buflen);
        close(g_buf_fd);
        return 0;
    }
    if (secure_boot(&dc, &cc) != 0) {
        fprintf(stderr, "[srv] SECURE BOOT FAILED，拒绝服务（权重已清零）\n");
        munmap(g_buf, g_buflen);
        close(g_buf_fd);
        return 3;
    }

    /* ---- 4. 密文指纹（证据留痕；明文 W 已不存在） ---- */
    {
        char hp[512], hw[65], hb[65];
        snprintf(hp, sizeof hp, "%s/%s", g_enc_dir, W_ENC_NAME);
        if (sha256_file(hp, hw) == 0) printf("[srv] W_enc sha256 %s\n", hw);
        sha256_file_raw(hp, g_bi.enc_hash);          /* FARC STATUS 静态加密指纹 */
        snprintf(hp, sizeof hp, "%s/%s", g_enc_dir, B_NAME);
        if (sha256_file(hp, hb) == 0) printf("[srv] b sha256 %s\n", hb);
    }

    /* ---- 5. 公布地址表 ---- */
    {
        FILE *f = fopen(OUT_JSON, "w");
        if (f) {
            fprintf(f,
                "{\n  \"phys_addr\": %llu,\n  \"phys_addr_hex\": \"0x%010llX\",\n"
                "  \"size\": %zu,\n  \"in_bytes\": %u,\n  \"out_bytes\": %u,\n"
                "  \"layout\": { \"X_words\": %u, \"b\": %u, \"W\": %u },\n"
                "  \"n_max\": %u,\n  \"pid\": %d\n}\n",
                (unsigned long long)g_pa, (unsigned long long)g_pa,
                g_buflen, (unsigned)IN_BYTES, (unsigned)OUT_BYTES,
                (unsigned)X_WORDS, (unsigned)B_OFF, (unsigned)W_OFF,
                (unsigned)HW_N_MAX, (int)getpid());
            fclose(f);
        }
    }

    signal(SIGINT, on_sig);
    signal(SIGTERM, on_sig);

    /* ---- 6. selftest：一次零输入推理，确认通路 ---- */
    if (selftest) {
        uint32_t *xw = calloc(X_WORDS, 4);
        uint32_t *yw = calloc(OUT_WORDS, 4);
        uint32_t hits = 0, phase = 0;
        double ms = 0;
        int st;
        /* 用一个可辨识的 X（前 8 维递增），避免全 0 掩盖通路问题 */
        for (i = 0; i < 8; i++) xw[i] = 0x3F800000u + (uint32_t)i;   /* ~1.0.. */
        wr_g(R_FAR_CTRL, 0);
        load_x(xw, 1);
        st = run_once(0, &hits, &phase, &ms);
        collect_y(yw, 1);
        printf("[selftest] status=%d elapsed=%.1f ms far_hits=%u phase=%u\n",
               st, ms, hits, phase);
        printf("[selftest] Y[0..3] = %.6g %.6g %.6g %.6g\n",
               bits_to_f32(yw[0]), bits_to_f32(yw[1]),
               bits_to_f32(yw[2]), bits_to_f32(yw[3]));
        free(xw); free(yw);
        printf("[selftest] 通路%s\n", st == 0 ? "OK" : "FAIL");
        return st == 0 ? 0 : 3;
    }

    /* ---- 7. TCP 服务 ---- */
    {
        int lfd, one = 1;
        struct sockaddr_in addr;
        lfd = socket(AF_INET, SOCK_STREAM, 0);
        if (lfd < 0) { perror("socket"); return 1; }
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
        memset(&addr, 0, sizeof addr);
        addr.sin_family = AF_INET;
        addr.sin_addr.s_addr = htonl(INADDR_ANY);
        addr.sin_port = htons((uint16_t)port);
        if (bind(lfd, (struct sockaddr *)&addr, sizeof addr) != 0) {
            perror("bind"); return 1;
        }
        if (listen(lfd, 4) != 0) { perror("listen"); return 1; }
        printf("\n[srv] 权重已常驻（phys 0x%010llX），监听 0.0.0.0:%d\n",
               (unsigned long long)g_pa, port);
        printf("[srv] 协议: FARQ(mode,n_far,n_tok)+FaRMap+X -> FARS+Y  |  FARC(op) 控制通道\n");
        fflush(stdout);

        while (!g_stop) {
            int cfd;
            struct timeval tv;
            fd_set rfds;
            FD_ZERO(&rfds);
            FD_SET(lfd, &rfds);
            tv.tv_sec = 1; tv.tv_usec = 0;
            if (select(lfd + 1, &rfds, NULL, NULL, &tv) <= 0) continue;
            cfd = accept(lfd, NULL, NULL);
            if (cfd < 0) { if (errno == EINTR) continue; perror("accept"); continue; }
            setsockopt(cfd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof one);
            printf("[srv] 连接建立，开始服务\n");
            fflush(stdout);
            handle_conn(cfd);
            close(cfd);
            printf("[srv] 连接关闭\n");
            fflush(stdout);
        }
        close(lfd);
    }

    printf("[srv] 退出，释放缓冲\n");
    munmap(g_buf, g_buflen);
    close(g_buf_fd);
    unlink(OUT_JSON);
    return 0;
}
