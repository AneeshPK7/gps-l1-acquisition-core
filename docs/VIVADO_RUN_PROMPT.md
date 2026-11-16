# Prompt for running the Vivado build with Claude Code

Paste the block below into Claude Code on a Windows / Linux PC that has Vivado installed.
It runs the simulations and the bitstream build and collects the timing and utilisation
results into `RESULTS_VIVADO.md`. It does not install Vivado, change the RTL, or push to
GitHub. Manual steps for the same run are in [RUN_ON_PC.md](RUN_ON_PC.md).

```
I need you to run the Vivado build and tests for a GPS L1 acquisition core FPGA project
and collect the results. The repository is public:
https://github.com/AneeshPK7/gps-l1-acquisition-core

Step-by-step instructions are in docs/RUN_ON_PC.md in that repo; read it first and follow it.

1. Check the setup
   - Find the installed Vivado (2022.2 or 2023.x preferred) and its settings script
     (settings64.bat on Windows, settings64.sh on Linux). Tell me the version.
   - If Vivado is not installed, STOP and tell me. Do not download or install it yourself.
   - Check whether PYNQ-Z2 or ZedBoard board files are installed (<Vivado>/data/boards/board_files).
     If they are missing, continue anyway and note it.

2. Get the code
   - Clone the repo into a short path with no spaces (on Windows: C:/work/gps).

3. Simulation in Vivado's simulator (xsim), run from the hw/ folder:
     xvlog -sv rtl/sdf_stage.sv rtl/fft_sdf.sv rtl/acq_core.sv rtl/gps_acq_axi.sv tb/tb_gps_acq.sv
     xelab tb_gps_acq -s tb_sim
     xsim tb_sim -R -testplusarg "VEC=sim/vectors/directed"
     xsim tb_sim -R -testplusarg "VEC=sim/vectors/regress" -testplusarg TRUTH_STAT
   Expected: "bit-exact vs model : 8 / 8" and "24 / 24", and "TB_GPS_ACQ PASS" for both runs.

4. Bitstream build, run from the repository root (takes 15-30 minutes):
     vivado -mode batch -source vivado/build.tcl
   (add "-tclargs zedboard" at the end if only ZedBoard board files are installed)
   Run it as a normal foreground command with a long timeout (at least 45 minutes).
   Do NOT start Vivado as a detached background process: Vivado 2024.2 on Windows then
   fails in create_bd_design ("Failed to load feature 'ipintegrator'").
   If Vivado exits after the bitstream but before the reports are written, open
   vivado/build/gps_acq.xpr in a new Vivado batch session and re-run the last block of
   build.tcl (open_run impl_1, the three report_* commands, write_hw_platform).

5. If the build fails:
   - Read vivado.log and find the first real error.
   - You may fix problems in vivado/build.tcl, such as Tcl syntax, IP property names
     that differ in this Vivado version, or address-segment names.
   - Do NOT change the RTL design logic in hw/rtl/ or the test vectors. If an error
     seems to need an RTL change, stop and explain it instead.
   - Re-run the build after each fix, and keep a list of every change you made.

6. Collect the results into a file RESULTS_VIVADO.md in the repo root containing:
   - Vivado version, OS, part (xc7z020clg400-1 or clg484-1), whether board files were used
   - xsim results: pass/fail lines for the directed and regression runs
   - From vivado/reports/timing_summary.txt: WNS, TNS, WHS, and whether timing is met
     at 100 MHz. Estimated max clock = 1000 / (10 - WNS) MHz. Include the worst setup
     path (start point, end point, logic levels).
   - From vivado/reports/utilization.txt: Slice LUTs, LUT as Memory, Slice Registers,
     Block RAM Tiles, DSPs, each with % of the device
   - From vivado/reports/utilization_hier.txt: the same numbers for the "acq" cell only
     (the acquisition core without the PS and DMA)
   - The exact diff of any changes you made to build.tcl, with the reason for each

7. Do not commit or push anything to GitHub. When done, tell me where RESULTS_VIVADO.md
   and the vivado/reports/ folder are so I can send them back.
```

Send back `RESULTS_VIVADO.md` and the `vivado/reports/` folder.
