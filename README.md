# FFT-Based Parallel Code Phase Acquisition Core for GPS L1

VL 423 – UAV Avionics and SoC-based Systems mini project (SVNIT Surat).
Aneesh Kadam (U23EC003), Samarth Kala (U23EC132). Supervisor: Dr. Suresh Dahiya.

The acquisition stage of an SoC (Zynq-7000, PS–PL) GPS L1 C/A receiver. A PL core
finds the Doppler (±5 kHz, 1 kHz bins) and the code phase of one satellite from 1 ms of
IF samples. The PS controls it over AXI4-Lite, loads samples over AXI DMA and reports
to the flight controller over UART.

## Layout

```
model/
  gps_acq_model.py     floating-point / algorithm reference (report figures, Monte Carlo)
  bit_true_model.py    integer model that matches the RTL bit for bit
  gen_vectors.py       ROM images, test vectors and sw/test_vectors.h
hw/
  rtl/sdf_stage.sv     radix-2 SDF DIF butterfly stage (generic FIFO length, twiddle, scaling)
  rtl/fft_sdf.sv       1024-point FFT: 10 stages in a generate loop
  rtl/acq_core.sv      capture buffer, fs/4 mixer + decimator, spectrum RAM, code ROM,
                       Doppler multiplier, |.|^2, peak / second-peak detector, control FSM
  rtl/gps_acq_axi.sv   top: AXI4-Lite registers + AXI4-Stream input + interrupt
  rtl/gps_acq_top.v    Verilog wrapper for the Vivado block design
  tb/tb_fft.sv         FFT unit test (impulse, tone, random, GNSS; back-to-back + gap)
  tb/tb_gps_acq.sv     system testbench: acts as the PS over AXI, self-checking
  mem/                 twiddle.hex (Q2.14), code_rom.hex (32 PRN x 1024 x 8+8 bit)
  syn/                 Yosys script + utilisation report
  Makefile
sw/
  gps_acq.[ch]         PS driver (register map, search loop, NMEA-style status)
  main.c               bare-metal app: AXI DMA hardware-in-the-loop test + 32-PRN cold start
  test_vectors.h       generated: T1–T8 samples and expected results
vivado/build.tcl       Zynq-7020 block design (PS7, AXI DMA, core, IRQ) -> bitstream + XSA
docs/                  project report (.docx / .pdf), acquisition flowchart (.drawio)
```

## Running

Needs Python 3 with numpy and matplotlib, Icarus Verilog 12 or newer, and Yosys
(`brew install icarus-verilog yosys`).

```bash
cd hw
make vectors     # regenerate ROMs, vectors, sw/test_vectors.h
make sim         # FFT unit test, T1–T8, interrupt mode, 24-case random regression
make syn         # Yosys synthesis for xc7 -> syn/utilization.txt
```

Board build (Vivado 2022.x or newer, board files installed). Step-by-step guide for a
Windows / Linux PC: [docs/RUN_ON_PC.md](docs/RUN_ON_PC.md). To have Claude Code do the run, paste
the prompt in [docs/VIVADO_RUN_PROMPT.md](docs/VIVADO_RUN_PROMPT.md).

```bash
vivado -mode batch -source vivado/build.tcl                    # PYNQ-Z2
vivado -mode batch -source vivado/build.tcl -tclargs zedboard  # ZedBoard
```

Then make a Vitis "Empty Application (C)" on `vivado/gps_acq.xsa` and add the files
from `sw/`. The core sits at `0x43C0_0000`.

## How it works

| Step | Hardware |
|---|---|
| Capture | 1024 x 12-bit buffer (4 x 3-bit samples per word) filled from AXI-Stream (`tlast` resets the pointer) |
| Mix + decimate | LO at fs/4 is (1, −j, −1, +j): I = v0 − v2, Q = v3 − v1, no multipliers; gain 64 |
| Forward FFT | 1024-point radix-2 SDF, 16-bit, ÷2 on even stages; written to spectrum RAM in natural order |
| Block exponent | e = bitlen(max\|Re\|,\|Im\|) − 6, so all 11 bins share one barrel shift |
| Doppler bin k | read X[(m+k) mod 1024] (address offset only) × conj FFT(code) from ROM, >> e, conj |
| Inverse FFTs | 11 transforms streamed back to back through the same FFT engine |
| Detection | \|y\|² peak tracker with a 2-bank row buffer, then a second-peak scan outside ±2 samples; P1·256 > P2·THRESH |

## Register map (AXI4-Lite)

| Offset | Name | Access | Description |
|---|---|---|---|
| 0x00 | CTRL | R/W | bit0 start, bit1 soft reset (both self-clearing), bit2 interrupt enable |
| 0x04 | STATUS | R | bit0 busy, bit1 done, bit2 detected |
| 0x08 | PRN | R/W | satellite to search, 1–32 |
| 0x0C | THRESH | R/W | threshold, Q8.8 (reset 0x0200 = 2.0) |
| 0x10 | DOPPLER | R | Doppler bin k, signed, 1 kHz units |
| 0x14 | CODE_PHASE | R | 0–1023 samples |
| 0x18 / 0x1C | PEAK / SECOND | R | peak and second-peak power |
| 0x20 | CYCLES | R | clock cycles of the last search |
| 0x24 | EXPONENT | R | block exponent (debug, added) |
| 0x28 | ID | R | 0x47505331 "GPS1" (added) |

## Results

### RTL simulation (Icarus Verilog, 100 MHz clock)

| ID | Case | f_d (Hz) | τ (chips) | RTL f̂_d (Hz) | RTL τ̂ (chips) | RTL ratio | Model match | Result |
|---|---|---|---|---|---|---|---|---|
| T1 | Strong signal (60 dB-Hz) | 3000 | 512.0 | 3000 | 511.5 | 50.27 | bit-exact | Pass |
| T2 | Negative Doppler | −4000 | 87.3 | −4000 | 86.9 | 9.19 | bit-exact | Pass |
| T3 | Zero Doppler | 0 | 1000.5 | 0 | 1000.0 | 10.16 | bit-exact | Pass |
| T4 | Upper band edge | 5000 | 201.7 | 5000 | 201.8 | 4.58 | bit-exact | Pass |
| T5 | Lower band edge | −5000 | 15.0 | −5000 | 15.0 | 12.34 | bit-exact | Pass |
| T6 | Doppler between bins | −2400 | 640.2 | −2000 | 639.4 | 2.03 | bit-exact | Pass |
| T7 | UAV motion (+260 Hz) | 1260 | 333.3 | 1000 | 332.7 | 6.50 | bit-exact | Pass |
| T8 | Noise only | – | – | – | – | 1.37 | bit-exact | Pass |

* FFT unit test: 5120 output samples bit-exact; latency 1053 cycles.
* Interrupt mode: T1–T8 pass.
* Random regression, 24 cases (46–58 dB-Hz, 15 % noise-only): RTL is bit-exact with
  the model in 24/24 cases and meets the truth criteria in 22/24. The 2 misses are
  algorithm limits that the model reproduces exactly: a Doppler exactly between two bins,
  and a 46.9 dB-Hz signal below the 50 dB-Hz needed for reliable 1 ms detection
  (report §7).

### Timing and resources

Vivado 2024.2, xc7z020clg400-1, 100 MHz `FCLK_CLK0` (full results in
[docs/vivado_results/](docs/vivado_results/)):

| Metric | Report estimate | Measured (acquisition core only) |
|---|---|---|
| Cycles / time per PRN | 26 200 / 0.26 ms | **15 428 / 0.154 ms** (RTL sim; inverse FFTs streamed back to back) |
| All 32 PRNs | 8.4 ms | 4.9 ms |
| Timing at 100 MHz | – | **met**, WNS +0.200 ns (≈102 MHz max); worst path: code ROM BRAM → DSP |
| DSP slices | ≈42 | 48 (21.8 %): 40 FFT, 4 Doppler multiplier, 2 magnitude, 2 threshold compare |
| Block RAM | spectrum 32 kb, FIFOs 32 kb, ROM 512 kb | 21 tiles (15.0 %): 18 RAMB36 + 6 RAMB18 |
| LUTs | – | 4 135 (7.8 %), of which 900 LUTRAM/SRL |
| Flip-flops | – | 1 359 (1.3 %) |

Whole design including PS glue, AXI DMA and interconnect: 5 305 LUTs (10.0 %), 3 030 FFs,
22 BRAM tiles, 48 DSPs. The same xsim testbench passes bit-exact in Vivado (8/8 directed,
24/24 regression).

Differences from the report's architecture: the FFT uses its complex multiplier for the
sum path too (W = 1), so all paths share one rounding. This costs a few DSPs, and the
last stage could drop its multiplier. The THRESH register is defined as Q8.8.

## Not yet done

* The on-board hardware-in-the-loop run (`sw/`). The Vivado build above was made without
  board files, so its bitstream will not boot on a board: rebuild with the PYNQ-Z2 or
  ZedBoard board files installed first (see [docs/RUN_ON_PC.md](docs/RUN_ON_PC.md)).
* Tracking loops, non-coherent integration, a 2048-point FFT and radix-2² stages
  (report: future work).
