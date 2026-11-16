# Vivado results: GPS L1 acquisition core

Results for commit **`2a25a94`** ("Meet 100 MHz timing, force block RAM, merge Vivado 2024.2
build fixes"), 2026-11-16. They follow `docs/VIVADO_RUN_PROMPT.md`. The bitstream build ran
14:20–14:34 (`vivado_run2.log`), and the xsim runs were repeated afterwards on the same RTL.

**Summary:** both simulations pass bit-exact. The bitstream and XSA were built with
**100 MHz timing met** (WNS = +0.200 ns, estimated max clock ≈ 102 MHz). Moving the code ROM
into block RAM cut the design from 14110 to 5305 LUTs. No errors or critical warnings in
the build log. Nothing was changed in this run: the two Vivado 2024.2 `build.tcl` fixes from
the first run are already in `2a25a94`.

## Setup

| Item | Value |
|---|---|
| Vivado | **2024.2** (SW Build 5239630) |
| OS | Windows 11 Home 10.0.26200 |
| Part | xc7z020clg400-1 (PYNQ-Z2 default) |
| Board files | **Not used.** Neither PYNQ-Z2 nor ZedBoard board files are installed, so the PS7 uses Vivado defaults. Timing and utilisation are valid, but this bitstream / XSA will not boot on the board. |

## xsim simulation (from `hw/`)

| Run | Bit-exact vs model | Truth checks | Max cycles / PRN | Result |
|---|---|---|---|---|
| `VEC=sim/vectors/directed` | **8 / 8** | 8 / 8 | 15428 (0.154 ms @ 100 MHz) | `TB_GPS_ACQ PASS` |
| `VEC=sim/vectors/regress` + `TRUTH_STAT` | **24 / 24** | 22 / 24 | 15428 | `TB_GPS_ACQ PASS` |

The two regression truth misses are case 14 (PRN 2, k = −4 kHz, τ = 881) and case 19 (PRN 25,
k = +3 kHz, τ = 90, det = 0, P1/P2 = 1.52). The hardware matches the model bit-for-bit on both,
so they come from the algorithm, not from the RTL. The per-case lines now print correctly in xsim.

## Timing (`vivado/reports/timing_summary.txt`, clk_fpga_0 = 100 MHz)

| Metric | Value |
|---|---|
| WNS (setup) | **+0.200 ns** |
| TNS | 0.000 ns (0 failing endpoints of 16603) |
| WHS (hold) | 0.024 ns (met) |
| WPWS | 3.750 ns (met) |
| 100 MHz met? | **Yes** |
| Estimated max clock | 1000 / (10 − 0.200) = 1000 / 9.8 ≈ **102 MHz** |

**Worst setup path**

| | |
|---|---|
| Start point | `system_i/acq/inst/u_acq/u_core/rom_q_reg_0_2/CLKARDCLK` (code ROM block RAM) |
| End point | `system_i/acq/inst/u_acq/u_core/pi_reg/PCIN[0]` (DSP48E1 cascade input) |
| Data path delay | 8.065 ns (logic 6.305 ns / 78 %, route 1.760 ns / 22 %) |
| Logic levels | **1** (DSP48E1 = 1) |

The previous worst path (`exponent_reg` → `bn_im_reg`, 16 logic levels, −0.362 ns) is gone.
The limit is now the BRAM clock-to-out plus a DSP, which is close to the device limit for this path.

## Utilisation (`vivado/reports/utilization.txt`, xc7z020: 53200 LUT / 106400 FF / 140 BRAM / 220 DSP)

| Resource | Whole design | `acq` cell only (`utilization_hier.txt`) | Previous run, whole design |
|---|---|---|---|
| Slice LUTs | 5305 (9.97 %) | 4135 (7.77 %) | 14110 (26.52 %) |
| LUT as Memory | 1016 (5.84 %) | 900 (5.17 %): 800 LUTRAM + 100 SRL | 1014 |
| Slice Registers | 3030 (2.85 %) | 1359 (1.28 %) | 3328 |
| Block RAM Tiles | 22 (15.71 %) | 21 (15.0 %): 18 × RAMB36 + 6 × RAMB18 | 6 |
| DSPs | 48 (21.82 %) | 48 (21.82 %) | 48 |

The DMA uses 444 LUTs, 668 FFs and 1 RAMB36. The rest is AXI interconnect and reset logic.

Note: the README lists the measured block RAM as "3 RAMB36 + 43 RAMB18 (≈24.5 RAMB36)".
This build has 21 tiles in `acq` (18 RAMB36 + 6 RAMB18), so Vivado packed the ROM into RAMB36s.
The README figure may need updating.

## Address map (checked in the block design)

| Segment | Base |
|---|---|
| `SEG_acq_reg0` | 0x43C0_0000 (64K), matches `ACQ_BASE` in `sw/main.c` |
| `SEG_dma_Reg` | 0x4040_0000 |
| `SEG_ps7_HP0_DDR_LOWOCM` | 0x0000_0000 (DMA view of DDR) |

## Changes made to `vivado/build.tcl`

None in this run. These two fixes were made in the first run (on commit `b9e57b7`) so the
build would go through on Vivado 2024.2. Both are already merged in `2a25a94`, which also
adds a comment line above the second fix. Diff against `b9e57b7`:

```diff
@@ -76,10 +76,12 @@ apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
     -config {Master "/ps7/M_AXI_GP0" Clk "Auto"} [get_bd_intf_pins dma/S_AXI_LITE]
 # DMA reads DDR through HP0
 apply_bd_automation -rule xilinx.com:bd_rule:axi4 \
-    -config {Slave "/ps7/S_AXI_HP0" Clk "Auto"} [get_bd_intf_pins dma/M_AXI_MM2S]
+    -config {Master "/dma/M_AXI_MM2S" Clk "Auto"} [get_bd_intf_pins ps7/S_AXI_HP0]
 # sample stream
 connect_bd_intf_net [get_bd_intf_pins dma/M_AXIS_MM2S] [get_bd_intf_pins acq/s_axis]
-connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dma/m_axi_mm2s_aclk]
+if {[llength [get_bd_nets -quiet -of_objects [get_bd_pins dma/m_axi_mm2s_aclk]]] == 0} {
+    connect_bd_net [get_bd_pins ps7/FCLK_CLK0] [get_bd_pins dma/m_axi_mm2s_aclk]
+}
```

1. **HP0 automation (line 78).** Vivado 2024.2 rejected the original form with
   `[xilinx.com:ip:axi_dma:7.1-1] /dma No valid slave interface could be found to connect to </dma/M_AXI_MM2S>`.
   The axi4 rule has to run on the slave pin (`ps7/S_AXI_HP0`) with the DMA named as `Master`.
2. **DMA clock (line 82).** In 2024.2 the HP0 automation already connects `dma/m_axi_mm2s_aclk`
   to `FCLK_CLK0`, so the explicit `connect_bd_net` failed with
   `[BD 5-4] Error: running connect_bd_net` ("all ports/pins are already connected").
   It now runs only if the pin has no net yet.

## Output files

- `vivado/reports/timing_summary.txt`, `utilization.txt`, `utilization_hier.txt`
- `vivado/gps_acq.xsa` (bitstream included; built without board files)
- `vivado/system_wrapper.bit` (bitstream on its own, from `vivado/build/gps_acq.runs/impl_1/`)
- `vivado_run2.log` (full Vivado batch log of this build)
- `vivado_run2.jou` (Vivado journal of this build: session header and the `source vivado/build.tcl` command)
- `xsim.log` (full xvlog / xelab / xsim console output for both simulation runs)
- `xsim_results.txt` (just the per-case and summary lines from `xsim.log`)
