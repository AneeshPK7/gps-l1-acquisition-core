`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// sdf_stage.sv - one radix-2 single-path delay-feedback (SDF) DIF butterfly stage
//
// Stage STAGE of an N = 2^LOG2N point FFT has a feedback FIFO of L = N >> (STAGE+1)
// words.  For every block of 2L input samples:
//   first half  (j <  L): the input is pushed into the FIFO; the FIFO drains the
//                         differences of the previous block, multiplied by W[j<<STAGE]
//   second half (j >= L): top = FIFO, bottom = input; the sum is output and the
//                         difference is pushed back into the FIFO
// Sums and twiddled differences share one complex multiplier (sums use W = 1.0),
// followed by round-half-up and an optional divide-by-2 (SCALE) and saturation.
//
// Latency: L + 3 clock cycles.  The stage runs every clock; in_sop marks the first
// sample of a frame and resynchronises the block counter.  Frames must be sent
// back-to-back or separated by at least L idle cycles.
// Bit-exact with model/bit_true_model.py::fft_sdf.
// -----------------------------------------------------------------------------
module sdf_stage #(
    parameter int LOG2N   = 10,
    parameter int STAGE   = 0,
    parameter bit SCALE   = 1'b1,
    parameter     TW_FILE = "mem/twiddle.hex",
    parameter int DW      = 16              // data / twiddle word length (16 or 32)
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
    localparam int LOG2L = LOG2N - 1 - STAGE;
    localparam int L     = 1 << LOG2L;
    localparam int TWF   = DW - 2;                       // twiddles are Q2.(DW-2)
    localparam int SH    = TWF + (SCALE ? 1 : 0);
    localparam int PW    = 2*DW + 4;                     // product width
    localparam int DLY   = L + 3;

    // ---------------------------------------------------------------- block counter
    logic [LOG2L:0] cnt;
    wire  [LOG2L:0] idx    = (in_valid && in_sop) ? '0 : cnt;
    wire            second = idx[LOG2L];

    always_ff @(posedge clk) begin
        if (rst) cnt <= '0;
        else     cnt <= idx + 1'b1;
    end

    // ---------------------------------------------------------------- feedback FIFO
    // (DW+1)-bit I and Q (differences need one extra bit)
    logic signed [DW:0] fq_re, fq_im;          // FIFO output for this cycle
    logic signed [DW:0] wr_re, wr_im;          // value pushed this cycle
    logic [8:0]         tw_idx;

    wire signed [DW:0] in_re17 = {in_re[DW-1], in_re};
    wire signed [DW:0] in_im17 = {in_im[DW-1], in_im};

    always_comb begin
        if (second) begin
            wr_re = fq_re - in_re17;
            wr_im = fq_im - in_im17;
        end else begin
            wr_re = in_re17;
            wr_im = in_im17;
        end
    end

    generate
        if (LOG2L == 0) begin : g_reg_fifo
            logic [2*DW+1:0] fifo_r = '0;
            always_ff @(posedge clk) fifo_r <= {wr_re, wr_im};
            assign fq_re  = fifo_r[2*DW+1:DW+1];
            assign fq_im  = fifo_r[DW:0];
            assign tw_idx = 9'd0;
        end else begin : g_ram_fifo
            // simple dual-port RAM; the next read address is always ptr+1, so a
            // registered (BRAM-style) read is ready exactly when it is needed.
            logic [2*DW+1:0]  mem [0:L-1];
            logic [2*DW+1:0]  rd_q = '0;
            wire  [LOG2L-1:0] ptr     = idx[LOG2L-1:0];
            wire  [LOG2L-1:0] ptr_nxt = ptr + 1'b1;
            initial for (int i = 0; i < L; i++) mem[i] = '0;
            always_ff @(posedge clk) begin
                mem[ptr] <= {wr_re, wr_im};
                rd_q     <= mem[ptr_nxt];
            end
            assign fq_re  = rd_q[2*DW+1:DW+1];
            assign fq_im  = rd_q[DW:0];
            assign tw_idx = 9'(ptr) << STAGE;
        end
    endgenerate

    // ---------------------------------------------------------------- twiddle ROM
    logic [2*DW-1:0] tw_rom [0:511];
    initial $readmemh(TW_FILE, tw_rom);

    // ---------------------------------------------------------------- pipeline
    // P1: operand select + twiddle read
    logic signed [DW:0]   a_re, a_im;
    logic signed [DW-1:0] w_re, w_im;
    always_ff @(posedge clk) begin
        if (second) begin
            a_re <= fq_re + in_re17;
            a_im <= fq_im + in_im17;
            w_re <= DW'(1) <<< TWF;            // 1.0 in Q2.(DW-2)
            w_im <= '0;
        end else begin
            a_re <= fq_re;
            a_im <= fq_im;
            w_re <= tw_rom[tw_idx][2*DW-1:DW];
            w_im <= tw_rom[tw_idx][DW-1:0];
        end
    end

    // P2: complex multiply
    logic signed [PW-1:0] p_re, p_im;
    always_ff @(posedge clk) begin
        p_re <= a_re * w_re - a_im * w_im;
        p_im <= a_re * w_im + a_im * w_re;
    end

    // P3: round half up, scale, saturate
    localparam logic signed [PW-1:0] ONE  = 1;
    localparam logic signed [PW-1:0] MAXV = (ONE <<< (DW-1)) - 1;
    localparam logic signed [PW-1:0] MINV = -(ONE <<< (DW-1));
    function automatic logic signed [DW-1:0] rnd_sat(input logic signed [PW-1:0] v);
        logic signed [PW-1:0] t;
        t = (v + (ONE <<< (SH - 1))) >>> SH;
        if (t > MAXV)      rnd_sat = MAXV[DW-1:0];
        else if (t < MINV) rnd_sat = MINV[DW-1:0];
        else               rnd_sat = t[DW-1:0];
    endfunction

    always_ff @(posedge clk) begin
        out_re <= rnd_sat(p_re);
        out_im <= rnd_sat(p_im);
    end

    // ---------------------------------------------------------------- valid / sop delay
    logic [DLY-1:0] v_dly, s_dly;
    always_ff @(posedge clk) begin
        if (rst) begin
            v_dly <= '0;
            s_dly <= '0;
        end else begin
            v_dly <= {v_dly[DLY-2:0], in_valid};
            s_dly <= {s_dly[DLY-2:0], in_valid & in_sop};
        end
    end
    assign out_valid = v_dly[DLY-1];
    assign out_sop   = s_dly[DLY-1];

endmodule
