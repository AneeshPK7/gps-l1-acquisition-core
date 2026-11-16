"""
Bit-true model of the RTL acquisition core (hw/rtl).

Every integer operation here is exactly what the SystemVerilog does, so the RTL
testbenches can demand a bit-for-bit match (spectrum, correlation peak, second peak,
Doppler bin and code phase). `gps_acq_model.py` remains the floating-point /
algorithm-level reference used for the report figures.

RTL arithmetic summary
----------------------
* IF sample codes: 3-bit two's complement c in [-4, 3], value v = 2c + 1 (+-1 .. +-7).
* fs/4 mixer + sum-of-4 decimator:  I = v0 - v2,  Q = v3 - v1,  then << 6 (gain 64).
* Radix-2 SDF DIF FFT, 10 stages, 16-bit data, Q2.14 twiddles.
    stage s, block size 2L (L = 512 >> s), sh = 1 on even stages (total 1/32):
      out[j]   = sat16( (  (top+bot) * 2^14       + 2^(13+sh)) >> (14+sh) )
      out[j+L] = sat16( ( (top-bot) * W[j << s]   + 2^(13+sh)) >> (14+sh) )   (complex)
  Output leaves in bit-reversed order: time slot j carries bin bitrev(j).
* Block exponent: e = max(0, bitlen(max |Re X|, |Im X|) - 6).
* Doppler bin k: P[m] = X[(m+k) mod N] * C[m]   (C = conj FFT(code), 8-bit ROM)
                 P'   = sat16(round_half_up(P >> e)),  IFFT input = conj(P').
* Power |y|^2 = yr^2 + yi^2 (unsigned 32 bit).
* Peak: strict '>' in output time order (bins k = -5..5, slot j = 0..1023).
* Second peak: max over the best row excluding |tau' - tau| <= 2 (circular).
* Detect: P1 * 256 > P2 * THRESH (THRESH in Q8.8, default 0x200 = 2.0).
"""
import numpy as np

N = 1024
STAGES = 10
DW = 16
TWF = 14                      # twiddle fractional bits
SCALE = [s % 2 == 0 for s in range(STAGES)]
DOPPLER_BINS = np.arange(-5, 6)
EXCLUDE = 2
THRESH_DEFAULT = 0x200        # 2.0 in Q8.8
FE_GAIN_SHIFT = 6

_LIM_LO, _LIM_HI = -(1 << (DW - 1)), (1 << (DW - 1)) - 1


def sat(v, lo=_LIM_LO, hi=_LIM_HI):
    return np.clip(v, lo, hi)


def bitrev(n, bits=10):
    return int(f"{n:0{bits}b}"[::-1], 2)


BITREV = np.array([bitrev(i) for i in range(N)])


# ---------------------------------------------------------------- tables (ROM contents)
def twiddle_table():
    """W[n] = exp(-j 2 pi n / N), n = 0..N/2-1, Q2.14, as (re, im) int arrays."""
    n = np.arange(N // 2)
    wr = np.round(np.cos(2 * np.pi * n / N) * (1 << TWF)).astype(np.int64)
    wi = np.round(-np.sin(2 * np.pi * n / N) * (1 << TWF)).astype(np.int64)
    return wr, wi


TW_RE, TW_IM = twiddle_table()


def code_rom_entry(prn):
    """8-bit conj(FFT(code)) for one PRN, same normalisation as gps_acq_model."""
    from gps_acq_model import code_ref_fft
    c = code_ref_fft(prn)
    c = c / np.abs(c).max() * 127
    return np.round(c.real).astype(np.int64), np.round(c.imag).astype(np.int64)


_ROM = {}


def code_rom(prn):
    if prn not in _ROM:
        _ROM[prn] = code_rom_entry(prn)
    return _ROM[prn]


# ---------------------------------------------------------------- datapath blocks
def if_to_codes(x_if):
    """gps_acq_model.make_if output (odd integers) -> 3-bit ADC codes."""
    c = ((np.asarray(x_if) - 1) // 2).astype(np.int64)
    assert c.min() >= -4 and c.max() <= 3
    return c


def front_end(codes):
    v = 2 * np.asarray(codes, dtype=np.int64).reshape(N, 4) + 1
    i = (v[:, 0] - v[:, 2]) << FE_GAIN_SHIFT
    q = (v[:, 3] - v[:, 1]) << FE_GAIN_SHIFT
    return i, q


def fft_sdf(xr, xi):
    """Bit-true SDF DIF FFT. Returns output in *time order* (bit-reversed bins)."""
    ar = np.asarray(xr, dtype=np.int64).copy()
    ai = np.asarray(xi, dtype=np.int64).copy()
    for s in range(STAGES):
        L = N >> (s + 1)
        sh = TWF + (1 if SCALE[s] else 0)
        rnd = 1 << (sh - 1)
        ar = ar.reshape(-1, 2 * L)
        ai = ai.reshape(-1, 2 * L)
        tr, ti, br, bi = ar[:, :L], ai[:, :L], ar[:, L:], ai[:, L:]
        sr = sat(((tr + br) * (1 << TWF) + rnd) >> sh)
        si = sat(((ti + bi) * (1 << TWF) + rnd) >> sh)
        dr, di = tr - br, ti - bi
        idx = np.arange(L) << s
        wr, wi = TW_RE[idx], TW_IM[idx]
        pr = sat((dr * wr - di * wi + rnd) >> sh)
        pi = sat((dr * wi + di * wr + rnd) >> sh)
        ar = np.hstack([sr, pr]).reshape(-1)
        ai = np.hstack([si, pi]).reshape(-1)
    return ar, ai


def fft_natural(xr, xi):
    yr, yi = fft_sdf(xr, xi)
    out_r = np.empty(N, dtype=np.int64)
    out_i = np.empty(N, dtype=np.int64)
    out_r[BITREV] = yr
    out_i[BITREV] = yi
    return out_r, out_i


def block_exponent(xr, xi):
    m = int(max(np.abs(xr).max(), np.abs(xi).max()))
    return max(0, m.bit_length() - 6)


def round_shift(v, e):
    if e == 0:
        return v
    return (v + (1 << (e - 1))) >> e


# ---------------------------------------------------------------- acquisition
def acquire(codes, prn, thresh=THRESH_DEFAULT, return_surface=False):
    """Run the full bit-true acquisition on 4096 ADC codes for one PRN."""
    xr, xi = fft_natural(*front_end(codes))
    e = block_exponent(xr, xi)
    cr, ci = code_rom(prn)
    rows_time = np.zeros((len(DOPPLER_BINS), N), dtype=np.int64)   # power, time order
    surf = np.zeros((len(DOPPLER_BINS), N), dtype=np.int64)        # power, by tau
    for r, k in enumerate(DOPPLER_BINS):
        sr = np.roll(xr, -k)
        si = np.roll(xi, -k)
        pr = sat(round_shift(sr * cr - si * ci, e))
        pi = sat(round_shift(sr * ci + si * cr, e))
        yr, yi = fft_sdf(pr, sat(-pi))
        p = yr * yr + yi * yi
        rows_time[r] = p
        surf[r, BITREV] = p
    flat = int(np.argmax(rows_time))           # first maximum in time order
    r_pk, j_pk = divmod(flat, N)
    tau = int(BITREV[j_pk])
    peak = int(rows_time[r_pk, j_pk])
    row = surf[r_pk].copy()
    d = (np.arange(N) - tau) % N
    row[(d <= EXCLUDE) | (d >= N - EXCLUDE)] = 0
    second = int(row.max())
    detected = peak * 256 > second * thresh
    res = dict(k=int(DOPPLER_BINS[r_pk]), doppler_hz=float(DOPPLER_BINS[r_pk] * 1000),
               tau=tau, code_phase_chips=tau * 1.023e6 / 1.024e6,
               peak=peak, second=second,
               ratio=peak / second if second else float("inf"),
               detected=bool(detected), exponent=e)
    if return_surface:
        return res, surf
    return res
