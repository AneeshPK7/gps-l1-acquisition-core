// -----------------------------------------------------------------------------
// tb_gps_acq.sv - self-checking system testbench for gps_acq_axi
//
// Acts like the PS: for each test case it streams 1 ms of samples over
// AXI4-Stream (as the AXI DMA would), writes PRN / THRESH / CTRL over AXI4-Lite,
// polls STATUS until done and reads the results.  Each case is checked twice:
//   1. bit-exact against the bit-true model (Doppler bin, code phase, P1, P2, detect)
//   2. against the true signal: Doppler bin nearest the true Doppler, code phase
//      within one sample, detection flag correct (report Section 6.1)
// It also checks CYCLES against the 1 ms (100 000 cycle @ 100 MHz) budget.
//
// Plusargs: +VEC=sim/vectors/directed  +CSV=sim/results_directed.csv  [+IRQ]
//           [+TRUTH_STAT]  random regression: truth hit-rate is reported as a
//                          statistic (weak / between-bin signals may legitimately
//                          miss); pass/fail then depends on the bit-exact check only
// -----------------------------------------------------------------------------
`timescale 1ns / 1ps
module tb_gps_acq;
    localparam int N = 1024, MAXT = 64, NF = 12;
    localparam int BUDGET = 100_000;           // 1 ms at 100 MHz

    logic clk = 0, rstn = 0;
    always #5 clk = ~clk;

    // AXI4-Lite
    logic [7:0]  awaddr = 0, araddr = 0;
    logic        awvalid = 0, wvalid = 0, bready = 0, arvalid = 0, rready = 0;
    logic [31:0] wdata = 0;
    logic        awready, wready, bvalid, arready, rvalid;
    logic [1:0]  bresp, rresp;
    logic [31:0] rdata;
    // AXI4-Stream
    logic [31:0] tdata = 0;
    logic        tvalid = 0, tlast = 0, tready;
    logic        irq;

    gps_acq_axi dut (
        .s_axi_aclk(clk), .s_axi_aresetn(rstn),
        .s_axi_awaddr(awaddr), .s_axi_awvalid(awvalid), .s_axi_awready(awready),
        .s_axi_wdata(wdata), .s_axi_wstrb(4'hf), .s_axi_wvalid(wvalid), .s_axi_wready(wready),
        .s_axi_bresp(bresp), .s_axi_bvalid(bvalid), .s_axi_bready(bready),
        .s_axi_araddr(araddr), .s_axi_arvalid(arvalid), .s_axi_arready(arready),
        .s_axi_rdata(rdata), .s_axi_rresp(rresp), .s_axi_rvalid(rvalid), .s_axi_rready(rready),
        .s_axis_tdata(tdata), .s_axis_tvalid(tvalid), .s_axis_tlast(tlast),
        .s_axis_tready(tready), .irq(irq)
    );

    // ---------------------------------------------------------------- AXI BFM
    task automatic axi_write(input logic [7:0] addr, input logic [31:0] data);
        @(posedge clk);
        awaddr <= addr; wdata <= data; awvalid <= 1; wvalid <= 1; bready <= 1;
        do @(posedge clk); while (!(awready && wready));
        awvalid <= 0; wvalid <= 0;
        while (!bvalid) @(posedge clk);
        @(posedge clk);
        bready <= 0;
    endtask

    task automatic axi_read(input logic [7:0] addr, output logic [31:0] data);
        @(posedge clk);
        araddr <= addr; arvalid <= 1; rready <= 1;
        do @(posedge clk); while (!arready);
        arvalid <= 0;
        while (!rvalid) @(posedge clk);
        data = rdata;
        @(posedge clk);
        rready <= 0;
    endtask

    // ---------------------------------------------------------------- vectors
    logic [31:0] samples [0:MAXT*N-1];
    logic [31:0] expv    [0:MAXT*NF-1];
    logic [31:0] meta    [0:0];
    string vec, csv;
    int fcsv;

    task automatic stream_case(input int t);
        for (int i = 0; i < N; i++) begin
            tdata  <= samples[t*N + i];
            tvalid <= 1;
            tlast  <= (i == N - 1);
            do @(posedge clk); while (!tready);
        end
        tvalid <= 0;
        tlast  <= 0;
    endtask

    // ---------------------------------------------------------------- test loop
    int ntests, n_bit_ok = 0, n_true_ok = 0, max_cycles = 0;
    logic use_irq, truth_stat;

    initial begin
        logic [31:0] st, dop, cp, pk, sp, cyc, id;
        int k_exp, k_true, tau_err;
        logic bit_ok, true_ok, present, det;
        real ratio;

        if (!$value$plusargs("VEC=%s", vec)) vec = "sim/vectors/directed";
        if (!$value$plusargs("CSV=%s", csv)) csv = "sim/results.csv";
        use_irq = $test$plusargs("IRQ");
        truth_stat = $test$plusargs("TRUTH_STAT");
        $readmemh($sformatf("%s/meta.hex", vec), meta);
        $readmemh($sformatf("%s/samples.hex", vec), samples);
        $readmemh($sformatf("%s/expected.hex", vec), expv);
        ntests = meta[0];
        fcsv = $fopen(csv, "w");
        $fwrite(fcsv, "id,prn,doppler_khz,code_phase_samples,code_phase_chips,peak,second,ratio,detected,cycles,bit_exact,truth_pass\n");

        repeat (5) @(posedge clk);
        rstn <= 1;
        repeat (2) @(posedge clk);
        axi_read(8'h28, id);
        $display("core ID = %h  (%s, %0d cases)", id, vec, ntests);
        if (use_irq) axi_write(8'h00, 32'h4);           // interrupt enable

        for (int t = 0; t < ntests; t++) begin
            // PS: DMA one millisecond of samples into the capture buffer
            stream_case(t);
            // PS: select satellite, threshold, start
            axi_write(8'h08, expv[t*NF + 0]);
            axi_write(8'h0C, expv[t*NF + 1]);
            axi_write(8'h00, use_irq ? 32'h5 : 32'h1);
            // PS: wait for done (poll STATUS or wait for the interrupt)
            if (use_irq) begin
                @(posedge irq);
                axi_read(8'h04, st);
            end else begin
                do axi_read(8'h04, st); while (!st[1]);
            end
            axi_read(8'h10, dop);
            axi_read(8'h14, cp);
            axi_read(8'h18, pk);
            axi_read(8'h1C, sp);
            axi_read(8'h20, cyc);

            det     = st[2];
            present = expv[t*NF + 7][0];
            bit_ok  = ($signed(dop) == $signed(expv[t*NF + 2])) && (cp == expv[t*NF + 3]) &&
                      (pk == expv[t*NF + 4]) && (sp == expv[t*NF + 5]) &&
                      (det == expv[t*NF + 6][0]);
            k_true  = $signed(expv[t*NF + 8]);
            tau_err = (int'(cp) * 16 - int'(expv[t*NF + 9]) + 16 * N * 3 / 2) % (16 * N) - 16 * N / 2;
            if (present)
                true_ok = ($signed(dop) == k_true) && (tau_err <= 16) && (tau_err >= -16) && det;
            else
                true_ok = !det;
            ratio = (sp == 0) ? 0.0 : real'(pk) / real'(sp);
            if (cyc > max_cycles) max_cycles = cyc;
            n_bit_ok  += bit_ok;
            n_true_ok += true_ok;

            $display("case %2d PRN %2d: k=%+0d kHz tau=%4d (%6.1f chips) P1/P2=%6.2f det=%0d cycles=%0d | model %s | truth %s",
                     t + 1, expv[t*NF + 0], $signed(dop), cp, cp * 1.023 / 1.024, ratio, det, cyc,
                     bit_ok ? "MATCH" : "MISMATCH", true_ok ? "PASS" : "FAIL");
            if (!bit_ok)
                $display("        expected k=%0d tau=%0d P1=%0d P2=%0d det=%0d", $signed(expv[t*NF + 2]),
                         expv[t*NF + 3], expv[t*NF + 4], expv[t*NF + 5], expv[t*NF + 6]);
            $fwrite(fcsv, "%0d,%0d,%0d,%0d,%.1f,%0d,%0d,%.2f,%0d,%0d,%0d,%0d\n", t + 1, expv[t*NF + 0],
                    $signed(dop), cp, cp * 1.023 / 1.024, pk, sp, ratio, det, cyc, bit_ok, true_ok);
        end
        $fclose(fcsv);

        $display("--------------------------------------------------------------");
        $display("bit-exact vs model : %0d / %0d", n_bit_ok, ntests);
        $display("truth checks       : %0d / %0d", n_true_ok, ntests);
        $display("max cycles / PRN   : %0d (%.3f ms at 100 MHz, budget %0d)", max_cycles,
                 max_cycles / 100000.0, BUDGET);
        if (n_bit_ok == ntests && (truth_stat || n_true_ok == ntests) && max_cycles < BUDGET)
            $display("TB_GPS_ACQ PASS");
        else
            $display("TB_GPS_ACQ FAIL");
        $finish;
    end

    initial begin
        #(64'd50_000_000 * 64);
        $display("TB_GPS_ACQ FAIL: timeout");
        $finish;
    end
endmodule
