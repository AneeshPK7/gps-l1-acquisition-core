# Prompt for the 32-bit FFT Vivado run (Claude desktop / Claude Code)

Paste the block below into Claude (Code tab) on the PC that has Vivado installed. It runs
the 16-bit and 32-bit FFT engine in Vivado's simulator (xsim), builds both out of context
on the Zynq-7020 at 100 MHz, and collects the results into `RESULTS_FFT32.md`. These are
the Vivado numbers for report Section 6.3 (16-bit vs 32-bit baseband), which so far uses
Yosys estimates. The run takes about 20–40 minutes. It does not install Vivado, change the
RTL, or push to GitHub.

```
I need you to run Vivado simulations and builds for the FFT engine of a GPS L1
acquisition core FPGA project, at 16-bit and 32-bit word length, and collect the results.
The repository is public:
https://github.com/AneeshPK7/gps-l1-acquisition-core

1. Check the setup
   - Find the installed Vivado and its settings script (settings64.bat on Windows,
     settings64.sh on Linux). Tell me the version.
   - If Vivado is not installed, STOP and tell me. Do not download or install it.

2. Get the code
   - Clone the repo into a short path with no spaces (on Windows: C:/work/gps).
     If it is already cloned there, run "git pull" instead.
   - Check that these files exist: vivado/fft_width.tcl, hw/mem/twiddle32.hex,
     hw/sim/vectors/fft32/in.hex. If any is missing, STOP and tell me.

3. Simulation in xsim, run from the hw/ folder. Use a separate xsim work folder per width
   so the two builds do not overwrite each other, or just run them one after another.
   16-bit FFT (the shipped design):
     xvlog -sv rtl/sdf_stage.sv rtl/fft_sdf.sv tb/tb_fft.sv
     xelab tb_fft -s fft16
     xsim fft16 -R
   32-bit FFT (the comparison build; FFT_DW selects the 32-bit vectors and twiddles):
     xvlog -sv -d "FFT_DW=32" rtl/sdf_stage.sv rtl/fft_sdf.sv tb/tb_fft.sv
   (keep the quotes: Windows cmd otherwise splits the define at "=")
     xelab tb_fft -s fft32
     xsim fft32 -R
   Expected for both: "FFT latency: 1053 cycles" and "TB_FFT PASS: 5120 samples bit-exact".

4. Out-of-context builds, run from the repository root (about 10-20 minutes per width):
     vivado -mode batch -source vivado/fft_width.tcl
   This builds DW=16 and then DW=32 and writes the reports to vivado/fft_width/dw16/ and
   vivado/fft_width/dw32/. To build one width only: add "-tclargs 32" (or 16).
   Run it as a normal foreground command with a long timeout (at least 60 minutes).
   Do NOT start Vivado as a detached background process.

5. If something fails:
   - Read vivado.log (or the xsim output) and find the first real error.
   - You may fix problems in vivado/fft_width.tcl, such as Tcl quoting of the TW_FILE
     generic (it must be the full path of the .hex file), or command options that differ
     in this Vivado version.
   - Do NOT change anything in hw/rtl/, hw/tb/, hw/mem/ or the test vectors. If an error
     seems to need such a change, stop and explain it instead.
   - Timing NOT being met at 100 MHz for DW=32 is a valid result, not an error. Do not
     try to fix it; just report it.
   - Keep a list of every change you made.

6. Collect the results into a file RESULTS_FFT32.md in the repo root containing:
   - Vivado version, OS, part (xc7z020clg400-1)
   - xsim: the latency and PASS/FAIL lines for 16-bit and 32-bit
   - A table with one column per width (16-bit, 32-bit) and these rows, taken from
     vivado/fft_width/dw<W>/utilization.txt and timing_summary.txt:
       Slice LUTs, LUT as Logic, LUT as Memory, Slice Registers, Block RAM Tiles
       (and how many RAMB36 / RAMB18), DSPs, each with % of the device;
       WNS, TNS, WHS, number of failing endpoints, timing met at 100 MHz (yes/no),
       estimated max clock = 1000 / (10 - WNS) MHz
   - For each width, the worst setup path from timing_summary.txt: start point,
     end point, data path delay, logic levels
   - The exact diff of any changes you made to vivado/fft_width.tcl, with the reason

7. Package the results
   - Zip RESULTS_FFT32.md, the whole vivado/fft_width/ folder, the xsim output text and
     the Vivado log(s) into gps_fft32_results.zip on the Desktop and tell me where it is.
   - Do not commit or push anything to GitHub.
```

When the zip is ready, send it back here. The results will replace the Yosys estimates in
Table 7 of the report.
