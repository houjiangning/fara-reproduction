/*
 * gemm_probe.c -- up_proj GEMM AXI-Lite 寄存器探针 (L2)
 *
 * 用途：验证 gemm_up_proj_bd_0/S_AXI 是否已挂上 AXI 总线、地址译码是否正确。
 *       基地址 0xA0010000 / 64KB 来自 Vivado Address Editor。
 *       寄存器映射来自 rtl/gemm_up_proj_axi_lite.sv，逐条对应。
 *
 * 输出刻意用 ASCII，避免串口工具按 GBK 解析 UTF-8 出现乱码。
 *
 * 编译：gcc -O2 -o gemm_probe gemm_probe.c
 * 运行：sudo ./gemm_probe
 */

#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define GEMM_BASE   0xA0010000UL
#define MAP_SIZE    0x10000UL       /* 64 KB，与 Address Editor 一致 */

/* 寄存器字节偏移（gemm_up_proj_axi_lite.sv） */
#define R_CTRL       0x00   /* W  [0]start [1]soft_rst [2]irq_en            */
#define R_STATUS     0x04   /* R  [0]busy [1]done [2]err [3]irq [7:4]state  */
#define R_M_ROWS     0x08   /* R  M_TILE = 16                               */
#define R_K_COLS     0x0C   /* RW 规约深度 K，复位值 768                    */
#define R_N_TOKENS   0x10   /* RW token 数 N，复位值 1                      */
#define R_LAYER_ID   0x14   /* RW 层标识，复位值 0                          */
#define R_VERSION    0x18   /* R  0x00020000（FaR 版）                       */
#define R_N_TILES    0x1C   /* R  M_TOTAL/M_TILE = 192                      */
#define R_IN_WORDS   0x20   /* R  已消费输入字数                            */
#define R_OUT_WORDS  0x24   /* R  已产出输出字数                            */
#define R_TILE_IDX   0x28   /* R  当前趟号                                  */
#define R_STATE      0x2C   /* R  FSM 状态码                                */

/* FaRMap 寄存器组（间接寻址：先写 FAR_IDX，再读写 FAR_A/INV/ND/D0/D1） */
#define R_FAR_CTRL   0x30   /* RW [0] far_en                                */
#define R_FAR_NENT   0x34   /* RW [4:0] 条目数                              */
#define R_FAR_IDX    0x38   /* RW [3:0] 当前条目下标                        */
#define R_FAR_A      0x3C   /* RW [15:0] 敏感通道 A                         */
#define R_FAR_INV    0x40   /* RW fp32 1/div                                */
#define R_FAR_ND     0x44   /* RW [1:0] dead 条数                           */
#define R_FAR_D0     0x48   /* RW [15:0] dead #0                            */
#define R_FAR_D1     0x4C   /* RW [15:0] dead #1                            */
#define R_FAR_HITS   0x50   /* R  重路由改写元素数                          */
#define R_FAR_PHASE  0x54   /* R  far_reroute 相位码                        */

#define HW_VERSION   0x00020000u

static volatile uint32_t *g;

static uint32_t rd(unsigned off)             { return g[off >> 2]; }
static void     wr(unsigned off, uint32_t v) { g[off >> 2] = v; }

static int fails;

static void check_eq(const char *nm, unsigned off, uint32_t got, uint32_t want)
{
    int ok = (got == want);
    printf("%-10s (0x%02X) = 0x%08X   expect 0x%08X   %s\n",
           nm, off, got, want, ok ? "OK" : "FAIL");
    if (!ok) fails++;
}

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) { perror("open /dev/mem"); return 1; }

    void *p = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, GEMM_BASE);
    if (p == MAP_FAILED) { perror("mmap"); close(fd); return 1; }
    g = (volatile uint32_t *)p;

    printf("up_proj GEMM @ 0x%08lX (mapped %lu KB)\n\n", GEMM_BASE, MAP_SIZE / 1024);

    printf("--- 只读常量寄存器 ---\n");
    check_eq("VERSION",  R_VERSION, rd(R_VERSION), HW_VERSION);
    check_eq("M_ROWS",   R_M_ROWS,  rd(R_M_ROWS),  16u);
    check_eq("N_TILES",  R_N_TILES, rd(R_N_TILES), 192u);

    printf("\n--- 地址译码（未映射偏移应返回 0xDEADBEEF）---\n");
    check_eq("0x60", 0x60, rd(0x60), 0xDEADBEEFu);
    check_eq("0x80", 0x80, rd(0x80), 0xDEADBEEFu);

    printf("\n--- 读写回环 ---\n");
    struct { const char *nm; unsigned off; uint32_t val; } rw[] = {
        { "K_COLS",   R_K_COLS,   768u       },
        { "K_COLS",   R_K_COLS,   8u         },
        { "N_TOKENS", R_N_TOKENS, 1u         },
        { "N_TOKENS", R_N_TOKENS, 4u         },
        { "LAYER_ID", R_LAYER_ID, 0x1234ABCDu},
        { "LAYER_ID", R_LAYER_ID, 0u         },
    };
    for (unsigned i = 0; i < sizeof(rw) / sizeof(rw[0]); i++) {
        wr(rw[i].off, rw[i].val);
        uint32_t got = rd(rw[i].off);
        int ok = (got == rw[i].val);
        printf("%-10s (0x%02X) write 0x%08X -> read 0x%08X   %s\n",
               rw[i].nm, rw[i].off, rw[i].val, got, ok ? "OK" : "FAIL");
        if (!ok) fails++;
    }

    /* 恢复复位默认值，避免影响后续 L3 */
    wr(R_K_COLS, 768);
    wr(R_N_TOKENS, 1);
    wr(R_LAYER_ID, 0);

    printf("\n--- 状态寄存器 ---\n");
    uint32_t st = rd(R_STATUS);
    printf("STATUS (0x04) = 0x%08X   busy=%u done=%u err=%u state=%u\n",
           st, st & 1u, (st >> 1) & 1u, (st >> 2) & 1u, (st >> 4) & 0xFu);
    printf("STATE  (0x2C) = %u\n", rd(R_STATE));
    printf("IN_WORDS  = %u\n", rd(R_IN_WORDS));
    printf("OUT_WORDS = %u\n", rd(R_OUT_WORDS));
    printf("TILE_IDX  = %u\n", rd(R_TILE_IDX));

    printf("\n--- FaRMap 寄存器组（间接寻址）---\n");
    /* 顺序必须是：写 FAR_IDX -> 写该条目的 5 个字段 */
    wr(R_FAR_CTRL, 0x0);
    wr(R_FAR_NENT, 8);
    check_eq("FAR_NENT",  R_FAR_NENT, rd(R_FAR_NENT), 8u);

    wr(R_FAR_IDX, 0);
    wr(R_FAR_A,   767u);
    wr(R_FAR_INV, 0x3F000000u);   /* 1/2 = 0.5 */
    wr(R_FAR_ND,  1u);
    wr(R_FAR_D0,  0u);
    wr(R_FAR_D1,  0u);
    check_eq("FAR_A[0]",   R_FAR_A,   rd(R_FAR_A),   767u);
    check_eq("FAR_INV[0]", R_FAR_INV, rd(R_FAR_INV), 0x3F000000u);

    /* 写第 3 条后切回第 0 条，确认索引真的在切换（不是恒写第 0 条） */
    wr(R_FAR_IDX, 3);
    wr(R_FAR_A,   765u);
    wr(R_FAR_IDX, 0);
    check_eq("FAR_A[0]rw", R_FAR_A, rd(R_FAR_A), 767u);
    wr(R_FAR_IDX, 3);
    check_eq("FAR_A[3]",   R_FAR_A, rd(R_FAR_A), 765u);

    /* 清干净，别把测试值留给 L4 */
    wr(R_FAR_CTRL, 0);
    wr(R_FAR_NENT, 0);
    printf("    FAR_HITS  = %u (空闲应为 0)\n", rd(R_FAR_HITS));
    printf("    FAR_PHASE = %u (空闲应为 0)\n", rd(R_FAR_PHASE));

    printf("\n");
    if (fails) {
        printf(">>> L2 FAIL: %d check(s) failed.\n", fails);
        printf("    检查 Address Editor: gemm_up_proj_bd_0/S_AXI = 0xA0010000 / 64K\n");
        printf("    检查 BD: smartconnect M01_AXI -> gemm_up_proj_bd_0/s_axi\n");
    } else {
        printf(">>> L2 PASS: GEMM AXI-Lite registers read/write correctly.\n");
        printf("    GEMM 从接口已挂上总线，可以进入 L3 (DMA 喂数据对 golden)。\n");
    }

    munmap(p, MAP_SIZE);
    close(fd);
    return fails ? 2 : 0;
}
