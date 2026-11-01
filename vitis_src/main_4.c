/******************************************************************************/
/* task4: 线性RD成像 (LRD)                                                     */
/*                                                                            */
/*   数据读取 (SD) -> PS 距离向 FFT -> PL 复数乘法(匹配滤波 + 运动补偿)         */
/*   -> PS 方位向 FFT (hamming) -> PS 距离向 IFFT (hamming) -> 幅度 -> LCD     */
/*                                                                            */
/*   与任务三工程 (task3_fft_lcd) 相同的硬件框架: PS + AXI VDMA 显示,           */
/*   新增 AXI DMA + PL 复数乘法 IP (rtl/cplx_mul.v):                           */
/*     * DMA 每次搬运一条距离线 (2048 点, 8192 字节)                           */
/*     * PS 先通过 AXI-Lite 把该脉冲的 2048 个 Q15 系数写入 IP 内部 BRAM        */
/*     * IP 用 4 个 DSP48 完成复数乘 (含舍入/饱和), 经 S2MM 写回 DDR            */
/*                                                                            */
/*   定点格式: 距离 FFT 结果按列缩放到 int16, 系数 Q15 (|H| = 1),               */
/*             输出 int16, PS 用 mx/32767 还原为浮点, 与 MATLAB 逐位一致        */
/*             (sim 已用 data/sim_*.hex 验证 IP 输出与 MATLAB 模型完全相同)    */
/*                                                                            */
/*   SD 卡文件 (8.3 文件名, 小端):                                             */
/*     RDRAW.BIN  16MB  原始回波, int16 re/im, 按"列优先"(每条距离线连续)       */
/*     COEF16.BIN 16MB  系数 H 的 Q15 int16, 同一顺序                          */
/*                                                                            */
/*   内存布局 (DDR 内绝对地址):                                                */
/*     frame   +0x1000000  800*480*3 = 1.15MB                                 */
/*     RAW     +0x1400000  16MB  原始回波 int16                                */
/*     COEF    +0x2400000  16MB  系数 Q15 int16                                */
/*     WORKA   +0x3400000  32MB  float complex [azimuth][range-freq]           */
/*     WORKB   +0x5400000  32MB  float complex [range-freq][azimuth]           */
/*     MAG     +0x7400000  16MB  u32 幅度 [azimuth][range]                     */
/*     STG     +0x8400000  8KB   DMA 源 (int16 IQ)                             */
/*     RES     +0x8402000  8KB   DMA 目的                                       */
/******************************************************************************/
#include <stdio.h>
#include <string.h>
#include <stdint.h>
#include "xil_types.h"
#include "xil_cache.h"
#include "xparameters.h"
#include "xgpio.h"
#include "xaxivdma.h"
#include "xaxivdma_i.h"
#include "xaxidma.h"
#include "display_ctrl/display_ctrl.h"
#include "vdma_api/vdma_api.h"
#include "clk_wiz/clk_wiz.h"
#include "ff.h"
#include "sleep.h"
#include "xtime_l.h"

#define BYTES_PIXEL        3
#define CLK_WIZ_ID         XPAR_CLK_WIZ_0_DEVICE_ID
#define VDMA_ID            XPAR_AXIVDMA_0_DEVICE_ID
#define DISP_VTC_ID        XPAR_VTC_0_DEVICE_ID
#define AXI_GPIO_0_ID      XPAR_AXI_GPIO_0_DEVICE_ID
#define AXI_GPIO_0_CHANEL  1

#define N                  2048
#define LOGN               11
#define LINE_BYTES         (N * 4)          /* 2048 点 x 4 字节 */
#define CLIP               1000.0f          /* 与 LRD_SAR.m 的 caxis([0 1e3]) 一致 */

/* 原始回波 int16 缩放系数 (MATLAB: 32767 / max|raw|) */
#define SRAW               985.5408577708f

#define MUL_BASE           0x40000000       /* cplx_mul AXI-Lite (系数区 8KB) */

#define DDR_BASE           XPAR_PS7_DDR_0_S_AXI_BASEADDR
#define FRAME_ADDR         (DDR_BASE + 0x1000000)
#define RAW_ADDR           (DDR_BASE + 0x1400000)
#define COEF_ADDR          (DDR_BASE + 0x2400000)
#define WORKA_ADDR         (DDR_BASE + 0x3400000)
#define WORKB_ADDR         (DDR_BASE + 0x5400000)
#define MAG_ADDR           (DDR_BASE + 0x7400000)
#define STG_ADDR           (DDR_BASE + 0x8400000)
#define RES_ADDR           (DDR_BASE + 0x8402000)

XAxiVdma     vdma;
DisplayCtrl  dispCtrl;
XGpio        axi_gpio_inst;
XAxiDma      axi_dma;
VideoMode    vd_mode;
unsigned int const frame_buffer_addr = FRAME_ADDR;
unsigned int lcd_id = 0;

/* ---------------- 软件 FFT (float, radix-2 DIT) ---------------- */
static float    g_tw_re[N/2], g_tw_im[N/2];
static uint16_t g_bitrev[N];
static float    g_win[N];               /* hamming(2048) */
static int      g_init_done = 0;

static void fft_init(void)
{
    const float w1_re =  0.999995293809576f;  /* cos(2*pi/2048)  (exp(-j*2*pi/2048)) */
    const float w1_im = -0.003067956762966f;  /* -sin(2*pi/2048) */
    float re = 1.0f, im = 0.0f;
    int k;

    for (k = 0; k < N/2; k++) {
        g_tw_re[k] = re;
        g_tw_im[k] = im;
        {
            float nr = re * w1_re - im * w1_im;
            float ni = re * w1_im + im * w1_re;
            re = nr; im = ni;
        }
    }
    for (k = 0; k < N; k++) {
        int j = 0, b;
        for (b = 0; b < LOGN; b++)
            if (k & (1 << b)) j |= (1 << (LOGN - 1 - b));
        g_bitrev[k] = (uint16_t)j;
    }

    /* hamming(2048) = 0.54 - 0.46*cos(2*pi*k/2047), 用旋转递推 (double) */
    {
        const double ct = 0.99999528921032232;
        const double st = 0.0030694555158386218;
        double cr = 1.0, ci = 0.0;
        for (k = 0; k < N; k++) {
            g_win[k] = (float)(0.54 - 0.46 * cr);
            {
                double nr = cr * ct - ci * st;
                double ni = cr * st + ci * ct;
                cr = nr; ci = ni;
            }
        }
    }
    g_init_done = 1;
}

static void fft_2048(float *re, float *im, int inv)
{
    int i, len, start, k;

    if (!g_init_done) fft_init();

    for (i = 1; i < N; i++) {
        int j = g_bitrev[i];
        if (i < j) {
            float t = re[i]; re[i] = re[j]; re[j] = t;
            t = im[i]; im[i] = im[j]; im[j] = t;
        }
    }
    for (len = 2; len <= N; len <<= 1) {
        int half = len >> 1;
        int step = N / len;
        for (start = 0; start < N; start += len) {
            float *pr = re + start;
            float *pi = im + start;
            for (k = 0; k < half; k++) {
                float cosv = g_tw_re[k * step];
                float sinv = inv ? -g_tw_im[k * step] : g_tw_im[k * step];
                float vr = pr[k + half], vi = pi[k + half];
                float tr = vr * cosv - vi * sinv;
                float ti = vr * sinv + vi * cosv;
                float ur = pr[k], ui = pi[k];
                pr[k]        = ur + tr;
                pi[k]        = ui + ti;
                pr[k + half] = ur - tr;
                pi[k + half] = ui - ti;
            }
        }
    }
}

static float sqrtf_sw(float v)
{
    union { float f; u32 i; } u;
    float x;
    int n;
    if (v <= 0.0f) return 0.0f;
    /* IEEE754 位操作取初值 (指数折半), 对任意 v 误差约几 %, */
    /* 再做 4 次牛顿迭代即收敛到 float 全精度 (原 x=v 对大值不收敛)。 */
    u.f = v;
    u.i = (u.i >> 1) + 0x1FC00000u;
    x = u.f;
    for (n = 0; n < 4; n++)
        x = 0.5f * (x + v / x);
    return x;
}

/* ---------------- 32x32 分块转置: src[行][列] -> dst[列][行] (float complex) ---------------- */
static float g_tile[32][32][2];

static void transpose_f(float *src, float *dst)
{
    int br, bc, i, j;
    for (br = 0; br < N; br += 32) {
        for (bc = 0; bc < N; bc += 32) {
            for (i = 0; i < 32; i++) {
                float *sp = src + (u32)(br + i) * N * 2 + bc * 2;
                for (j = 0; j < 32; j++) {
                    g_tile[i][j][0] = sp[j * 2];
                    g_tile[i][j][1] = sp[j * 2 + 1];
                }
            }
            for (j = 0; j < 32; j++) {
                float *dp = dst + (u32)(bc + j) * N * 2 + br * 2;
                for (i = 0; i < 32; i++) {
                    dp[i * 2]     = g_tile[i][j][0];
                    dp[i * 2 + 1] = g_tile[i][j][1];
                }
            }
        }
    }
}

/* ---------------- int16 饱和 ---------------- */
static int sat16(int v)
{
    if (v >  32767) return  32767;
    if (v < -32768) return -32768;
    return v;
}

/* ---------------- 计时 ---------------- */
static XTime now_t(void)
{
    XTime t;
    XTime_GetTime(&t);
    return t;
}

static float sec_of(XTime a, XTime b)
{
    return (float)((double)(b - a) / (double)COUNTS_PER_SECOND);
}

static u32 ms_of(XTime a, XTime b)
{
    return (u32)((double)(b - a) * 1000.0 / (double)COUNTS_PER_SECOND);
}

int main(void)
{
    int16_t *raw  = (int16_t *)RAW_ADDR;
    int16_t *coef = (int16_t *)COEF_ADDR;
    float   *wa   = (float   *)WORKA_ADDR;
    float   *wb   = (float   *)WORKB_ADDR;
    u32     *mag  = (u32     *)MAG_ADDR;
    volatile u32 *mul = (volatile u32 *)MUL_BASE;
    u32     *stg  = (u32 *)STG_ADDR;
    u32     *res  = (u32 *)RES_ADDR;

    static float t_re[N], t_im[N];

    XGpio_Initialize(&axi_gpio_inst, AXI_GPIO_0_ID);
    XGpio_SetDataDirection(&axi_gpio_inst, AXI_GPIO_0_CHANEL, 0x07);
    lcd_id = lcd_id_read(&axi_gpio_inst, AXI_GPIO_0_CHANEL);
    XGpio_SetDataDirection(&axi_gpio_inst, AXI_GPIO_0_CHANEL, 0x00);

    switch (lcd_id) {
        case 0x4342 : vd_mode = VMODE_480x272; break;
        case 0x4384 : vd_mode = VMODE_800x480; break;
        case 0x7084 : vd_mode = VMODE_800x480; break;
        case 0x7016 : vd_mode = VMODE_1024x600; break;
        case 0x1018 : vd_mode = VMODE_1280x800; break;
        default     : vd_mode = VMODE_800x480; break;
    }

    memset((void *)frame_buffer_addr, 0,
           (u32)vd_mode.width * vd_mode.height * BYTES_PIXEL);
    Xil_DCacheFlushRange(frame_buffer_addr,
                         (u32)vd_mode.width * vd_mode.height * BYTES_PIXEL);
    run_vdma_frame_buffer(&vdma, VDMA_ID, vd_mode.width, vd_mode.height,
                          frame_buffer_addr, 0, 0, ONLY_READ);
    clk_wiz_cfg(CLK_WIZ_ID, vd_mode.freq);
    DisplayInitialize(&dispCtrl, DISP_VTC_ID);
    DisplaySetMode(&dispCtrl, &vd_mode);
    DisplayStart(&dispCtrl);

    xil_printf("\r\ntask4 LRD: SD -> PS range FFT -> PL complex mul -> "
               "PS azimuth FFT / range IFFT -> LCD (ID %x, %dx%d)\r\n",
               lcd_id, vd_mode.width, vd_mode.height);

    /* ---------------- AXI DMA 初始化 ---------------- */
    {
        XAxiDma_Config *cfg = XAxiDma_LookupConfig(XPAR_AXI_DMA_0_DEVICE_ID);
        if (!cfg) { xil_printf("ERROR: no DMA config\r\n"); return -1; }
        if (XAxiDma_CfgInitialize(&axi_dma, cfg) != XST_SUCCESS) {
            xil_printf("ERROR: DMA init failed\r\n"); return -1;
        }
        if (!XAxiDma_HasSg(&axi_dma) &&
            XAxiDma_Busy(&axi_dma, XAXIDMA_DMA_TO_DEVICE)) {
            xil_printf("ERROR: DMA busy\r\n");
        }
        XAxiDma_IntrDisable(&axi_dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DMA_TO_DEVICE);
        XAxiDma_IntrDisable(&axi_dma, XAXIDMA_IRQ_ALL_MASK, XAXIDMA_DEVICE_TO_DMA);
        XAxiDma_Reset(&axi_dma);
        while (XAxiDma_ResetIsDone(&axi_dma) != 1) { }
        xil_printf("DMA ready (mm2s=%d, s2mm=%d)\r\n",
                   axi_dma.HasMm2S, axi_dma.HasS2Mm);
    }

    /* ---------------- 从 SD 读取回波和系数 ---------------- */
    {
        static FATFS fatfs;
        FIL fil; UINT br;
        const u32 bytes = (u32)N * N * 4;

        f_mount(&fatfs, "", 1);

        if (f_open(&fil, "RDRAW.BIN", FA_READ) != FR_OK) {
            xil_printf("ERROR: open RDRAW.BIN failed\r\n");
            return -1;
        }
        {
            u32 left = bytes, off = 0;
            while (left) {
                UINT rd = left > 0x10000 ? 0x10000 : (UINT)left;
                if (f_read(&fil, (void *)(RAW_ADDR + off), rd, &br) != FR_OK || br != rd) {
                    xil_printf("ERROR: RDRAW read\r\n"); break;
                }
                left -= rd; off += rd;
            }
        }
        f_close(&fil);
        Xil_DCacheFlushRange(RAW_ADDR, bytes);

        if (f_open(&fil, "COEF16.BIN", FA_READ) != FR_OK) {
            xil_printf("ERROR: open COEF16.BIN failed\r\n");
            return -1;
        }
        {
            u32 left = bytes, off = 0;
            while (left) {
                UINT rd = left > 0x10000 ? 0x10000 : (UINT)left;
                if (f_read(&fil, (void *)(COEF_ADDR + off), rd, &br) != FR_OK || br != rd) {
                    xil_printf("ERROR: COEF read\r\n"); break;
                }
                left -= rd; off += rd;
            }
        }
        f_close(&fil);
        Xil_DCacheFlushRange(COEF_ADDR, bytes);
        xil_printf("SD load done (2 x %u bytes)\r\n", bytes);
    }

    fft_init();

    XTime t_all = now_t();   /* 成像总计时起点 */

    /* =================================================================
     * 阶段 1: 逐条距离线  FFT -> 量化 -> PL 复数乘 -> 还原浮点
     * ================================================================= */
    {
        int ii, k, c;
        int sw_errors = 0;
        XTime t_s1 = now_t();
        XTime t_dma_sum = 0;

        for (ii = 0; ii < N; ii++) {
            int16_t *rp = raw + (u32)ii * N * 2;
            int16_t *cp = coef + (u32)ii * N * 2;
            float    s, inv, mx = 0.0f;

            /* ---- fftshift(fft(fftshift(x))) : 先搬移再变换 ---- */
            for (c = 0; c < N; c++) {
                int sc = (c + N/2) & (N - 1);
                t_re[sc] = (float)rp[c * 2]     / SRAW;
                t_im[sc] = (float)rp[c * 2 + 1] / SRAW;
            }
            fft_2048(t_re, t_im, 0);

            /* ---- 该列最大值 -> 每列缩放 ---- */
            for (k = 0; k < N; k++) {
                float m2 = t_re[k] * t_re[k] + t_im[k] * t_im[k];
                if (m2 > mx) mx = m2;
            }
            mx = sqrtf_sw(mx);
            s   = (mx > 0.0f) ? (32767.0f / mx) : 1.0f;
            inv = (mx > 0.0f) ? (mx / 32767.0f) : 1.0f;

            /* ---- 量化到 int16, 输出顺序为 fftshift 之后 (与 COEF16 对齐) ---- */
            for (k = 0; k < N; k++) {
                int sc = (k + N/2) & (N - 1);
                float re = t_re[sc] * s;
                float im = t_im[sc] * s;
                int   ir = sat16((int)(re + (re >= 0.0f ? 0.5f : -0.5f)));
                int   ii_ = sat16((int)(im + (im >= 0.0f ? 0.5f : -0.5f)));
                stg[k] = ((u32)(uint16_t)(int16_t)ii_ << 16) | (u32)(uint16_t)(int16_t)ir;
            }
            Xil_DCacheFlushRange(STG_ADDR, LINE_BYTES);

            /* ---- 该脉冲的 2048 个 Q15 系数写入 PL BRAM ---- */
            {
                for (k = 0; k < N; k++)
                    mul[k] = ((u32)(uint16_t)cp[k * 2 + 1] << 16) |
                             (u32)(uint16_t)cp[k * 2];
            }

            /* ---- DMA: S2MM 接收 + MM2S 发送 ---- */
            {
                XTime td0 = now_t();
                if (XAxiDma_SimpleTransfer(&axi_dma, (UINTPTR)RES_ADDR, LINE_BYTES,
                                           XAXIDMA_DEVICE_TO_DMA) != XST_SUCCESS ||
                    XAxiDma_SimpleTransfer(&axi_dma, (UINTPTR)STG_ADDR, LINE_BYTES,
                                           XAXIDMA_DMA_TO_DEVICE) != XST_SUCCESS) {
                    xil_printf("ERROR: DMA transfer submit failed at %d\r\n", ii);
                    return -1;
                }
                while (XAxiDma_Busy(&axi_dma, XAXIDMA_DMA_TO_DEVICE)) { }
                while (XAxiDma_Busy(&axi_dma, XAXIDMA_DEVICE_TO_DMA)) { }
                t_dma_sum += now_t() - td0;
            }
            Xil_DCacheInvalidateRange(RES_ADDR, LINE_BYTES);

            /* ---- 第 0 列做一次逐位自检 (硬件结果 vs 软件整数模型) ---- */
            if (ii == 0) {
                XTime t_sc0 = now_t();
                for (k = 0; k < N; k++) {
                    int ar = (int16_t)(stg[k] & 0xFFFF);
                    int ai = (int16_t)(stg[k] >> 16);
                    int br = (int16_t)cp[k * 2];
                    int bi = (int16_t)cp[k * 2 + 1];
                    s64 pr = (s64)ar * br - (s64)ai * bi;
                    s64 pi = (s64)ar * bi + (s64)ai * br;
                    int er = sat16((int)((pr + 16384) >> 15));
                    int ei = sat16((int)((pi + 16384) >> 15));
                    int hr = (int16_t)(res[k] & 0xFFFF);
                    int hi = (int16_t)(res[k] >> 16);
                    if (er != hr || ei != hi) {
                        if (sw_errors < 4)
                            xil_printf("  mul mismatch k=%d: hw(%d,%d) sw(%d,%d)\r\n",
                                       k, hr, hi, er, ei);
                        sw_errors++;
                    }
                }
                xil_printf("PL complex-mul self-check col0: %s (%d/2048 mismatch)\r\n",
                           sw_errors == 0 ? "PASS" : "FAIL", sw_errors);
                {
                    /* 同一份复数乘改用 PS 软件的耗时 (单条距离线) */
                    u32 us = (u32)((double)(now_t() - t_sc0) * 1000000.0
                                   / (double)COUNTS_PER_SECOND);
                    u32 all_ms = (u32)((double)us * (double)N / 1000.0);
                    xil_printf("PS soft model 1 line = %u us -> full 2048 lines ~ %u.%03u s\r\n",
                               us, all_ms/1000u, all_ms%1000u);
                }
            }

            /* ---- 还原为浮点, 存 [azimuth][range-freq] ---- */
            {
                float *ap = wa + (u32)ii * N * 2;
                for (k = 0; k < N; k++) {
                    ap[k * 2]     = (float)(int16_t)(res[k] & 0xFFFF) * inv;
                    ap[k * 2 + 1] = (float)(int16_t)(res[k] >> 16)    * inv;
                }
            }

            if ((ii & 0xFF) == 0)
                xil_printf("  range line %d / %d\r\n", ii, N);
        }
        Xil_DCacheFlushRange(WORKA_ADDR, (u32)N * N * 8);
        {
            u32 m1 = ms_of(t_s1, now_t());
            u32 md = ms_of(0, t_dma_sum);
            xil_printf("stage1 done in %u.%03u s (PL complex-mul DMA wait %u.%03u s). "
                       "transpose + azimuth FFT ...\r\n",
                       m1/1000u, m1%1000u, md/1000u, md%1000u);
        }
    }

    /* =================================================================
     * 阶段 2: 转置 -> 方位向 hamming + FFT
     * ================================================================= */
    XTime t_s2 = now_t();
    transpose_f(wa, wb);

    {
        int p, k;
        for (p = 0; p < N; p++) {
            float *rp = wb + (u32)p * N * 2;
            for (k = 0; k < N; k++) {
                t_re[k] = rp[k * 2]     * g_win[k];
                t_im[k] = rp[k * 2 + 1] * g_win[k];
            }
            /* fftshift(fft(fftshift(x))) */
            for (k = 0; k < N/2; k++) {
                float tr = t_re[k], ti = t_im[k];
                t_re[k] = t_re[k + N/2]; t_im[k] = t_im[k + N/2];
                t_re[k + N/2] = tr;      t_im[k + N/2] = ti;
            }
            fft_2048(t_re, t_im, 0);
            for (k = 0; k < N/2; k++) {
                float tr = t_re[k], ti = t_im[k];
                t_re[k] = t_re[k + N/2]; t_im[k] = t_im[k + N/2];
                t_re[k + N/2] = tr;      t_im[k + N/2] = ti;
            }
            for (k = 0; k < N; k++) {
                rp[k * 2]     = t_re[k];
                rp[k * 2 + 1] = t_im[k];
            }
        }
        Xil_DCacheFlushRange(WORKB_ADDR, (u32)N * N * 8);
    }
    {
        u32 m2 = ms_of(t_s2, now_t());
        xil_printf("azimuth FFT done in %u.%03u s. transpose back + range IFFT ...\r\n",
                   m2/1000u, m2%1000u);
    }

    /* =================================================================
     * 阶段 3: 转置回 [azimuth][range-freq] -> 距离向 hamming + IFFT -> 幅度
     * ================================================================= */
    XTime t_s3 = now_t();
    transpose_f(wb, wa);

    {
        int a, k;
        const float inv_n = 1.0f / (float)N;
        for (a = 0; a < N; a++) {
            float *rp = wa + (u32)a * N * 2;
            u32   *mp = mag + (u32)a * N;
            for (k = 0; k < N; k++) {
                t_re[k] = rp[k * 2]     * g_win[k];
                t_im[k] = rp[k * 2 + 1] * g_win[k];
            }
            for (k = 0; k < N/2; k++) {
                float tr = t_re[k], ti = t_im[k];
                t_re[k] = t_re[k + N/2]; t_im[k] = t_im[k + N/2];
                t_re[k + N/2] = tr;      t_im[k + N/2] = ti;
            }
            fft_2048(t_re, t_im, 1);
            for (k = 0; k < N/2; k++) {
                float tr = t_re[k], ti = t_im[k];
                t_re[k] = t_re[k + N/2]; t_im[k] = t_im[k + N/2];
                t_re[k + N/2] = tr;      t_im[k + N/2] = ti;
            }
            for (k = 0; k < N; k++) {
                float re = t_re[k] * inv_n, im = t_im[k] * inv_n;
                mp[k] = (u32)(sqrtf_sw(re * re + im * im) + 0.5f);
            }
        }
        Xil_DCacheFlushRange(MAG_ADDR, (u32)N * N * 4);
    }
    {
        u32 m3 = ms_of(t_s3, now_t());
        u32 mt = ms_of(t_all, now_t());
        xil_printf("range IFFT + magnitude done in %u.%03u s\r\n", m3/1000u, m3%1000u);
        xil_printf("TOTAL imaging time = %u.%03u s\r\n", mt/1000u, mt%1000u);
    }
    xil_printf("RD image ready. render ...\r\n");

    /* =================================================================
     * 阶段 4: 显示 (x = 方位, y = 距离, 与 MATLAB YDir normal 一致)
     * ================================================================= */
    {
        u8 *frame = (u8 *)frame_buffer_addr;
        int W = vd_mode.width, H = vd_mode.height;
        int x, y;

        for (y = 0; y < H; y++) {
            u32 r = (u32)((u64)(H - 1 - y) * (N - 1) + (u32)(H - 1) / 2) / (u32)(H - 1);
            u8 *fp = frame + (u32)y * W * BYTES_PIXEL;
            for (x = 0; x < W; x++) {
                u32 a = (u32)((u64)x * (N - 1) + (u32)(W - 1) / 2) / (u32)(W - 1);
                u32 m = mag[a * N + r];
                u32 g = (m >= (u32)CLIP) ? 255u : (u32)((float)m * 255.0f / CLIP);
                fp[x * 3]     = (u8)g;
                fp[x * 3 + 1] = (u8)g;
                fp[x * 3 + 2] = (u8)g;
            }
        }
        Xil_DCacheFlushRange(frame_buffer_addr, (u32)W * H * BYTES_PIXEL);
    }
    xil_printf("=========================================\r\n");
    xil_printf(" task4 LRD imaging done\r\n");
    xil_printf("=========================================\r\n");

    /* 死循环: VDMA MM2S 独立运行, 持续刷新帧缓存以保持画面显示 */
    while (1) {
        Xil_DCacheFlushRange(frame_buffer_addr,
                             (u32)vd_mode.width * vd_mode.height * BYTES_PIXEL);
        usleep(1000000);
    }
    return 0;
}
