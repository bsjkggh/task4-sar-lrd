# 基于 ZYNQ-7020 的微型 SAR 成像系统

> FPGA 创新设计竞赛 · 任务4 —— 线性 RD 成像处理
> 核心：用 FPGA **实现 16 bit 定点复数乘法**，完成机载斜视条带 SAR 的线性 Range-Doppler（RD）成像。

---

## 项目简介

合成孔径雷达（SAR）能全天时、全天候高分辨率成像，其成像处理本质上是海量复数乘加运算。本作品针对机载斜视条带 SAR，在正点原子 ZYNQ-7020 V2 开发板上实现完整的**线性 RD 成像链路**，并把其中计算量最大、最频繁的「逐点复数乘法」下沉到可编程逻辑（PL）端硬件实现，通过 PS/PL 异构协同完成 2048×2048 规模 SAR 图像的片上处理与 LCD 实时显示。

## 系统架构

| 部件 | 内容 |
|---|---|
| PS（ARM Cortex-A9 @667 MHz） | 浮点 FFT、流程调度、DMA 搬运 |
| PL（FCLK_CLK0 @100 MHz） | 16 bit 定点复数乘法器，Q15 四舍五入 + 饱和截位 |
| 数据通路 | AXI-Stream 32 bit `{im[31:16], re[15:0]}`，AXI DMA simple 模式，DDR3 缓冲 |
| 显示 | VDMA + v_tc + rgb2lcd 并串转换，800×480 LCD 实时显示成像结果 |
| 调试 | UART + JTAG |

## 关键性能指标（实测）

| 指标 | 数值 |
|---|---|
| 数据规模 | 2048 脉冲 × 2048 距离门（419 万复数样点） |
| 整幅处理时间 | 21.49 s（瓶颈为 PS 标量浮点 FFT） |
| 单线复数乘（PL） | 25 μs，较 PS 软件 640 μs 提速 **25 倍** |
| 吞吐 | 82 M 复数点/s（100 MHz 单路理论峰值 82%） |
| 资源占用 | LUT 9817(18.45%)、FF 10065(9.46%)、BRAM 8、DSP48 4 |
| 时序 | WNS +0.322 ns @100 MHz |
| 成像一致性 | 与 MATLAB 相关系数 0.999997，dB 差 RMS 0.005 dB、最大 0.012 dB |

## 目录结构

```
task4_lrd_v2
├── rtl/            # RTL 源码（cplx_mul.v、rgb2lcd3.v）
├── constrs/        # 引脚约束（LCD.xdc）
├── ip_repo/        # 自定义 IP（rgb2lcd3）
├── vitis_src/      # PS 软件源码（main_4.c 等）
├── data/           # 回波 / 系数数据（RDRAW.BIN、COEF16.BIN）
├── matlab/         # MATLAB 定点模型、数据生成与对比分析脚本
├── sim/            # 复数乘法 IP 仿真（tb_cplx_mul.v + run_sim.do）
├── build/          # 一键构建脚本（Vivado + Vitis + bootgen）
├── docs/           # 设计说明与使用说明
├── sd_card/         # SD 卡部署文件（BOOT.BIN 等，构建后生成）
└── task4_system.xsa # 硬件平台导出文件
```

## 环境依赖

- **Vivado / Vitis 2020.2**
- **MATLAB**（推荐 R2022a，用于数据生成与对比验证）
- Windows 10/11

## 快速开始

### 1. 一键构建

```bat
:: 换电脑时设置同名环境变量指向你的安装路径，否则使用默认 D:\VIVADO2020.2
set VIVADO_BIN=D:\VIVADO2020.2\Vivado\2020.2\bin
set XSCT_BIN=D:\VIVADO2020.2\Vitis\2020.2\bin

build\build_all.bat
```

脚本依次完成：Vivado 工程建立 + Block Design + 综合 + 实现 + 导出 XSA → Vitis 平台 + FSBL + 应用 → bootgen 生成 `BOOT.BIN`。

### 2. 上板部署

将以下文件拷贝到 SD 卡根目录，插入开发板并上电：

- `sd_card/BOOT.BIN`
- `sd_card/RDRAW.BIN`（原始回波，int16 I/Q 交替）
- `sd_card/COEF16.BIN`（匹配滤波 + 运动补偿系数，Q15）

## 数据与复现

`matlab/raw_data_dsx.mat` 是唯一的源头回波数据（2048×2048 复数）。运行：

```matlab
matlab/gen_task4_data.m   % 由 raw_data_dsx 生成 data/*.BIN、仿真 hex 与参考图像
```

构建 FPGA 工程所需的其他产物均可由脚本重新生成，无需手工维护。

## 参考文档

- [docs/设计说明.md](docs/设计说明.md) —— RD 原理映射、定点方案、验证结果
- [docs/使用说明.md](docs/使用说明.md) —— 上板步骤与操作说明