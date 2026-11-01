//****************************************************************************//
// rgb2lcd3 for task3: RGB passthrough LCD interface
//  Difference vs task2 rgb2lcd: NO complex magnitude logic in PL.
//  In task3 the PS computes magnitude / clipping / grayscale and writes
//  gray (R=G=B) into the frame buffer; VDMA -> v_axi4s_vid_out -> this IP,
//  which registers the stream for one cycle and drives the LCD directly.
//  LCD ID readback logic is identical to task2.
//****************************************************************************//
module rgb2lcd3 #(
    parameter VID_DATA_WIDTH = 24
)(
    //VID_IN (from v_axi4s_vid_out), standard vid_io interface
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_rgb DATA" *)
    input  [VID_DATA_WIDTH-1:0] rgb_data ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_rgb ACTIVE_VIDEO" *)
    input                       rgb_vde  ,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_rgb HSYNC" *)
    input                       rgb_hsync,
    (* X_INTERFACE_INFO = "xilinx.com:interface:vid_io:1.0 vid_rgb VSYNC" *)
    input                       rgb_vsync,

    (* X_INTERFACE_PARAMETER = "ASSOCIATED_BUSIF vid_rgb:lcd_rgb:lcd_id, FREQ_HZ 33333333" *)
    (* X_INTERFACE_INFO = "xilinx.com:signal:clock:1.0 pixel_clk CLK" *)
    input                       pixel_clk,

    //RGB LCD timing (plain external pins)
    output                      lcd_pclk ,
    output                      lcd_rst  ,
    output                      lcd_hs   ,
    output                      lcd_vs   ,
    output                      lcd_de   ,
    output                      lcd_bl   ,

    //AXI GPIO (LCD ID), gpio slave side (mirrored master)
    (* X_INTERFACE_INFO = "xilinx.com:interface:gpio:1.0 lcd_id TRI_O" *)
    input  [2:0]                lcd_id_i,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gpio:1.0 lcd_id TRI_T" *)
    input  [2:0]                lcd_id_t,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gpio:1.0 lcd_id TRI_I" *)
    output [2:0]                lcd_id_o,

    //LCD data bidir, gpio master side
    (* X_INTERFACE_INFO = "xilinx.com:interface:gpio:1.0 lcd_rgb TRI_I" *)
    input  [VID_DATA_WIDTH-1:0] lcd_rgb_i,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gpio:1.0 lcd_rgb TRI_O" *)
    output [VID_DATA_WIDTH-1:0] lcd_rgb_o,
    (* X_INTERFACE_INFO = "xilinx.com:interface:gpio:1.0 lcd_rgb TRI_T" *)
    output [VID_DATA_WIDTH-1:0] lcd_rgb_t
);

reg [VID_DATA_WIDTH-1:0] rgb_data_r;
reg                      rgb_vde_r;
reg                      rgb_hsync_r;
reg                      rgb_vsync_r;
always @(posedge pixel_clk) begin
    rgb_data_r  <= rgb_data;
    rgb_vde_r   <= rgb_vde;
    rgb_hsync_r <= rgb_hsync;
    rgb_vsync_r <= rgb_vsync;
end

assign lcd_pclk = pixel_clk;
assign lcd_de   = rgb_vde_r;
assign lcd_hs   = rgb_hsync_r;
assign lcd_vs   = rgb_vsync_r;
assign lcd_bl   = 1'b1;
assign lcd_rst  = 1'b1;
assign lcd_rgb_o  = ({VID_DATA_WIDTH{lcd_id_t[0]}}) ? {VID_DATA_WIDTH{1'bz}} : rgb_data_r;
assign lcd_rgb_t  = {VID_DATA_WIDTH{lcd_id_t[0]}};

//read LCD ID on R7/G7/B7
assign lcd_id_o[0] = (lcd_id_t[0]==1'b1) ? lcd_rgb_i[23] : 1'bz;  //R7:M0
assign lcd_id_o[1] = (lcd_id_t[1]==1'b1) ? lcd_rgb_i[15] : 1'bz;  //G7:M1
assign lcd_id_o[2] = (lcd_id_t[2]==1'b1) ? lcd_rgb_i[7]  : 1'bz;  //B7:M2

endmodule
