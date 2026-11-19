// -----------------------------------------------------------------------------
// tb_fft.sv - unit test of the 1024-point SDF FFT
// Streams four back-to-back frames (impulse, tone, full-scale random, GNSS
// baseband) followed by a gap and a repeat of frame 0, and compares every output
// sample bit-exactly with the bit-true Python model (sim/vectors/fft/out.hex).
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
// Build with -DFFT_DW=32 for the 32-bit comparison FFT (vectors in sim/vectors/fft32).
`ifdef FFT_DW
`define FFT_VEC "sim/vectors/fft32"
`define FFT_TW  "mem/twiddle32.hex"
`else
`define FFT_DW  16
`define FFT_VEC "sim/vectors/fft"
`define FFT_TW  "mem/twiddle.hex"
`endif
module tb_fft;
    localparam int N = 1024, NF = 4;
    localparam int DW = `FFT_DW;

    logic clk = 0, rst = 1;
    always #5 clk = ~clk;                    // 100 MHz

    logic in_valid = 0, in_sop = 0;
    logic signed [DW-1:0] in_re = 0, in_im = 0;
    logic out_valid, out_sop;
    logic signed [DW-1:0] out_re, out_im;

    fft_sdf #(.DW(DW), .TW_FILE(`FFT_TW)) dut (.*);

    logic [2*DW-1:0] vin  [0:NF*N-1];
    logic [2*DW-1:0] vout [0:NF*N-1];
    initial begin
        $readmemh({`FFT_VEC, "/in.hex"}, vin);
        $readmemh({`FFT_VEC, "/out.hex"}, vout);
    end

    // expected output order: frames 0..3, then frame 0 again
    int frame_seq [0:NF] = '{0, 1, 2, 3, 0};
    int nout = 0, errors = 0, first_out_cycle = -1, cycle = 0;
    always @(posedge clk) cycle <= cycle + 1;

    task automatic send_frame(input int f);
        for (int i = 0; i < N; i++) begin
            in_valid <= 1;
            in_sop   <= (i == 0);
            in_re    <= vin[f*N + i][2*DW-1:DW];
            in_im    <= vin[f*N + i][DW-1:0];
            @(posedge clk);
        end
        in_valid <= 0;
        in_sop   <= 0;
    endtask

    int f, j;
    logic [2*DW-1:0] exp_w;
    always @(posedge clk) begin
        if (out_valid) begin
            f = frame_seq[nout / N];
            j = nout % N;
            exp_w = vout[f*N + j];
            if (first_out_cycle < 0) first_out_cycle = cycle;
            if ((j == 0) != out_sop) begin
                $display("ERROR: sop mismatch at output %0d", nout);
                errors++;
            end
            if ({out_re, out_im} !== exp_w) begin
                if (errors < 10)
                    $display("ERROR frame %0d slot %0d: got %0d,%0dj expected %0d,%0dj", f, j,
                             out_re, out_im, $signed(exp_w[2*DW-1:DW]), $signed(exp_w[DW-1:0]));
                errors++;
            end
            nout++;
        end
    end

    int start_cycle;
    initial begin
        repeat (4) @(posedge clk);
        rst <= 0;
        @(posedge clk);
        start_cycle = cycle;
        for (int f = 0; f < NF; f++) send_frame(f);   // back-to-back frames
        repeat (1500) @(posedge clk);                  // idle gap
        send_frame(0);                                 // isolated frame
        repeat (1200) @(posedge clk);
        $display("FFT latency: %0d cycles", first_out_cycle - start_cycle - 1);
        if (nout != (NF + 1) * N) begin
            $display("ERROR: got %0d output samples, expected %0d", nout, (NF + 1) * N);
            errors++;
        end
        if (errors == 0) $display("TB_FFT PASS: %0d samples bit-exact", nout);
        else             $display("TB_FFT FAIL: %0d errors", errors);
        $finish;
    end
endmodule
