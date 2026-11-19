"""
16-bit vs 32-bit baseband datapath comparison.

`acquire_w(codes, prn, fmt)` is the bit-true acquisition of bit_true_model.py with the
baseband word length as a parameter:

  format  FFT data  twiddles  code ROM  front-end gain  block-exponent target
  16-bit  16 bit    Q2.14     8+8 bit   << 6            |X| < 2^6
  32-bit  32 bit    Q2.30     16+16 bit << 22           |X| < 2^14

The 16-bit format is checked to be bit-exact with bit_true_model.acquire (the RTL)
before anything else runs. The 32-bit format keeps the same algorithm, scaling
schedule (/2 on even stages) and headroom, so the only difference is word length.

Running this file writes model/width_results.json and docs/figures/width_*.png/pdf.
"""
import json
import os
import sys
import time

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

sys.path.insert(0, os.path.dirname(__file__))
import bit_true_model as bt          # noqa: E402
import gps_acq_model as gm           # noqa: E402

N = 1024
STAGES = 10
SCALE = [s % 2 == 0 for s in range(STAGES)]
DOPPLER_BINS = np.arange(-5, 6)
EXCLUDE = 2
THRESH = 0x200
BITREV = bt.BITREV

OUT_FIG = os.path.join(os.path.dirname(__file__), "..", "docs", "figures")
OUT_DATA = os.path.join(os.path.dirname(__file__), "width_results.json")


class Fmt:
    def __init__(self, dw, rom_bits):
        self.dw = dw
        self.twf = dw - 2                       # Q2.(dw-2) twiddles
        self.rom_bits = rom_bits
        self.fe_shift = dw - 10                 # 3-bit samples sum to <= 14 -> fill the word
        self.exp_target = dw - rom_bits - 2     # same headroom rule as the RTL
        self.lo, self.hi = -(1 << (dw - 1)), (1 << (dw - 1)) - 1
        n = np.arange(N // 2)
        self.tw_re = np.round(np.cos(2 * np.pi * n / N) * (1 << self.twf)).astype(np.int64)
        self.tw_im = np.round(-np.sin(2 * np.pi * n / N) * (1 << self.twf)).astype(np.int64)
        self._rom = {}

    def sat(self, v):
        return np.clip(v, self.lo, self.hi)

    def rom(self, prn):
        if prn not in self._rom:
            c = gm.code_ref_fft(prn)
            c = c / np.abs(c).max() * ((1 << (self.rom_bits - 1)) - 1)
            self._rom[prn] = (np.round(c.real).astype(np.int64),
                              np.round(c.imag).astype(np.int64))
        return self._rom[prn]


F16 = Fmt(16, 8)
F32 = Fmt(32, 16)


def front_end(codes, f):
    v = 2 * np.asarray(codes, dtype=np.int64).reshape(N, 4) + 1
    return (v[:, 0] - v[:, 2]) << f.fe_shift, (v[:, 3] - v[:, 1]) << f.fe_shift


def fft_sdf(xr, xi, f):
    """Bit-true SDF DIF FFT, output in time (bit-reversed) order. int64 is enough for
    32-bit data: |d| < 2^32, |w| <= 2^30, so |d*w| < 2^62 and a complex MAC < 2^63."""
    ar = np.asarray(xr, dtype=np.int64).copy()
    ai = np.asarray(xi, dtype=np.int64).copy()
    for s in range(STAGES):
        L = N >> (s + 1)
        sh = f.twf + (1 if SCALE[s] else 0)
        rnd = 1 << (sh - 1)
        ar = ar.reshape(-1, 2 * L)
        ai = ai.reshape(-1, 2 * L)
        tr, ti, br, bi = ar[:, :L], ai[:, :L], ar[:, L:], ai[:, L:]
        sr = f.sat(((tr + br) * (1 << f.twf) + rnd) >> sh)
        si = f.sat(((ti + bi) * (1 << f.twf) + rnd) >> sh)
        dr, di = tr - br, ti - bi
        idx = np.arange(L) << s
        wr, wi = f.tw_re[idx], f.tw_im[idx]
        pr = f.sat((dr * wr - di * wi + rnd) >> sh)
        pi = f.sat((dr * wi + di * wr + rnd) >> sh)
        ar = np.hstack([sr, pr]).reshape(-1)
        ai = np.hstack([si, pi]).reshape(-1)
    return ar, ai


def fft_natural(xr, xi, f):
    yr, yi = fft_sdf(xr, xi, f)
    out_r = np.empty(N, dtype=np.int64)
    out_i = np.empty(N, dtype=np.int64)
    out_r[BITREV] = yr
    out_i[BITREV] = yi
    return out_r, out_i


def acquire_w(codes, prn, f, thresh=THRESH, return_surface=False):
    xr, xi = fft_natural(*front_end(codes, f), f)
    m = int(max(np.abs(xr).max(), np.abs(xi).max()))
    e = max(0, m.bit_length() - f.exp_target)
    cr, ci = f.rom(prn)
    exact = f.dw <= 16                      # 32-bit |y|^2 needs 64 bits: use float
    rows_time = np.zeros((len(DOPPLER_BINS), N), dtype=np.int64 if exact else float)
    surf = np.zeros_like(rows_time)
    for r, k in enumerate(DOPPLER_BINS):
        sr, si = np.roll(xr, -k), np.roll(xi, -k)
        pr = f.sat(bt.round_shift(sr * cr - si * ci, e))
        pi = f.sat(bt.round_shift(sr * ci + si * cr, e))
        yr, yi = fft_sdf(pr, f.sat(-pi), f)
        if exact:
            p = yr * yr + yi * yi
        else:
            p = yr.astype(float) ** 2 + yi.astype(float) ** 2
        rows_time[r] = p
        surf[r, BITREV] = p
    flat = int(np.argmax(rows_time))
    r_pk, j_pk = divmod(flat, N)
    tau = int(BITREV[j_pk])
    peak = rows_time[r_pk, j_pk]
    row = surf[r_pk].copy()
    d = (np.arange(N) - tau) % N
    row[(d <= EXCLUDE) | (d >= N - EXCLUDE)] = 0
    second = row.max()
    res = dict(k=int(DOPPLER_BINS[r_pk]), doppler_hz=float(DOPPLER_BINS[r_pk] * 1000),
               tau=tau, code_phase_samples=tau,
               code_phase_chips=tau * 1.023e6 / 1.024e6,
               peak=int(peak) if exact else float(peak),
               second=int(second) if exact else float(second),
               ratio=float(peak) / float(second) if second else float("inf"),
               detected=bool(peak * 256 > second * thresh), exponent=e)
    if return_surface:
        return res, surf
    return res


# ---------------------------------------------------------------- helpers
def snr_db(ref, y):
    ref = np.asarray(ref, dtype=complex)
    y = np.asarray(y, dtype=complex)
    a = np.vdot(ref, y) / np.vdot(ref, ref)          # best gain match
    return float(10 * np.log10(np.sum(np.abs(ref) ** 2) / np.sum(np.abs(y / a - ref) ** 2)))


def float_surface(codes, prn):
    v = 2 * np.asarray(codes, dtype=float).reshape(N, 4) + 1
    bb = (v[:, 0] - v[:, 2]) + 1j * (v[:, 3] - v[:, 1])
    X = np.fft.fft(bb)
    c = gm.code_ref_fft(prn)
    return np.array([np.abs(np.fft.ifft(np.roll(X, -k) * c)) ** 2 for k in DOPPLER_BINS])


def style():
    plt.rcParams.update({"font.family": "serif", "mathtext.fontset": "cm",
                         "font.size": 10, "axes.grid": True, "grid.alpha": 0.3,
                         "figure.dpi": 150, "savefig.bbox": "tight"})


def main():
    os.makedirs(OUT_FIG, exist_ok=True)
    style()
    out = {}

    # --- 0. the 16-bit path of this file is the RTL path ------------------------
    rng = np.random.default_rng(7)
    for _ in range(20):
        prn = int(rng.integers(1, 33))
        x = gm.make_if(prn, rng.uniform(-5000, 5000), rng.uniform(0, 1023),
                       rng.uniform(42, 58), rng)
        c = bt.if_to_codes(x)
        a, b = bt.acquire(c, prn), acquire_w(c, prn, F16)
        assert all(a[key] == b[key] for key in ("k", "tau", "peak", "second", "detected")), (a, b)
    out["check_16bit_equals_rtl_model"] = "20/20 bit-exact"
    print("16-bit generic model == bit_true_model (RTL): 20/20")

    # --- 1. FFT and correlation accuracy vs floating point ----------------------
    rng = np.random.default_rng(11)
    fft_sq = {16: [], 32: []}
    corr_sq = {16: [], 32: []}
    ratio_err = {16: [], 32: []}
    for _ in range(40):
        prn = int(rng.integers(1, 33))
        x = gm.make_if(prn, rng.uniform(-5000, 5000), rng.uniform(0, 1023), 50, rng)
        c = bt.if_to_codes(x)
        v = 2 * c.reshape(N, 4) + 1
        bb = (v[:, 0] - v[:, 2]) + 1j * (v[:, 3] - v[:, 1])
        Xf = np.fft.fft(bb)
        sf = float_surface(c, prn)
        r_pk, tau = np.unravel_index(np.argmax(sf), sf.shape)
        d = (np.arange(N) - tau) % N
        rf = sf.max() / np.where((d <= EXCLUDE) | (d >= N - EXCLUDE), 0, sf[r_pk]).max()
        for w, f in ((16, F16), (32, F32)):
            xr, xi = fft_natural(*front_end(c, f), f)
            fft_sq[w].append(snr_db(Xf, xr + 1j * xi))
            r, s = acquire_w(c, prn, f, return_surface=True)
            corr_sq[w].append(snr_db(sf.ravel(), s.astype(float).ravel()))
            ratio_err[w].append(abs(r["ratio"] - rf) / rf * 100)
    out["accuracy"] = {
        str(w): dict(fft_sqnr_db=float(np.mean(fft_sq[w])),
                     corr_sqnr_db=float(np.mean(corr_sq[w])),
                     ratio_err_pct_mean=float(np.mean(ratio_err[w])),
                     ratio_err_pct_max=float(np.max(ratio_err[w])))
        for w in (16, 32)}
    print(json.dumps(out["accuracy"], indent=2))

    # --- 2. Detection: Pd vs C/N0 and Pfa, same signals for every format -------
    rng = np.random.default_rng(2026)
    cn0s = np.arange(38, 57, 2)
    trials = 300
    pd = {"float": [], "16": [], "32": []}
    agree = same_ratio = 0
    total = 0
    t16 = t32 = 0.0
    for cn0 in cn0s:
        hits = {"float": 0, "16": 0, "32": 0}
        for _ in range(trials):
            prn = int(rng.integers(1, 33))
            fd = rng.uniform(-5000, 5000)
            cp = rng.uniform(0, 1023)
            x = gm.make_if(prn, fd, cp, cn0, rng)
            c = bt.if_to_codes(x)
            hits["float"] += gm.check(gm.acquire(x, prn), fd, cp)[0]
            t = time.perf_counter()
            r16 = acquire_w(c, prn, F16)
            t16 += time.perf_counter() - t
            t = time.perf_counter()
            r32 = acquire_w(c, prn, F32)
            t32 += time.perf_counter() - t
            hits["16"] += gm.check(r16, fd, cp)[0]
            hits["32"] += gm.check(r32, fd, cp)[0]
            total += 1
            agree += (r16["k"], r16["tau"], r16["detected"]) == (r32["k"], r32["tau"], r32["detected"])
        for key in pd:
            pd[key].append(hits[key] / trials)
        print(f"C/N0 {cn0}: " + "  ".join(f"{k}={pd[k][-1]:.3f}" for k in pd))
    out["pd"] = dict(cn0=cn0s.tolist(), trials=trials, **{f"pd_{k}": v for k, v in pd.items()})
    out["decision_agreement_16_32"] = dict(same=agree, total=total)

    fa_trials = 1000
    fa = {16: 0, 32: 0}
    ratios = {16: [], 32: []}
    for _ in range(fa_trials):
        x = gm.make_if(1, 0, 0, 45, rng, present=False)
        c = bt.if_to_codes(x)
        for w, f in ((16, F16), (32, F32)):
            r = acquire_w(c, 1, f)
            fa[w] += r["detected"]
            ratios[w].append(r["ratio"])
    out["pfa"] = {str(w): dict(pfa=fa[w] / fa_trials, trials=fa_trials,
                               ratio_p99=float(np.percentile(ratios[w], 99))) for w in (16, 32)}
    print(out["pfa"])

    def interp(p, target):
        p = np.asarray(p)
        i = int(np.argmax(p >= target))
        if i == 0:
            return float(cn0s[0])
        return float(cn0s[i - 1] + (target - p[i - 1]) / (p[i] - p[i - 1]) * 2)
    out["cn0_at_pd"] = {k: dict(pd50=interp(pd[k], 0.5), pd90=interp(pd[k], 0.9)) for k in pd}
    print(out["cn0_at_pd"])

    # --- figures -----------------------------------------------------------------
    fig, ax = plt.subplots(figsize=(4.6, 2.8))
    ax.plot(cn0s, pd["float"], "o-", ms=4, label="Floating point")
    ax.plot(cn0s, pd["16"], "s--", ms=4, label="16-bit baseband (this design)")
    ax.plot(cn0s, pd["32"], "^:", ms=4, label="32-bit baseband")
    ax.legend(fontsize=8)
    ax.set_xlabel("$C/N_0$ (dB-Hz)")
    ax.set_ylabel("Probability of detection")
    ax.set_ylim(-0.02, 1.02)
    ax.set_title(f"16-bit vs 32-bit baseband, {trials} trials/point", fontsize=9)
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(OUT_FIG, f"width_pd.{ext}"))
    plt.close(fig)

    fig, ax = plt.subplots(figsize=(4.6, 2.6))
    labels = ["Forward FFT", "Correlation surface"]
    xs = np.arange(2)
    v16 = [out["accuracy"]["16"]["fft_sqnr_db"], out["accuracy"]["16"]["corr_sqnr_db"]]
    v32 = [out["accuracy"]["32"]["fft_sqnr_db"], out["accuracy"]["32"]["corr_sqnr_db"]]
    b1 = ax.bar(xs - 0.18, v16, 0.36, label="16-bit")
    b2 = ax.bar(xs + 0.18, v32, 0.36, label="32-bit")
    ax.bar_label(b1, fmt="%.1f", fontsize=8)
    ax.bar_label(b2, fmt="%.1f", fontsize=8)
    ax.set_xticks(xs, labels)
    ax.set_ylabel("SQNR vs floating point (dB)")
    ax.set_ylim(0, max(v32) * 1.18)
    ax.legend(fontsize=8, loc="upper left")
    for ext in ("pdf", "png"):
        fig.savefig(os.path.join(OUT_FIG, f"width_sqnr.{ext}"))
    plt.close(fig)

    out["runtime_ms_per_acquire"] = {"16": t16 / total * 1e3, "32": t32 / total * 1e3}
    with open(OUT_DATA, "w") as fh:
        json.dump(out, fh, indent=2)
    print(json.dumps(out, indent=2))


# ---------------------------------------------------------------- 32-bit FFT RTL vectors
def write_fft32_vectors():
    """hw/mem/twiddle32.hex and hw/sim/vectors/fft32/{in,out}.hex for the DW=32 FFT
    (same four frames as the 16-bit unit test, scaled to the 32-bit word)."""
    hw = os.path.join(os.path.dirname(__file__), "..", "hw")
    f = F32

    def h32(v):
        return f"{int(v) & 0xFFFFFFFF:08x}"
    with open(os.path.join(hw, "mem", "twiddle32.hex"), "w") as fh:
        for a, b in zip(f.tw_re, f.tw_im):
            fh.write(h32(a) + h32(b) + "\n")
    rng = np.random.default_rng(11)
    n = np.arange(N)
    g = 1 << 16
    frames = []
    imp = np.zeros(N, dtype=np.int64)
    imp[0] = 12000 * g
    frames.append((imp, np.zeros(N, dtype=np.int64)))
    tone = 9000 * g * np.exp(2j * np.pi * 37 * n / N)
    frames.append((np.round(tone.real).astype(np.int64), np.round(tone.imag).astype(np.int64)))
    frames.append((rng.integers(-(1 << 31), 1 << 31, N), rng.integers(-(1 << 31), 1 << 31, N)))
    x = gm.make_if(4, 2000, 100.0, 50, rng)
    frames.append(front_end(bt.if_to_codes(x), f))
    d = os.path.join(hw, "sim", "vectors", "fft32")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "in.hex"), "w") as fi, open(os.path.join(d, "out.hex"), "w") as fo:
        for xr, xi in frames:
            yr, yi = fft_sdf(xr, xi, f)
            for a, b in zip(xr, xi):
                fi.write(h32(a) + h32(b) + "\n")
            for a, b in zip(yr, yi):
                fo.write(h32(a) + h32(b) + "\n")
    print("wrote hw/mem/twiddle32.hex and hw/sim/vectors/fft32/")


if __name__ == "__main__":
    if "--vectors" in sys.argv:
        write_fft32_vectors()
    else:
        main()
