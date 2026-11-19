`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// fft_sdf.sv - 1024-point radix-2 SDF DIF FFT (one sample per clock)
//
// Ten sdf_stage instances in a generate loop; a divide-by-2 on every even stage
// (total gain 1/32 = 1/sqrt(N)) keeps noise-like GNSS data inside 16 bits.
// Output is in bit-reversed order: the j-th output sample after out_sop is bin
// bitrev(j).  Latency = (N-1) + 3*LOG2N = 1053 cycles.
// The inverse FFT is obtained by conjugating the input (done by the caller).
// -----------------------------------------------------------------------------
module fft_sdf #(
    parameter int LOG2N   = 10,
    parameter     TW_FILE = "mem/twiddle.hex",
    parameter int DW      = 16              // 16 = this design; 32 = wide comparison build
) (
    input  logic               clk,
    input  logic               rst,
    input  logic               in_valid,
    input  logic               in_sop,
    input  logic signed [DW-1:0] in_re,
    input  logic signed [DW-1:0] in_im,
    output logic               out_valid,
    output logic               out_sop,
    output logic signed [DW-1:0] out_re,
    output logic signed [DW-1:0] out_im
);
    logic               v  [0:LOG2N];
    logic               s  [0:LOG2N];
    logic signed [DW-1:0] re [0:LOG2N];
    logic signed [DW-1:0] im [0:LOG2N];

    assign v[0]  = in_valid;
    assign s[0]  = in_sop;
    assign re[0] = in_re;
    assign im[0] = in_im;

    genvar g;
    generate
        for (g = 0; g < LOG2N; g++) begin : g_stage
            sdf_stage #(
                .LOG2N  (LOG2N),
                .STAGE  (g),
                .SCALE  ((g % 2) == 0),
                .TW_FILE(TW_FILE),
                .DW     (DW)
            ) u_stage (
                .clk      (clk),
                .rst      (rst),
                .in_valid (v[g]),
                .in_sop   (s[g]),
                .in_re    (re[g]),
                .in_im    (im[g]),
                .out_valid(v[g+1]),
                .out_sop  (s[g+1]),
                .out_re   (re[g+1]),
                .out_im   (im[g+1])
            );
        end
    endgenerate

    assign out_valid = v[LOG2N];
    assign out_sop   = s[LOG2N];
    assign out_re    = re[LOG2N];
    assign out_im    = im[LOG2N];
endmodule
