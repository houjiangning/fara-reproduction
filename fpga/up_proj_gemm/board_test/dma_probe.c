/*
 * dma_probe.c — AXI DMA 寄存器探针
 *
 * 用途：在 ZCU106 上验证 bitstream 加载后，PL 侧的 AXI DMA 是否可被 ARM 访问。
 *       这一步同时验证三件事：
 *         1) bitstream 已正确加载到 PL
 *         2) PL 时钟（pl_clk0 = 100MHz）在跑
 *         3) PS 的 M_AXI_HPM0_FPD 控制通路已使能
 *
 * 寄存器偏移来自 AXI DMA v7.1 (PG021) 的 Simple / Direct Register 模式寄存器表。
 * 基地址 0xA0000000 来自 Vivado Address Editor 中 axi_dma_0/S_AXI_LITE 的分配结果。
 *
 * 编译：gcc -O2 -o dma_probe dma_probe.c
 * 运行：sudo ./dma_probe
 */

#include <stdio.h>
#include <stdint.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/mman.h>

#define DMA_BASE    0xA0000000UL
#define MAP_SIZE    0x10000UL   /* 64 KB，与 Address Editor 中的分配一致 */

/* Simple 模式寄存器偏移 */
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

/* DMACR 位 */
#define DMACR_RS      (1u << 0)   /* Run/Stop：1=运行，0=停止 */
#define DMACR_RESET   (1u << 2)   /* 软复位，自清零 */

/* DMASR 位 */
#define DMASR_HALTED  (1u << 0)   /* 1=通道已停止 */
#define DMASR_IDLE    (1u << 1)   /* 1=传输完成、通道空闲 */

static volatile uint32_t *dma;

static uint32_t rd(unsigned off)            { return dma[off >> 2]; }
static void     wr(unsigned off, uint32_t v){ dma[off >> 2] = v; }

int main(void)
{
    int fd = open("/dev/mem", O_RDWR | O_SYNC);
    if (fd < 0) {
        perror("open /dev/mem");
        return 1;
    }

    void *p = mmap(NULL, MAP_SIZE, PROT_READ | PROT_WRITE, MAP_SHARED, fd, DMA_BASE);
    if (p == MAP_FAILED) {
        perror("mmap");
        close(fd);
        return 1;
    }
    dma = (volatile uint32_t *)p;

    printf("AXI DMA @ 0x%08lX (mapped %lu KB)\n\n",
           DMA_BASE, MAP_SIZE / 1024);

    printf("--- 复位后的寄存器状态 ---\n");
    printf("MM2S_DMACR (0x00) = 0x%08X\n", rd(MM2S_DMACR));
    printf("MM2S_DMASR (0x04) = 0x%08X   Halted=%u Idle=%u\n",
           rd(MM2S_DMASR), rd(MM2S_DMASR) & 1u, (rd(MM2S_DMASR) >> 1) & 1u);
    printf("S2MM_DMACR (0x30) = 0x%08X\n", rd(S2MM_DMACR));
    printf("S2MM_DMASR (0x34) = 0x%08X   Halted=%u Idle=%u\n\n",
           rd(S2MM_DMASR), rd(S2MM_DMASR) & 1u, (rd(S2MM_DMASR) >> 1) & 1u);

    /* 写-读回：置 RS=1 后 Halted 应从 1 变 0。
       只写 RS 不写 LENGTH 不会触发传输，安全。 */
    printf("--- 写-读回测试 ---\n");
    wr(MM2S_DMACR, DMACR_RS);
    usleep(2000);
    uint32_t sr = rd(MM2S_DMASR);
    printf("写 MM2S_DMACR.RS=1 后: MM2S_DMASR = 0x%08X   Halted=%u\n\n",
           sr, sr & 1u);

    int ok = !(sr & 1u);

    if (ok) {
        printf(">>> 通过：AXI-Lite 控制通路可用。\n");
        printf("    bitstream 已生效，PL 有时钟，HPM0 已使能。\n");
    } else {
        printf(">>> 失败：寄存器无响应。可能原因——\n");
        printf("    1) bitstream 未真正加载（先查 fpga_manager state）\n");
        printf("    2) BOOT.BIN 未使能 M_AXI_HPM0_FPD（需重新生成 BOOT.BIN）\n");
        printf("    3) PL 时钟未启用\n");
    }

    /* 复位通道，恢复初始状态 */
    wr(MM2S_DMACR, DMACR_RESET);
    usleep(2000);
    wr(MM2S_DMACR, 0);
    usleep(2000);
    printf("\n通道已复位: MM2S_DMASR = 0x%08X\n", rd(MM2S_DMASR));

    munmap(p, MAP_SIZE);
    close(fd);
    return ok ? 0 : 2;
}
