`timescale 1ns / 1ps
// -----------------------------------------------------------------------------
// acq_core.sv - FFT-based parallel code phase acquisition core, GPS L1 C/A
//
//   capture buffer (1 ms, 4096 x 3-bit, written by AXI-Stream, 4 samples/word)
//     -> fs/4 mixer + sum-of-4 decimator (no multipliers)        -> FFT (forward)
//     -> spectrum RAM (natural order) + block exponent
//     -> for k = -5..+5 :  X[(m+k) mod N] * conj(FFT(code))[m]   (ROM, 8+8 bit)
//                          >> e, conj                              -> FFT (inverse)
//                          |.|^2 -> peak tracker + 2-bank row buffer
//     -> second-peak scan of the best row (|tau'-tau| > 2) -> P1*256 > P2*THRESH
//
// One FFT engine does all 12 transforms.  The eleven inverse transforms are
// streamed back-to-back.  Bit-exact with model/bit_true_model.py::acquire.
// -----------------------------------------------------------------------------
module acq_core #(
    parameter TW_FILE  = "mem/twiddle.hex",
    parameter ROM_FILE = "mem/code_rom.hex"
) (
    input  logic               clk,
    input  logic               rst,          // synchronous, active high
    // control
    input  logic               start,        // 1-cycle pulse
    input  logic [5:0]         prn,          // 1..32
    input  logic [15:0]        thresh,       // Q8.8
    // sample input (AXI-Stream slave, from AXI DMA or the front-end capture logic)
    input  logic [31:0]        s_axis_tdata, // 4 samples: byte i bits [2:0] = sample 4w+i
    input  logic               s_axis_tvalid,
    input  logic               s_axis_tlast,
    output logic               s_axis_tready,
    // status / results
    output logic               busy,
    output logic               done,         // sticky until next start
    output logic               detected,
    output logic signed [3:0]  doppler_bin,  // -5..+5 (1 kHz)
    output logic [9:0]         code_phase,   // 0..1023 samples
    output logic [31:0]        peak,
    output logic [31:0]        second,
    output logic [31:0]        cycles,
    output logic [3:0]         exponent
);
    localparam int N = 1024;

    // ======================================================================
    // capture buffer: 1024 words x 12 bits (4 x 3-bit codes)
    // ======================================================================
    (* ram_style = "block" *) logic [11:0] cap_mem [0:N-1];
    logic [9:0]  cap_wptr;
    logic [9:0]  cap_raddr;
    logic [11:0] cap_q;

    assign s_axis_tready = ~busy;

    always_ff @(posedge clk) begin
        if (rst) cap_wptr <= '0;
        else if (s_axis_tvalid && s_axis_tready) begin
            cap_mem[cap_wptr] <= {s_axis_tdata[26:24], s_axis_tdata[18:16],
                                  s_axis_tdata[10:8],  s_axis_tdata[2:0]};
            cap_wptr <= s_axis_tlast ? 10'd0 : cap_wptr + 10'd1;
        end
    end
    always_ff @(posedge clk) cap_q <= cap_mem[cap_raddr];

    // ======================================================================
    // memories: spectrum RAM, code ROM, row buffer
    // ======================================================================
    (* ram_style = "block" *) logic [31:0] spec_mem [0:N-1];
    logic [9:0]  spec_raddr, spec_waddr;
    logic [31:0] spec_q, spec_wdata;
    logic        spec_we;
    always_ff @(posedge clk) begin
        if (spec_we) spec_mem[spec_waddr] <= spec_wdata;
        spec_q <= spec_mem[spec_raddr];
    end

    // 32 PRN x 1024 x (8+8) bit = 512 kb: force block RAM (Vivado otherwise built it
    // from ~9 400 LUTs)
    (* rom_style = "block" *) logic [15:0] code_rom [0:32*N-1];
    initial $readmemh(ROM_FILE, code_rom);
    logic [14:0] rom_addr;
    logic [15:0] rom_q;
    always_ff @(posedge clk) rom_q <= code_rom[rom_addr];

    (* ram_style = "block" *) logic [31:0] row_mem [0:2*N-1];
    logic [10:0] row_raddr, row_waddr;
    logic [31:0] row_q, row_wdata;
    logic        row_we;
    always_ff @(posedge clk) begin
        if (row_we) row_mem[row_waddr] <= row_wdata;
        row_q <= row_mem[row_raddr];
    end

    // ======================================================================
    // control FSM
    // ======================================================================
    typedef enum logic [2:0] {
        S_IDLE, S_FWD_FEED, S_FWD_WAIT, S_BIN_FEED, S_BIN_WAIT, S_SCAN, S_SCAN_WAIT, S_DECIDE
    } state_t;
    state_t state;

    logic [9:0]  m;              // sample index of the frame being fed
    logic [3:0]  kidx;           // Doppler bin index 0..10 (k = kidx - 5)
    logic [4:0]  prn_m1;
    logic [15:0] thr_r;
    logic        fwd_last, bins_last;

    // results of the inverse-FFT stage (declared here, driven below)
    logic [31:0] p1, p2;
    logic [3:0]  best_row;
    logic [9:0]  best_tau;
    logic        best_bank;
    logic [16:0] maxabs;

    function automatic logic [3:0] blk_exp(input logic [16:0] v);
        int bl;
        bl = 0;
        for (int i = 0; i < 17; i++) if (v[i]) bl = i + 1;
        blk_exp = (bl > 6) ? 4'(bl - 6) : 4'd0;
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            state    <= S_IDLE;
            busy     <= 1'b0;
            done     <= 1'b0;
            detected <= 1'b0;
            cycles   <= '0;
            m        <= '0;
            kidx     <= '0;
            exponent <= '0;
            prn_m1   <= '0;
            thr_r    <= 16'h0200;
        end else begin
            if (busy) cycles <= cycles + 1;
            case (state)
                S_IDLE: if (start) begin
                    busy   <= 1'b1;
                    done   <= 1'b0;
                    cycles <= 32'd1;
                    prn_m1 <= 5'(prn - 6'd1);
                    thr_r  <= thresh;
                    m      <= '0;
                    state  <= S_FWD_FEED;
                end
                S_FWD_FEED: begin
                    m <= m + 1;
                    if (m == N - 1) state <= S_FWD_WAIT;
                end
                S_FWD_WAIT: if (fwd_last) begin
                    exponent <= blk_exp(maxabs);
                    m        <= '0;
                    kidx     <= '0;
                    state    <= S_BIN_FEED;
                end
                S_BIN_FEED: begin
                    m <= m + 1;
                    if (m == N - 1) begin
                        kidx <= kidx + 1;
                        if (kidx == 4'd10) state <= S_BIN_WAIT;
                    end
                end
                S_BIN_WAIT: if (bins_last) begin
                    m     <= '0;
                    state <= S_SCAN;
                end
                S_SCAN: begin
                    m <= m + 1;
                    if (m == N - 1) state <= S_SCAN_WAIT;
                end
                S_SCAN_WAIT: state <= S_DECIDE;   // last row-buffer word arrives
                S_DECIDE: begin
                    detected <= (48'({p1, 8'd0}) > (48'(p2) * 48'(thr_r)));
                    busy     <= 1'b0;
                    done     <= 1'b1;
                    state    <= S_IDLE;
                end
                default: state <= S_IDLE;
            endcase
        end
    end

    wire inverse = (state == S_BIN_FEED) || (state == S_BIN_WAIT);

    // ======================================================================
    // FFT input path
    // ======================================================================
    // forward: capture buffer -> fs/4 mixer + decimate-by-4
    assign cap_raddr = m;
    logic fe_v1, fe_s1, fe_v2, fe_s2;
    logic signed [15:0] fe_re, fe_im;

    // ADC code c (3-bit two's complement) -> value 2c+1 = {c, 1'b1}
    wire signed [3:0] v0 = {cap_q[2:0],  1'b1};
    wire signed [3:0] v1 = {cap_q[5:3],  1'b1};
    wire signed [3:0] v2 = {cap_q[8:6],  1'b1};
    wire signed [3:0] v3 = {cap_q[11:9], 1'b1};
    // LO = 1, -j, -1, +j  ->  I = v0 - v2, Q = v3 - v1   (gain 64 = << 6)
    wire signed [4:0] mix_i = v0 - v2;
    wire signed [4:0] mix_q = v3 - v1;

    always_ff @(posedge clk) begin
        if (rst) begin
            {fe_v1, fe_s1, fe_v2, fe_s2} <= '0;
        end else begin
            fe_v1 <= (state == S_FWD_FEED);
            fe_s1 <= (state == S_FWD_FEED) && (m == 0);
            fe_v2 <= fe_v1;
            fe_s2 <= fe_s1;
        end
        fe_re <= 16'(mix_i) <<< 6;
        fe_im <= 16'(mix_q) <<< 6;
    end

    // inverse: spectrum (circularly shifted by k) x code ROM, block-exponent shift, conj
    assign spec_raddr = m + 10'(kidx) - 10'd5;          // (m + k) mod N
    assign rom_addr   = {prn_m1, m};

    // pipeline: 1 RAM/ROM read | 2 complex multiply | 3 round + block-exponent shift
    //           | 4 saturate + conjugate  (stages 3 and 4 split to meet 100 MHz)
    logic bn_v1, bn_s1, bn_v2, bn_s2, bn_v3, bn_s3, bn_v4, bn_s4;
    logic signed [25:0] pr, pi;          // stage 2: products
    logic signed [25:0] pr_t, pi_t;      // stage 3: rounded and shifted
    logic signed [15:0] bn_re, bn_im;    // stage 4: FFT input

    wire signed [15:0] xr = spec_q[31:16];
    wire signed [15:0] xi = spec_q[15:0];
    wire signed [7:0]  cr = rom_q[15:8];
    wire signed [7:0]  ci = rom_q[7:0];

    // rounding constant 2^(e-1), registered once per search (exponent is static
    // during the Doppler bins), so stage 3 is only an adder and a barrel shifter
    logic signed [25:0] rnd_c;
    always_ff @(posedge clk)
        rnd_c <= (exponent == 0) ? 26'sd0 : (26'sd1 <<< (exponent - 1));

    function automatic logic signed [15:0] sat16(input logic signed [25:0] t);
        if (t > 26'sd32767)       sat16 = 16'sh7fff;
        else if (t < -26'sd32768) sat16 = 16'sh8000;
        else                      sat16 = t[15:0];
    endfunction

    // conj(sat16(t)) with saturation: sat16 = -32768 maps to +32767
    function automatic logic signed [15:0] neg_sat16(input logic signed [25:0] t);
        if (t <= -26'sd32768)     neg_sat16 = 16'sh7fff;
        else if (t >= 26'sd32767) neg_sat16 = -16'sh7fff;
        else                      neg_sat16 = 16'(-t);
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            {bn_v1, bn_s1, bn_v2, bn_s2, bn_v3, bn_s3, bn_v4, bn_s4} <= '0;
        end else begin
            bn_v1 <= (state == S_BIN_FEED);
            bn_s1 <= (state == S_BIN_FEED) && (m == 0);
            {bn_v2, bn_s2} <= {bn_v1, bn_s1};
            {bn_v3, bn_s3} <= {bn_v2, bn_s2};
            {bn_v4, bn_s4} <= {bn_v3, bn_s3};
        end
        pr    <= xr * cr - xi * ci;
        pi    <= xr * ci + xi * cr;
        pr_t  <= (pr + rnd_c) >>> exponent;
        pi_t  <= (pi + rnd_c) >>> exponent;
        bn_re <= sat16(pr_t);
        bn_im <= neg_sat16(pi_t);
    end

    // FFT engine (shared by forward and inverse transforms)
    logic fft_ov, fft_os;
    logic signed [15:0] fft_ore, fft_oim;
    fft_sdf #(.TW_FILE(TW_FILE)) u_fft (
        .clk      (clk),
        .rst      (rst),
        .in_valid (fe_v2 | bn_v4),
        .in_sop   (fe_s2 | bn_s4),
        .in_re    (fe_v2 ? fe_re : bn_re),
        .in_im    (fe_v2 ? fe_im : bn_im),
        .out_valid(fft_ov),
        .out_sop  (fft_os),
        .out_re   (fft_ore),
        .out_im   (fft_oim)
    );

    // ======================================================================
    // FFT output path
    // ======================================================================
    function automatic logic [9:0] bitrev10(input logic [9:0] x);
        for (int i = 0; i < 10; i++) bitrev10[i] = x[9 - i];
    endfunction

    logic [9:0] oj_cnt, oj;
    logic [3:0] orow;
    assign oj = fft_os ? 10'd0 : oj_cnt;

    always_ff @(posedge clk) begin
        if (rst || state == S_IDLE) begin
            oj_cnt <= '0;
            orow   <= '0;
        end else if (fft_ov) begin
            oj_cnt <= oj + 1;
            if (inverse && oj == N - 1) orow <= orow + 1;
        end
    end

    // forward output -> spectrum RAM (natural order) + max |Re|,|Im|
    wire [16:0] abs_re = fft_ore[15] ? 17'(-$signed({fft_ore[15], fft_ore})) : 17'(fft_ore);
    wire [16:0] abs_im = fft_oim[15] ? 17'(-$signed({fft_oim[15], fft_oim})) : 17'(fft_oim);

    assign spec_we    = fft_ov && !inverse;
    assign spec_waddr = bitrev10(oj);
    assign spec_wdata = {fft_ore, fft_oim};
    assign fwd_last   = fft_ov && !inverse && (oj == N - 1);

    always_ff @(posedge clk) begin
        if (rst || state == S_IDLE) maxabs <= '0;
        else if (spec_we) begin
            if (abs_re > maxabs && abs_re >= abs_im) maxabs <= abs_re;
            else if (abs_im > maxabs)                maxabs <= abs_im;
        end
    end

    // inverse output -> |.|^2 -> peak tracker / row buffer
    logic        pw_v, pw_last;
    logic [31:0] pw;
    wire signed [31:0] sq_re = fft_ore * fft_ore;
    wire signed [31:0] sq_im = fft_oim * fft_oim;
    logic [9:0]  pw_tau;
    logic [3:0]  pw_row;
    always_ff @(posedge clk) begin
        if (rst) pw_v <= 1'b0;
        else     pw_v <= fft_ov && inverse;
        pw      <= $unsigned(sq_re) + $unsigned(sq_im);
        pw_tau  <= bitrev10(oj);
        pw_row  <= orow;
        pw_last <= (oj == N - 1);
    end

    logic wr_bank, row_has_max;
    wire  newmax = pw > p1;
    assign bins_last = pw_v && pw_last && (pw_row == 4'd10);

    assign row_we    = pw_v;
    assign row_waddr = {wr_bank, pw_tau};
    assign row_wdata = pw;

    always_ff @(posedge clk) begin
        if (rst || (state == S_IDLE && start)) begin
            p1          <= '0;
            best_row    <= '0;
            best_tau    <= '0;
            best_bank   <= 1'b0;
            wr_bank     <= 1'b0;
            row_has_max <= 1'b0;
        end else if (pw_v) begin
            if (newmax) begin
                p1       <= pw;
                best_row <= pw_row;
                best_tau <= pw_tau;
            end
            if (pw_last) begin
                row_has_max <= 1'b0;
                if (row_has_max || newmax) begin   // keep this row, write the other bank
                    best_bank <= wr_bank;
                    wr_bank   <= ~wr_bank;
                end
            end else if (newmax) begin
                row_has_max <= 1'b1;
            end
        end
    end

    // second-peak scan over the best row, excluding |tau' - tau| <= 2
    assign row_raddr = {best_bank, m};
    logic       sc_v;
    logic [9:0] sc_tau;
    always_ff @(posedge clk) begin
        if (rst) sc_v <= 1'b0;
        else     sc_v <= (state == S_SCAN);
        sc_tau <= m;
    end
    wire [9:0] tau_dist = sc_tau - best_tau;
    wire       excl = (tau_dist <= 10'd2) || (tau_dist >= 10'd1022);

    always_ff @(posedge clk) begin
        if (rst || (state == S_IDLE && start)) p2 <= '0;
        else if (sc_v && !excl && row_q > p2) p2 <= row_q;
    end

    // results
    assign doppler_bin = $signed(best_row) - 4'sd5;
    assign code_phase  = best_tau;
    assign peak        = p1;
    assign second      = p2;

endmodule
