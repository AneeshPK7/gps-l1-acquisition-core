# Running the project on a Windows / Linux PC with Vivado

Vivado runs only on x86-64 Windows or Linux (not on macOS or Apple-silicon Macs).
These steps build the bitstream and get the timing / utilisation numbers for the
report (Table 6), and optionally run the hardware-in-the-loop test on a board.

> `vivado/build.tcl` and the `sw/` application have not yet been run on real Vivado.
> If a step fails, keep `vivado.log` (written in the folder you ran Vivado from) and
> the error message.

## 1. Install Vivado (skip if the lab PC already has it)

1. Download the **AMD Unified Installer** (free account needed) from
   amd.com → Support → Downloads → Vivado. **2023.1** is recommended: it still has the
   classic Vitis IDE that `sw/main.c` is written for (2022.2 also works).
2. Choose **Vivado ML Standard** (free; the Zynq-7020 is supported) and tick **Vitis**
   if you want to run the software on a board.
3. In *Devices*, select only **SoCs → Zynq-7000** to keep the install around 40 GB.
4. PC needs: 16 GB RAM recommended (8 GB minimum), ~60 GB free disk.

### Board files (so the PS DDR/MIO settings match the board)

* **ZedBoard**: Vivado → *Tools → Vivado Store → Boards* → install *ZedBoard*.
* **PYNQ-Z2**: download the `pynq-z2` board-file folder from TUL's PYNQ-Z2 page and copy
  it into `<Vivado install>/data/boards/board_files/`.

Without board files the build still runs (it prints a warning), and the timing and
utilisation numbers are still valid, but the bitstream will not boot on the board.

## 2. Get the project

```bash
git clone https://github.com/AneeshPK7/gps-l1-acquisition-core.git
```

On Windows, clone into a **short path with no spaces**, e.g. `C:\work\gps`
(long paths break Vivado). Or download the ZIP from GitHub and extract it there.

## 3. Build the bitstream (about 15–30 min)

**Windows:** Start menu → *Vivado 2023.1 Tcl Shell*.
**Linux:** `source <Vivado install>/settings64.sh` in a terminal.

```bash
cd C:/work/gps                      # the repository root (use forward slashes on Windows)
vivado -mode batch -source vivado/build.tcl                     # PYNQ-Z2
vivado -mode batch -source vivado/build.tcl -tclargs zedboard   # ZedBoard
```

When it finishes, the last lines show:

```
Worst negative slack @100 MHz: <WNS> ns
XSA written to .../vivado/gps_acq.xsa
```

## 4. Read the results for the report

| File | What to take |
|---|---|
| `vivado/reports/timing_summary.txt` | **WNS** (worst negative slack). WNS ≥ 0 → 100 MHz is met. Max clock ≈ 1000 / (10 − WNS) MHz |
| `vivado/reports/utilization.txt` | Slice LUTs, Slice Registers, Block RAM Tile, DSPs |
| `vivado/reports/utilization_hier.txt` | the same numbers for the `acq` cell alone (the core without PS/DMA) |

These two report files go into Table 6 of the report ("LUTs / FFs / max clock" and the
measured DSP / BRAM).

To look at the design in the GUI: `vivado vivado/build/gps_acq.xpr`.

## 5. (Optional) Simulate in Vivado's simulator

The same self-checking testbench runs in xsim. Run these from the `hw` folder:

```bash
cd hw
xvlog -sv rtl/sdf_stage.sv rtl/fft_sdf.sv rtl/acq_core.sv rtl/gps_acq_axi.sv tb/tb_gps_acq.sv
xelab tb_gps_acq -s tb_sim
xsim tb_sim -R -testplusarg "VEC=sim/vectors/directed" -testplusarg "CSV=sim/results_xsim.csv"
```

Expected ending: `bit-exact vs model : 8 / 8` and `TB_GPS_ACQ PASS`.

## 6. (Optional) Run on the board: PS–PL hardware-in-the-loop test

1. Set the board's boot jumpers to **JTAG**. Connect the USB-JTAG/UART cable and power it on.
2. Start **Vitis 2023.1** (classic IDE) and choose a new, empty workspace folder.
3. *File → New → Platform Project* → *Create from hardware specification* → select
   `vivado/gps_acq.xsa`, OS **standalone**, processor **ps7_cortexa9_0** → Finish →
   build the platform (hammer icon).
4. *File → New → Application Project* → select that platform → template
   **Empty Application (C)**.
5. Copy `sw/gps_acq.c`, `sw/gps_acq.h`, `sw/main.c`, `sw/test_vectors.h` into the
   application's `src` folder and build.
6. Open a serial terminal (Vitis *Terminal* tab, PuTTY or Tera Term) on the board's COM port
   at **115200 baud**, 8N1.
7. Right-click the application → *Run As → Launch Hardware (Single Application Debug)*.

Expected UART output:

```
GPS L1 acquisition core - PS/PL test
T1 PRN  1: fd=  3000 Hz  tau= 512  P1/P2=50.27  det=1  cycles=15428  PASS
...
T8 PRN  3: fd= -5000 Hz  tau= 997  P1/P2=1.37  det=0  cycles=15428  PASS
HIL result: 8 / 8 PASS
cold start: ...
$PGACQ,...
```

The `cycles` value read back from the board is the measured hardware search time
(15 428 cycles = 0.154 ms at 100 MHz).

## Common problems

| Symptom | Fix |
|---|---|
| `no board files matching ...` warning | install the board files (step 1), or ignore if you only need the reports |
| `$readmemh` / file-not-found for `twiddle.hex` or `code_rom.hex` | run from the repository root and do not move `hw/mem/` |
| Path / "file name too long" errors on Windows | move the repository to `C:\work\gps` |
| `XPAR_AXIDMA_0_DEVICE_ID` undeclared in Vitis | you are using Vitis 2024.x (new flow); use 2023.1, or replace it with `XPAR_XAXIDMA_0_BASEADDR` |
| `acquisition core not found at 0x43c00000` | check the address of `acq` in the block design's *Address Editor* and set `ACQ_BASE` in `main.c` |
| WNS negative (timing fails) | send `timing_summary.txt`: the failing path shows which pipeline stage needs another register |
