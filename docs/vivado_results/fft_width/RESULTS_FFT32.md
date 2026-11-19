# Vivado results: 16-bit vs 32-bit FFT engine

Run on 2026-11-20 at commit `0f5af5b`, following `docs/VIVADO_FFT32_PROMPT.md`.
Only the 1024-point SDF FFT engine (`hw/rtl/sdf_stage.sv`, `hw/rtl/fft_sdf.sv`) is built,
out of context, with a 100 MHz clock (`vivado/fft_width.tcl`).

**Summary:** both widths simulate bit-exact (1053-cycle latency, 5120 samples). The 16-bit
FFT meets 100 MHz with +2.198 ns of slack (≈128 MHz). The 32-bit FFT **does not meet
100 MHz** (WNS −1.141 ns, ≈90 MHz) and uses 3.1× the LUTs and 4× the DSPs (160 of 220,
73 % of the device). No changes were made to `vivado/fft_width.tcl`, the RTL, the testbench
or the vectors. The build log has no errors and no critical warnings.

## Setup

| Item | Value |
|---|---|
| Vivado | 2024.2 (SW Build 5239630) |
| OS | Windows 11 Home 10.0.26200 |
| Part | xc7z020clg400-1 |
| Build | out of context (`synth_design -mode out_of_context`), opt → place → phys_opt → route |

## xsim (from `hw/`)

| Width | Latency | Result |
|---|---|---|
| 16-bit (`xelab tb_fft -s fft16`) | `FFT latency: 1053 cycles` | `TB_FFT PASS: 5120 samples bit-exact` |
| 32-bit (`xvlog -d FFT_DW=32`, `-s fft32`) | `FFT latency: 1053 cycles` | `TB_FFT PASS: 5120 samples bit-exact` |

The 32-bit compile used `mem/twiddle32.hex` and `sim/vectors/fft32`, which I confirmed in the
xelab output. On Windows cmd the define has to be quoted, `-d "FFT_DW=32"`. Unquoted, cmd splits
it at `=` and xvlog fails with `Can not find file: 32`. The command in the prompt needs that quote
when run from a `.bat` file.

## Utilisation and timing (`vivado/fft_width/dw<W>/utilization.txt`, `timing_summary.txt`)

xc7z020: 53200 LUTs, 17400 LUTRAM-capable, 106400 registers, 140 BRAM tiles (280 RAMB18), 220 DSPs.

| | 16-bit | 32-bit | 32 / 16 |
|---|---|---|---|
| Slice LUTs | 2641 (4.96 %) | 8108 (15.24 %) | 3.07× |
| LUT as Logic | 2447 (4.60 %) | 7878 (14.81 %) | 3.22× |
| LUT as Memory | 194 (1.11 %) | 230 (1.32 %) | 1.19× |
| Slice Registers | 957 (0.90 %) | 2205 (2.07 %) | 2.30× |
| Block RAM Tiles | 2.5 (1.79 %): 0 × RAMB36 + 5 × RAMB18 | 6 (4.29 %): 6 × RAMB36 + 0 × RAMB18 | 2.4× |
| DSPs | 40 (18.18 %) | 160 (72.73 %) | 4.00× |
| WNS (setup) | +2.198 ns | **−1.141 ns** | |
| TNS | 0.000 ns | −142.472 ns | |
| WHS (hold) | +0.122 ns | +0.127 ns | |
| Failing endpoints (setup) | 0 of 4946 | **424 of 9416** | |
| Timing met at 100 MHz | **Yes** | **No** | |
| Estimated max clock = 1000 / (10 − WNS) | 1000 / 7.802 ≈ **128.2 MHz** | 1000 / 11.141 ≈ **89.8 MHz** | |

Hold is met for both widths, with 0 failing hold endpoints.

## Worst setup path

| | 16-bit | 32-bit |
|---|---|---|
| Start point | `g_stage[6].u_stage/p_re_reg/CLK` | `g_stage[3].u_stage/p_im1__1/CLK` |
| End point | `g_stage[6].u_stage/out_re_reg[11]/S` | `g_stage[3].u_stage/p_im_reg[65]/D` |
| Data path delay | 7.008 ns (logic 2.932 ns / 42 %, route 4.076 ns / 58 %) | 11.119 ns (logic 8.927 ns / 80 %, route 2.192 ns / 20 %) |
| Logic levels | 8 (CARRY4 = 8) | 16 (CARRY4 = 13, DSP48E1 = 1, LUT2 = 2) |

In the 32-bit build the twiddle multiply (`p_im`, 66 bits wide) no longer fits in one DSP48E1
(25 × 18). Vivado splits it across cascaded DSPs plus a 13-deep carry chain, so the complex
multiply in each butterfly stage becomes the critical path. The 16-bit build's worst path is
the rounding / saturation carry chain after the multiplier.

## Changes made to `vivado/fft_width.tcl`

None. The script ran unchanged on Vivado 2024.2. The `TW_FILE` generic was passed as the full
path of the `.hex` file.

## Files

- `RESULTS_FFT32.md` (this file)
- `vivado/fft_width/dw16/`, `vivado/fft_width/dw32/`: `utilization.txt`, `utilization_hier.txt`,
  `utilization_synth.txt`, `timing_summary.txt`, `timing_paths.txt`, `summary.txt`, `clock.xdc`
- `xsim_fft16_fft32.log`: xvlog / xelab / xsim output for both widths (the 16-bit run, the
  failed unquoted 32-bit compile, and the 32-bit re-run)
- `vivado_fft_width.log`, `vivado_fft_width.jou`: Vivado batch log and journal of the build
