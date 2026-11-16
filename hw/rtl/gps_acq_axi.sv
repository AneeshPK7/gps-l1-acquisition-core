`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// gps_acq_axi.sv - top level: acquisition core + AXI4-Lite register slave
//                  + AXI4-Stream sample input + done interrupt
//
// Port names follow the Vivado IP-packager conventions (s_axi_*, s_axis_*) so the
// module can be dropped into a Zynq-7000 block design (GP0 -> s_axi, AXI DMA
// MM2S -> s_axis, irq -> IRQ_F2P).
//
// Register map (byte offsets)
//   0x00 CTRL        R/W  bit0 start (self-clearing), bit1 soft reset (self-clearing),
//                         bit2 interrupt enable
//   0x04 STATUS      R    bit0 busy, bit1 done, bit2 detected
//   0x08 PRN         R/W  satellite to search (1..32)
//   0x0C THRESH      R/W  peak / second-peak threshold, Q8.8 (reset 0x0200 = 2.0)
//   0x10 DOPPLER     R    detected Doppler bin k, signed, 1 kHz units
//   0x14 CODE_PHASE  R    detected code phase, 0..1023 samples
//   0x18 PEAK        R    peak power P1
//   0x1C SECOND      R    second-peak power P2
//   0x20 CYCLES      R    clock cycles of the last search
//   0x24 EXPONENT    R    block exponent used for the inverse transforms (debug)
//   0x28 ID          R    0x47505331 ("GPS1")
// -----------------------------------------------------------------------------
module gps_acq_axi #(
    parameter TW_FILE  = "mem/twiddle.hex",
    parameter ROM_FILE = "mem/code_rom.hex"
) (
    input  logic        s_axi_aclk,
    input  logic        s_axi_aresetn,
    // AXI4-Lite slave
    input  logic [7:0]  s_axi_awaddr,
    input  logic        s_axi_awvalid,
    output logic        s_axi_awready,
    input  logic [31:0] s_axi_wdata,
    input  logic [3:0]  s_axi_wstrb,
    input  logic        s_axi_wvalid,
    output logic        s_axi_wready,
    output logic [1:0]  s_axi_bresp,
    output logic        s_axi_bvalid,
    input  logic        s_axi_bready,
    input  logic [7:0]  s_axi_araddr,
    input  logic        s_axi_arvalid,
    output logic        s_axi_arready,
    output logic [31:0] s_axi_rdata,
    output logic [1:0]  s_axi_rresp,
    output logic        s_axi_rvalid,
    input  logic        s_axi_rready,
    // AXI4-Stream sample input
    input  logic [31:0] s_axis_tdata,
    input  logic        s_axis_tvalid,
    input  logic        s_axis_tlast,
    output logic        s_axis_tready,
    // interrupt (level, active high)
    output logic        irq
);
    wire clk = s_axi_aclk;

    // ---------------------------------------------------------------- registers
    logic        start_p, srst_p, irq_en;
    logic [5:0]  prn_r;
    logic [15:0] thresh_r;

    logic        busy, done, detected;
    logic signed [3:0] doppler_bin;
    logic [9:0]  code_phase;
    logic [31:0] peak, second, cycles;
    logic [3:0]  exponent;

    wire core_rst = ~s_axi_aresetn | srst_p;

    // ---------------------------------------------------------------- write channel
    wire wr_fire = s_axi_awvalid && s_axi_wvalid && !s_axi_bvalid;
    assign s_axi_awready = wr_fire;
    assign s_axi_wready  = wr_fire;
    assign s_axi_bresp   = 2'b00;

    always_ff @(posedge clk) begin
        if (!s_axi_aresetn) begin
            s_axi_bvalid <= 1'b0;
            start_p      <= 1'b0;
            srst_p       <= 1'b0;
            irq_en       <= 1'b0;
            prn_r        <= 6'd1;
            thresh_r     <= 16'h0200;
        end else begin
            start_p <= 1'b0;
            srst_p  <= 1'b0;
            if (s_axi_bvalid && s_axi_bready) s_axi_bvalid <= 1'b0;
            if (wr_fire) begin
                s_axi_bvalid <= 1'b1;
                case (s_axi_awaddr[7:2])
                    6'h00: if (s_axi_wstrb[0]) begin
                        start_p <= s_axi_wdata[0];
                        srst_p  <= s_axi_wdata[1];
                        irq_en  <= s_axi_wdata[2];
                    end
                    6'h02: if (s_axi_wstrb[0]) prn_r <= s_axi_wdata[5:0];
                    6'h03: begin
                        if (s_axi_wstrb[0]) thresh_r[7:0]  <= s_axi_wdata[7:0];
                        if (s_axi_wstrb[1]) thresh_r[15:8] <= s_axi_wdata[15:8];
                    end
                    default: ;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- read channel
    assign s_axi_arready = s_axi_arvalid && !s_axi_rvalid;
    assign s_axi_rresp   = 2'b00;

    always_ff @(posedge clk) begin
        if (!s_axi_aresetn) begin
            s_axi_rvalid <= 1'b0;
            s_axi_rdata  <= '0;
        end else begin
            if (s_axi_rvalid && s_axi_rready) s_axi_rvalid <= 1'b0;
            if (s_axi_arready) begin
                s_axi_rvalid <= 1'b1;
                case (s_axi_araddr[7:2])
                    6'h00: s_axi_rdata <= {29'd0, irq_en, 2'b00};
                    6'h01: s_axi_rdata <= {29'd0, detected, done, busy};
                    6'h02: s_axi_rdata <= {26'd0, prn_r};
                    6'h03: s_axi_rdata <= {16'd0, thresh_r};
                    6'h04: s_axi_rdata <= 32'($signed(doppler_bin));
                    6'h05: s_axi_rdata <= {22'd0, code_phase};
                    6'h06: s_axi_rdata <= peak;
                    6'h07: s_axi_rdata <= second;
                    6'h08: s_axi_rdata <= cycles;
                    6'h09: s_axi_rdata <= {28'd0, exponent};
                    6'h0A: s_axi_rdata <= 32'h47505331;
                    default: s_axi_rdata <= 32'd0;
                endcase
            end
        end
    end

    assign irq = irq_en & done;

    // ---------------------------------------------------------------- core
    acq_core #(.TW_FILE(TW_FILE), .ROM_FILE(ROM_FILE)) u_core (
        .clk          (clk),
        .rst          (core_rst),
        .start        (start_p),
        .prn          (prn_r),
        .thresh       (thresh_r),
        .s_axis_tdata (s_axis_tdata),
        .s_axis_tvalid(s_axis_tvalid),
        .s_axis_tlast (s_axis_tlast),
        .s_axis_tready(s_axis_tready),
        .busy         (busy),
        .done         (done),
        .detected     (detected),
        .doppler_bin  (doppler_bin),
        .code_phase   (code_phase),
        .peak         (peak),
        .second       (second),
        .cycles       (cycles),
        .exponent     (exponent)
    );
endmodule
