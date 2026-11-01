`timescale 1ns / 1ps
//=====================================================================
// tb_cplx_mul.v -- cplx_mul IP self-check testbench
//   * AXI-Lite writes 2048 Q15 coefficients  (data/sim_coef.hex)
//   * AXIS streams 2048 int16 IQ samples     (data/sim_in.hex)
//   * compared with data/sim_out.hex (bit-exact MATLAB model)
//   * downstream random back-pressure, checks tlast and beat count
//=====================================================================
module tb_cplx_mul;

    localparam integer N = 2048;

    reg  clk = 0;
    reg  rstn = 0;
    always #5 clk = ~clk;

    // ---- DUT ports ----
    reg  [31:0] s_tdata = 0;
    reg         s_tvalid = 0;
    wire        s_tready;
    reg         s_tlast = 0;

    wire [31:0] m_tdata;
    wire        m_tvalid;
    reg         m_tready = 0;
    wire        m_tlast;

    reg  [13:0] awaddr = 0;
    reg         awvalid = 0;
    wire        awready;
    reg  [31:0] wdata = 0;
    reg  [3:0]  wstrb = 4'hF;
    reg         wvalid = 0;
    wire        wready;
    wire [1:0]  bresp;
    wire        bvalid;
    reg         bready = 0;
    reg  [13:0] araddr = 0;
    reg         arvalid = 0;
    wire        arready;
    wire [31:0] rdata;
    wire [1:0]  rresp;
    wire        rvalid;
    reg         rready = 0;

    cplx_mul #(.N(N)) dut (
        .aclk(clk), .aresetn(rstn),
        .s_axis_tdata(s_tdata), .s_axis_tvalid(s_tvalid),
        .s_axis_tready(s_tready), .s_axis_tlast(s_tlast),
        .s_axis_tkeep(4'hF),
        .m_axis_tdata(m_tdata), .m_axis_tvalid(m_tvalid),
        .m_axis_tready(m_tready), .m_axis_tlast(m_tlast),
        .m_axis_tkeep(),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(wstrb), .s_axi_wvalid(wvalid),
        .s_axi_wready(wready), .s_axi_bresp(bresp), .s_axi_bvalid(bvalid),
        .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid),
        .s_axi_rready(rready)
    );

    reg [31:0] stim [0:N-1];
    reg [31:0] coef [0:N-1];
    reg [31:0] gold [0:N-1];

    integer i, errors = 0, got = 0, tlast_ok = 0, tlast_bad = 0;
    integer seed = 7;

    // ---------- one AXI-Lite write ----------
    task axi_write(input [13:0] addr, input [31:0] data);
        begin
            @(posedge clk);
            awaddr  <= addr;  awvalid <= 1'b1;
            wdata   <= data;  wvalid  <= 1'b1;
            @(posedge clk);
            while (!(awready && wready)) @(posedge clk);
            awvalid <= 1'b0;  wvalid  <= 1'b0;
            bready  <= 1'b1;
            @(posedge clk);
            while (!bvalid) @(posedge clk);
            bready  <= 1'b0;
            @(posedge clk);
        end
    endtask

    // ---------- one AXIS beat ----------
    task axis_send(input [31:0] data, input last);
        begin
            @(posedge clk);
            s_tdata  <= data;
            s_tlast  <= last;
            s_tvalid <= 1'b1;
            @(posedge clk);
            while (!s_tready) @(posedge clk);
            s_tvalid <= 1'b0;
            s_tlast  <= 1'b0;
        end
    endtask

    // ---------- receiver / checker ----------
    always @(posedge clk) begin
        if (rstn && m_tvalid && m_tready) begin
            if (m_tdata !== gold[got]) begin
                if (errors < 10)
                    $display("MISMATCH @%0d: got %h exp %h", got, m_tdata, gold[got]);
                errors = errors + 1;
            end
            if (m_tlast) begin
                if (got == N-1) tlast_ok  = tlast_ok + 1;
                else            tlast_bad = tlast_bad + 1;
            end
            got = got + 1;
        end
    end

    // ---------- random downstream back-pressure ----------
    always @(posedge clk) begin
        m_tready <= (($random(seed) & 3) != 0);   // ~75% ready
    end

    initial begin
        $readmemh("../data/sim_in.hex",   stim);
        $readmemh("../data/sim_coef.hex", coef);
        $readmemh("../data/sim_out.hex",  gold);

        rstn = 0;
        repeat (5) @(posedge clk);
        rstn = 1;
        repeat (2) @(posedge clk);

        $display("writing %0d coefficients ...", N);
        for (i = 0; i < N; i = i + 1)
            axi_write(i * 4, coef[i]);

        $display("streaming %0d beats ...", N);
        for (i = 0; i < N; i = i + 1)
            axis_send(stim[i], (i == N-1));

        while (got < N) @(posedge clk);
        repeat (10) @(posedge clk);

        $display("---------------------------------------------");
        $display("beats out = %0d / %0d", got, N);
        $display("mismatches= %0d", errors);
        $display("tlast ok  = %0d, tlast bad = %0d", tlast_ok, tlast_bad);
        if (errors == 0 && got == N && tlast_ok == 1 && tlast_bad == 0)
            $display("RESULT: PASS");
        else
            $display("RESULT: FAIL");
        $display("---------------------------------------------");
        $finish;
    end

endmodule
