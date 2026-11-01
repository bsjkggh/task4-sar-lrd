`timescale 1ns / 1ps
//=====================================================================
// cplx_mul.v  --  Task4 线性RD成像 : PL 复数乘法器 (匹配滤波 + 运动补偿)
//
// 功能:
//   AXIS 输入  : 32bit {im[31:16], re[15:0]}   (距离 FFT 结果, int16 IQ)
//   AXIS 输出  : 32bit {im[31:16], re[15:0]}   (乘以 H 之后, int16 IQ)
//   系数       : 2048 x 32bit 内部 BRAM, 由 PS 通过 AXI4-Lite 写入
//                (地址 0x0000~0x1FFF, 每 4 字节一个复数, Q15)
//
// 运算 (每点):
//   pr = (re_in * coef_re - im_in * coef_im + 2^14) >> 15   saturate int16
//   pi = (re_in * coef_im + im_in * coef_re + 2^14) >> 15   saturate int16
//   系数为 Q15 且 |H| = 1, 因此输出幅度与输入相同, 不会溢出。
//
// 时序: 系数地址 = 包内已接收 beat 数; BRAM 同步读 1 拍, 数据同拍对齐。
//       每 2048 个 beat 自动产生一次 TLAST 并把地址计数器清零, 因此 PS
//       每次 DMA 传 2048 点(8192 字节)即可, 无需额外控制寄存器。
//       输出经 16 深度 FWFT FIFO, 支持下游反压。
//=====================================================================
module cplx_mul #(
    parameter integer N  = 2048,      // 每包点数
    parameter integer AW = 11         // 系数地址位宽
)(
    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF S_AXIS:M_AXIS:s_axi, ASSOCIATED_RESET aresetn, FREQ_HZ 100000000" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 aclk CLK" *)
    input  wire        aclk,
    (* X_INTERFACE_PARAMETER = "POLARITY ACTIVE_LOW" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:reset:1.0 aresetn RST" *)
    input  wire        aresetn,

    // ---------------- AXI4-Stream slave (data in) ----------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TDATA" *)
    input  wire [31:0] s_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TVALID" *)
    input  wire        s_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TREADY" *)
    output wire        s_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TLAST" *)
    input  wire        s_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 S_AXIS TKEEP" *)
    input  wire [3:0]  s_axis_tkeep,

    // ---------------- AXI4-Stream master (data out) ------------
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TDATA" *)
    output wire [31:0] m_axis_tdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TVALID" *)
    output wire        m_axis_tvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TREADY" *)
    input  wire        m_axis_tready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TLAST" *)
    output wire        m_axis_tlast,
    (* X_INTERFACE_INFO = "xilinx.com:interface:axis:1.0 M_AXIS TKEEP" *)
    output wire [3:0]  m_axis_tkeep,

    // ---------------- AXI4-Lite slave (coefficient) ------------
    (* X_INTERFACE_PARAMETER = "XIL_INTERFACENAME s_axi, PROTOCOL AXI4LITE, ADDR_WIDTH 14, DATA_WIDTH 32, READ_WRITE_MODE READ_WRITE, FREQ_HZ 100000000, HAS_BURST 0, HAS_LOCK 0, HAS_PROT 0, HAS_CACHE 0, HAS_QOS 0, HAS_REGION 0, SUPPORTS_NARROW_BURST 0, NUM_READ_OUTSTANDING 2, NUM_WRITE_OUTSTANDING 2" *)
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWADDR" *)
    input  wire [13:0] s_axi_awaddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWVALID" *)
    input  wire        s_axi_awvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi AWREADY" *)
    output wire        s_axi_awready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WDATA" *)
    input  wire [31:0] s_axi_wdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WSTRB" *)
    input  wire [3:0]  s_axi_wstrb,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WVALID" *)
    input  wire        s_axi_wvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi WREADY" *)
    output wire        s_axi_wready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BRESP" *)
    output wire [1:0]  s_axi_bresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BVALID" *)
    output wire        s_axi_bvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi BREADY" *)
    input  wire        s_axi_bready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARADDR" *)
    input  wire [13:0] s_axi_araddr,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARVALID" *)
    input  wire        s_axi_arvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi ARREADY" *)
    output wire        s_axi_arready,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RDATA" *)
    output wire [31:0] s_axi_rdata,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RRESP" *)
    output wire [1:0]  s_axi_rresp,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RVALID" *)
    output wire        s_axi_rvalid,
    (* X_INTERFACE_INFO = "xilinx.com:interface:aximm:1.0 s_axi RREADY" *)
    input  wire        s_axi_rready
);

    localparam integer DEPTH = 2048;

    //=================================================================
    // 系数 RAM : 写口 (AXI-Lite), 读口 (数据通路)
    //=================================================================
    reg [31:0] coef_mem [0:DEPTH-1];
    reg [31:0] coef_q;

    //=================================================================
    // AXI4-Lite 从机
    //=================================================================
    reg        awready_r, wready_r, bvalid_r;
    reg        arready_r, rvalid_r, rvalid_d;
    reg [31:0] rdata_r;
    reg [13:0] araddr_r;

    wire wr_en = s_axi_awvalid & s_axi_wvalid & awready_r & wready_r;

    assign s_axi_awready = awready_r;
    assign s_axi_wready  = wready_r;
    assign s_axi_bvalid  = bvalid_r;
    assign s_axi_bresp   = 2'b00;
    assign s_axi_arready = arready_r;
    assign s_axi_rvalid  = rvalid_r;
    assign s_axi_rdata   = rdata_r;
    assign s_axi_rresp   = 2'b00;

    always @(posedge aclk) begin
        if (!aresetn) begin
            awready_r <= 1'b1; wready_r <= 1'b1; bvalid_r <= 1'b0;
            arready_r <= 1'b1; rvalid_r <= 1'b0; rvalid_d <= 1'b0;
            rdata_r   <= 32'd0; araddr_r <= 14'd0;
        end else begin
            // ---------- 写 : 系数区 ----------
            if (wr_en) begin
                coef_mem[s_axi_awaddr[12:2]] <= s_axi_wdata;
                awready_r <= 1'b0;
                wready_r  <= 1'b0;
                bvalid_r  <= 1'b1;
            end
            if (bvalid_r && s_axi_bready) begin
                bvalid_r  <= 1'b0;
                awready_r <= 1'b1;
                wready_r  <= 1'b1;
            end
            // ---------- 读 ----------
            if (arready_r && s_axi_arvalid) begin
                araddr_r  <= s_axi_araddr;
                arready_r <= 1'b0;
                rvalid_d  <= 1'b1;
            end else if (rvalid_d) begin
                rvalid_d <= 1'b0;
            end
            if (rvalid_d && !rvalid_r) begin
                rdata_r  <= coef_mem[araddr_r[12:2]];
                rvalid_r <= 1'b1;
            end
            if (rvalid_r && s_axi_rready) begin
                rvalid_r  <= 1'b0;
                arready_r <= 1'b1;
            end
        end
    end

    //=================================================================
    // 包内计数器 + 系数地址
    //=================================================================
    reg  [AW-1:0] cnt;
    wire          in_fire = s_axis_tvalid & s_axis_tready;
    wire          last_in = (cnt == (N-1));

    always @(posedge aclk) begin
        if (!aresetn)
            cnt <= {AW{1'b0}};
        else if (in_fire)
            cnt <= last_in ? {AW{1'b0}} : (cnt + 1'b1);
    end

    //=================================================================
    // 系数 BRAM 读 (同步读, 1 拍延迟)
    //=================================================================
    always @(posedge aclk) begin
        if (!aresetn)
            coef_q <= 32'd0;
        else
            coef_q <= coef_mem[cnt];
    end

    //=================================================================
    // 数据流水 : 与系数同拍对齐, FIFO 满时整条流水冻结
    //=================================================================
    reg [31:0] d1_data;
    reg        d1_valid, d1_last;
    reg [31:0] md_r;
    reg        mv_r, ml_r;

    //=================================================================
    // 复数乘法 (4 个 DSP48, Q15, 舍入 + 饱和)
    //=================================================================
    wire signed [15:0] ar = d1_data[15:0];
    wire signed [15:0] ai = d1_data[31:16];
    wire signed [15:0] br = coef_q[15:0];
    wire signed [15:0] bi = coef_q[31:16];

    wire signed [31:0] p_rr = ar * br;
    wire signed [31:0] p_ii = ai * bi;
    wire signed [31:0] p_ri = ar * bi;
    wire signed [31:0] p_ir = ai * br;

    wire signed [32:0] pr  = p_rr - p_ii;
    wire signed [32:0] piw = p_ri + p_ir;

    function signed [15:0] sat16;
        input signed [32:0] v;
        reg   signed [19:0] r;
        begin
            r = (v + 33'sd16384) >>> 15;
            if (r > 20'sd32767)       sat16 = 16'sd32767;
            else if (r < -20'sd32768) sat16 = -16'sd32768;
            else                      sat16 = r[15:0];
        end
    endfunction

    wire [31:0] mul_data = {sat16(piw), sat16(pr)};

    //=================================================================
    // 输出 FIFO (FWFT, 深度 16)
    //=================================================================
    localparam integer FD = 16;
    reg [32:0] fifo [0:FD-1];       // {last, data}
    reg [4:0]  wr_ptr, rd_ptr, fifo_cnt;

    wire fifo_full  = (fifo_cnt == FD);
    wire fifo_empty = (fifo_cnt == 0);
    wire fifo_rd    = m_axis_tready & ~fifo_empty;

    // FIFO 满 -> 冻结整条流水 (含 cnt / d1 / mul 级), 保证系数与数据对齐
    wire pipe_stall = fifo_full;

    assign s_axis_tready = ~pipe_stall;

    always @(posedge aclk) begin
        if (!aresetn) begin
            d1_data <= 32'd0; d1_valid <= 1'b0; d1_last <= 1'b0;
            md_r    <= 32'd0; mv_r     <= 1'b0; ml_r    <= 1'b0;
        end else if (!pipe_stall) begin
            d1_data  <= s_axis_tdata;
            d1_valid <= s_axis_tvalid;
            d1_last  <= s_axis_tvalid & last_in;
            md_r     <= mul_data;
            mv_r     <= d1_valid;
            ml_r     <= d1_last;
        end
    end

    wire fifo_wr = mv_r & ~fifo_full;

    always @(posedge aclk) begin
        if (!aresetn) begin
            wr_ptr   <= 5'd0;
            rd_ptr   <= 5'd0;
            fifo_cnt <= 5'd0;
        end else begin
            if (fifo_wr) begin
                fifo[wr_ptr[3:0]] <= {ml_r, md_r};
                wr_ptr <= wr_ptr + 1'b1;
            end
            if (fifo_rd)
                rd_ptr <= rd_ptr + 1'b1;
            case ({fifo_wr, fifo_rd})
                2'b10: fifo_cnt <= fifo_cnt + 1'b1;
                2'b01: fifo_cnt <= fifo_cnt - 1'b1;
                default: ;
            endcase
        end
    end

    assign m_axis_tdata  = fifo[rd_ptr[3:0]][31:0];
    assign m_axis_tvalid = ~fifo_empty;
    assign m_axis_tlast  = fifo[rd_ptr[3:0]][32];
    assign m_axis_tkeep  = 4'hF;

    // 输入 tlast / tkeep 不使用: 本 IP 按 2048 点自动产生输出 tlast
    wire unused_in = s_axis_tlast | (|s_axis_tkeep);

endmodule
