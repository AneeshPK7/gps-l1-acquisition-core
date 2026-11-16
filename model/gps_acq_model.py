"""
Golden reference model for the FFT-based parallel code phase acquisition core (GPS L1 C/A).

Pipeline (mirrors the RTL):
    real IF @ 4.096 MHz -> fs/4 mixer -> sum-of-4 decimator -> 1024-pt FFT
    -> for k in -5..+5: circular shift by k bins -> x conj(FFT(PRN)) -> IFFT -> |.|^2
    -> peak / second-peak detector

Running this file regenerates every figure and table used in the report.
"""
import json
import os

import numpy as np
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

# ---------------------------------------------------------------- parameters
FS = 4.096e6            # front-end sample rate (Hz)
F_IF = 1.024e6          # intermediate frequency = FS/4 (Hz)
CHIP_RATE = 1.023e6     # C/A chip rate (chips/s)
N_IF = 4096             # IF samples in 1 ms
DECIM = 4
N = N_IF // DECIM       # FFT length (1024)
FS_BB = FS / DECIM      # baseband rate (1.024 MHz) -> FFT bin = 1 kHz
BIN_HZ = FS_BB / N
DOPPLER_BINS = np.arange(-5, 6)  # k, in units of BIN_HZ
ADC_BITS = 3
EXCLUDE = 2             # samples excluded either side of the main peak
THRESHOLD = 2.0         # peak / second-peak ratio

OUT_FIG = os.path.join(os.path.dirname(__file__), "..", "docs", "figures")
OUT_DATA = os.path.join(os.path.dirname(__file__), "results.json")

# G2 phase-selector taps (IS-GPS-200), PRN 1..32
G2_TAPS = {1: (2, 6), 2: (3, 7), 3: (4, 8), 4: (5, 9), 5: (1, 9), 6: (2, 10), 7: (1, 8),
           8: (2, 9), 9: (3, 10), 10: (2, 3), 11: (3, 4), 12: (5, 6), 13: (6, 7),
           14: (7, 8), 15: (8, 9), 16: (9, 10), 17: (1, 4), 18: (2, 5), 19: (3, 6),
           20: (4, 7), 21: (5, 8), 22: (6, 9), 23: (1, 3), 24: (4, 6), 25: (5, 7),
           26: (6, 8), 27: (7, 9), 28: (8, 10), 29: (1, 6), 30: (2, 7), 31: (3, 8),
           32: (4, 9)}


# ---------------------------------------------------------------- C/A code
def ca_code(prn):
    """Return the 1023-chip C/A code for `prn` as +1/-1 values."""
    g1 = [1] * 10
    g2 = [1] * 10
    t1, t2 = G2_TAPS[prn]
    out = []
    for _ in range(1023):
        g2i = g2[t1 - 1] ^ g2[t2 - 1]
        out.append(g1[9] ^ g2i)
        f1 = g1[2] ^ g1[9]
        f2 = g2[1] ^ g2[2] ^ g2[5] ^ g2[7] ^ g2[8] ^ g2[9]
        g1 = [f1] + g1[:9]
        g2 = [f2] + g2[:9]
    return 1 - 2 * np.array(out)  # 0 -> +1, 1 -> -1


def code_ref_fft(prn):
    """conj(FFT) of the code resampled to N samples per 1 ms (stored in ROM)."""
    code = ca_code(prn)
    idx = np.floor(np.arange(N) * CHIP_RATE / FS_BB).astype(int) % 1023
    return np.conj(np.fft.fft(code[idx]))


# ---------------------------------------------------------------- signal
def make_if(prn, doppler_hz, code_phase_chips, cn0_dbhz, rng, present=True):
    """1 ms of real, quantised IF samples."""
    t = np.arange(N_IF) / FS
    sig = np.zeros(N_IF)
    if present:
        code = ca_code(prn)
        chip = np.floor(t * CHIP_RATE - code_phase_chips).astype(int) % 1023
        phi = rng.uniform(0, 2 * np.pi)
        sig = code[chip] * np.cos(2 * np.pi * (F_IF + doppler_hz) * t + phi)
    # carrier amplitude 1 -> C = 1/2 ; N0 = sigma^2 / (FS/2)
    c = 0.5
    sigma = np.sqrt(c / 10 ** (cn0_dbhz / 10) * FS / 2)
    x = sig + sigma * rng.standard_normal(N_IF)
    # ADC: ADC_BITS-bit mid-rise quantiser, full scale ~ 3 sigma
    levels = 2 ** ADC_BITS
    step = 6 * sigma / levels
    q = np.clip(np.floor(x / step), -levels // 2, levels // 2 - 1)
    return (q + 0.5) * 2  # odd integers: +-1, +-3, ...


# ---------------------------------------------------------------- front end
def front_end(x_if):
    """fs/4 complex mixer (multiplier-free) followed by sum-of-4 decimation."""
    lo = np.tile(np.array([1, -1j, -1, 1j]), N_IF // 4)  # exp(-j*pi*n/2)
    bb = x_if * lo
    return bb.reshape(N, DECIM).sum(axis=1)


# ---------------------------------------------------------------- fixed-point FFT
SCALE_HALF = [s % 2 == 0 for s in range(10)]  # /2 on every other stage -> total 1/32


def fft_fixed(x, data_bits=16, tw_bits=16, scale=SCALE_HALF):
    """Radix-2 DIF FFT with rounding/saturation after every stage (models the RTL).

    `scale[s]` selects a divide-by-2 after stage s. The default schedule divides on
    five of the ten stages (total 1/sqrt(N)), which matches the sqrt(N) growth of
    noise-like GNSS samples. Output is in natural order (the RTL keeps bit-reversed
    order internally).
    """
    n = len(x)
    stages = int(np.log2(n))
    lim = 2 ** (data_bits - 1)
    tscale = 2 ** (tw_bits - 2)
    tw = np.exp(-2j * np.pi * np.arange(n // 2) / n)
    tw = (np.round(tw.real * tscale) + 1j * np.round(tw.imag * tscale)) / tscale

    def q(v):
        r = np.clip(np.round(v.real), -lim, lim - 1)
        i = np.clip(np.round(v.imag), -lim, lim - 1)
        return r + 1j * i

    a = q(np.asarray(x, dtype=complex))
    for s in range(stages):
        half = n >> (s + 1)
        a = a.reshape(-1, 2 * half)
        top, bot = a[:, :half], a[:, half:]
        w = tw[:: (1 << s)][:half]
        d = 2 if scale[s] else 1
        a = np.hstack([q((top + bot) / d), q((top - bot) / d * w)]).reshape(-1)
    return a[_bitrev_order(n)]


_BITREV = {}


def _bitrev_order(n):
    if n not in _BITREV:
        b = int(np.log2(n))
        rev = np.array([int(f"{i:0{b}b}"[::-1], 2) for i in range(n)])
        _BITREV[n] = np.argsort(rev)
    return _BITREV[n]


# ---------------------------------------------------------------- acquisition
def acquire(x_if, prn, fixed=False, return_surface=False):
    bb = front_end(x_if)
    cref = code_ref_fft(prn)
    if fixed:
        X = fft_fixed(bb * 64)  # input gain so the 3-bit samples use the 16-bit range
        cq = np.round(cref / np.abs(cref).max() * (2 ** 7 - 1))  # 8-bit ROM
        # one block exponent for all Doppler bins (a single barrel shift in RTL)
        shift = 2 ** np.ceil(np.log2(np.abs(X).max() * 127 / 2 ** 13))
    else:
        X = np.fft.fft(bb)
        cq = cref
    surf = np.zeros((len(DOPPLER_BINS), N))
    for r, k in enumerate(DOPPLER_BINS):
        prod = np.roll(X, -k) * cq
        if fixed:
            # IFFT via conj -> FFT -> conj, reusing the same fixed-point core
            prod = np.round(prod / shift)
            corr = np.conj(fft_fixed(np.conj(prod)))
        else:
            corr = np.fft.ifft(prod)
        surf[r] = np.abs(corr) ** 2
    r_pk, tau = np.unravel_index(np.argmax(surf), surf.shape)
    row = surf[r_pk].copy()
    excl = (np.arange(-EXCLUDE, EXCLUDE + 1) + tau) % N
    peak = row[tau]
    row[excl] = 0
    ratio = peak / row.max()
    res = dict(doppler_hz=float(DOPPLER_BINS[r_pk] * BIN_HZ),
               code_phase_samples=int(tau),
               code_phase_chips=float(tau * CHIP_RATE / FS_BB),
               ratio=float(ratio), detected=bool(ratio > THRESHOLD))
    if return_surface:
        return res, surf
    return res


def check(res, fd, cp, dop_tol=0.5 * BIN_HZ):
    dop_ok = abs(res["doppler_hz"] - fd) <= dop_tol + 1e-6
    true_s = cp * FS_BB / CHIP_RATE
    err = (res["code_phase_samples"] - true_s + N / 2) % N - N / 2
    return dop_ok and abs(err) <= 1.0 and res["detected"], err


# ---------------------------------------------------------------- figures
def style():
    plt.rcParams.update({"font.family": "serif", "mathtext.fontset": "cm",
                         "font.size": 10, "axes.grid": True, "grid.alpha": 0.3,
                         "figure.dpi": 150, "savefig.bbox": "tight"})


def main():
    os.makedirs(OUT_FIG, exist_ok=True)
    style()
    rng = np.random.default_rng(2026)
    results = {}

    # sanity: first 10 chips of PRN 1 are 1100100000 (octal 1440)
    first10 = "".join("1" if c < 0 else "0" for c in ca_code(1)[:10])
    results["prn1_first10"] = first10

    # --- Fig: correlation surface -----------------------------------------
    PRN, FD, CP, CN0 = 7, 3000.0, 350.0, 50.0
    x = make_if(PRN, FD, CP, CN0, rng)
    res, surf = acquire(x, PRN, return_surface=True)
    results["demo"] = dict(prn=PRN, fd=FD, cp=CP, cn0=CN0, **res)

    fig = plt.figure(figsize=(6.4, 4.4))
    ax = fig.add_subplot(111, projection="3d")
    ax.set_box_aspect(None, zoom=0.88)
    tau = np.arange(N) * CHIP_RATE / FS_BB
    T, D = np.meshgrid(tau, DOPPLER_BINS * BIN_HZ / 1e3)
    ax.plot_surface(T, D, surf / surf.max(), cmap="viridis", linewidth=0,
                    rstride=1, cstride=4, antialiased=True)
    ax.set_xlabel("Code phase (chips)")
    ax.set_ylabel("Doppler (kHz)")
    ax.set_zlabel("Normalised $|R|^2$")
    ax.view_init(elev=28, azim=-60)
    fig.savefig(os.path.join(OUT_FIG, "corr_surface.pdf"), pad_inches=0.25)
    plt.close(fig)

    # --- Fig: slices --------------------------------------------------------
    r_pk = list(DOPPLER_BINS * BIN_HZ).index(res["doppler_hz"])
    fig, axs = plt.subplots(1, 2, figsize=(6.4, 2.4))
    axs[0].plot(tau, surf[r_pk] / surf.max(), lw=0.7)
    axs[0].set_xlabel("Code phase (chips)")
    axs[0].set_ylabel("Normalised $|R|^2$")
    axs[0].set_title(f"Doppler bin {res['doppler_hz']/1e3:+.0f} kHz", fontsize=9)
    axs[1].bar(DOPPLER_BINS, surf[:, res["code_phase_samples"]] / surf.max(), width=0.7)
    axs[1].set_xlabel("Doppler bin $k$ (kHz)")
    axs[1].set_title(f"Code phase {res['code_phase_chips']:.1f} chips", fontsize=9)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_FIG, "corr_slices.pdf"))
    plt.close(fig)

    # --- Directed tests ------------------------------------------------------
    cases = [
        ("Clean, positive Doppler", 1, 3000, 512.0, 60, True),
        ("Negative Doppler", 5, -4000, 87.3, 52, True),
        ("Zero Doppler", 12, 0, 1000.5, 52, True),
        ("Upper band edge", 20, 5000, 201.7, 52, True),
        ("Lower band edge", 31, -5000, 15.0, 52, True),
        ("Off-bin Doppler", 9, -2400, 640.2, 52, True),
        ("UAV dynamics (+260 Hz)", 17, 1260, 333.3, 50, True),
        ("Noise only", 3, 0, 0.0, 52, False),
    ]
    table = []
    for name, prn, fd, cp, cn0, present in cases:
        x = make_if(prn, fd, cp, cn0, rng, present=present)
        r = acquire(x, prn)
        rf = acquire(x, prn, fixed=True)
        if present:
            ok, err = check(r, fd, cp)
            okf, _ = check(rf, fd, cp)
        else:
            ok, okf, err = (not r["detected"]), (not rf["detected"]), 0.0
        table.append(dict(name=name, prn=prn, fd=fd, cp=cp, cn0=cn0, present=present,
                          fd_hat=r["doppler_hz"], cp_hat=r["code_phase_chips"],
                          ratio=r["ratio"], ratio_fx=rf["ratio"],
                          pass_float=bool(ok), pass_fixed=bool(okf)))
    results["directed"] = table

    # --- Monte Carlo: Pd vs C/N0, Pfa --------------------------------------
    cn0s = np.arange(38, 57, 2)
    trials = 300
    pd, pd_fx, pd_adj = [], [], []
    for cn0 in cn0s:
        hits = hits_fx = hits_adj = 0
        for _ in range(trials):
            prn = int(rng.integers(1, 33))
            fd = rng.uniform(-5000, 5000)
            cp = rng.uniform(0, 1023)
            x = make_if(prn, fd, cp, cn0, rng)
            r = acquire(x, prn)
            hits += check(r, fd, cp)[0]
            hits_adj += check(r, fd, cp, dop_tol=1.5 * BIN_HZ)[0]
            hits_fx += check(acquire(x, prn, fixed=True), fd, cp)[0]
        pd.append(hits / trials)
        pd_fx.append(hits_fx / trials)
        pd_adj.append(hits_adj / trials)
    fa_trials = 1000
    ratios_noise = [acquire(make_if(1, 0, 0, 45, rng, present=False), 1)["ratio"]
                    for _ in range(fa_trials)]
    pfa = float(np.mean(np.array(ratios_noise) > THRESHOLD))
    results["pd"] = dict(cn0=cn0s.tolist(), pd=pd, pd_fx=pd_fx, pd_adj=pd_adj, trials=trials)
    results["pfa"] = dict(pfa=pfa, trials=fa_trials,
                          ratio_p99=float(np.percentile(ratios_noise, 99)))

    fig, ax = plt.subplots(figsize=(4.6, 2.8))
    ax.plot(cn0s, pd, "o-", ms=4, label="Floating point")
    ax.plot(cn0s, pd_fx, "s--", ms=4, label="16-bit fixed point")
    ax.plot(cn0s, pd_adj, "^:", ms=4, label="Float, Doppler within $\\pm$1 bin")
    ax.legend(fontsize=8)
    ax.set_xlabel("$C/N_0$ (dB-Hz)")
    ax.set_ylabel("Probability of detection")
    ax.set_ylim(-0.02, 1.02)
    ax.set_title(f"1 ms coherent, threshold {THRESHOLD}, {trials} trials/point", fontsize=9)
    fig.savefig(os.path.join(OUT_FIG, "pd_vs_cn0.pdf"))
    plt.close(fig)

    # --- Scalloping loss vs Doppler offset ----------------------------------
    offs = np.linspace(-500, 500, 41)
    loss = []
    srng = np.random.default_rng(1)
    trials_s = [(int(srng.integers(1, 33)), srng.uniform(0, 1023), int(srng.integers(-4, 4)))
                for _ in range(24)]
    for off in offs:
        acc = 0.0
        for j, (prn, cp, kc) in enumerate(trials_s):
            x = make_if(prn, kc * BIN_HZ + off, cp, 60, np.random.default_rng(100 + j))
            _, s = acquire(x, prn, return_surface=True)
            acc += s.max()
        loss.append(acc / len(trials_s))
    loss = 10 * np.log10(np.array(loss) / max(loss))
    theory = 20 * np.log10(np.abs(np.sinc(offs / 1000)) + 1e-12)
    results["scalloping_worst_db"] = float(loss.min())
    fig, ax = plt.subplots(figsize=(4.6, 2.6))
    ax.plot(offs, loss, "o", ms=3, label="Model")
    ax.plot(offs, theory, "-", lw=1, label=r"$20\log_{10}|\mathrm{sinc}(\Delta f\,T)|$")
    ax.set_xlabel(r"Offset from bin centre $\Delta f$ (Hz)")
    ax.set_ylabel("Peak loss (dB)")
    ax.legend(fontsize=8)
    fig.savefig(os.path.join(OUT_FIG, "scalloping.pdf"))
    plt.close(fig)

    # --- Fixed-point FFT accuracy -------------------------------------------
    widths = [10, 12, 14, 16, 18]
    sq = []
    x = make_if(1, 1000, 300.0, 45, rng)
    bb = front_end(x) * 64
    ref = np.fft.fft(bb) / 32
    for w in widths:
        y = fft_fixed(bb * 2 ** (w - 16), data_bits=w, tw_bits=w) / 2 ** (w - 16)
        sq.append(10 * np.log10(np.sum(np.abs(ref) ** 2) / np.sum(np.abs(y - ref) ** 2)))
    results["sqnr"] = dict(bits=widths, sqnr_db=[float(v) for v in sq])
    fig, ax = plt.subplots(figsize=(4.6, 2.6))
    ax.plot(widths, sq, "s-", ms=4)
    ax.set_xlabel("Data / twiddle word length (bits)")
    ax.set_ylabel("FFT output SQNR (dB)")
    fig.savefig(os.path.join(OUT_FIG, "sqnr.pdf"))
    plt.close(fig)

    # --- Doppler sidelobes and real-IF image (noise-free, unquantised) ---------
    t = np.arange(N_IF) / FS
    code = ca_code(20)
    chip = np.floor(t * CHIP_RATE - 655.1).astype(int) % 1023
    xs = code[chip] * np.cos(2 * np.pi * (F_IF + 3000) * t + 0.3)
    _, s = acquire(xs, 20, return_surface=True)
    rows = 10 * np.log10(s.max(axis=1) / s.max())
    k = list(DOPPLER_BINS)
    results["doppler_sidelobe_db"] = float(max(rows[k.index(2)], rows[k.index(4)]))
    results["image_ghost_db"] = float(rows[k.index(-3)])
    results["doppler_rows_db"] = [float(v) for v in rows]

    # --- Fig: IF signal and spectrum -----------------------------------------
    x = make_if(1, 1000, 0.0, 45, rng)
    fig, axs = plt.subplots(1, 2, figsize=(6.4, 2.3))
    axs[0].step(np.arange(80) / FS * 1e6, x[:80], where="post", lw=0.8)
    axs[0].set_xlabel(r"Time ($\mu$s)")
    axs[0].set_ylabel("ADC code")
    axs[0].set_title("3-bit IF samples (first 80)", fontsize=9)
    f = np.fft.rfftfreq(N_IF, 1 / FS) / 1e6
    P = np.abs(np.fft.rfft(x)) ** 2
    Pk = np.convolve(P, np.ones(16) / 16, mode="same")
    axs[1].plot(f, 10 * np.log10(Pk / Pk.max()), lw=0.7)
    axs[1].set_xlabel("Frequency (MHz)")
    axs[1].set_ylabel("PSD (dB, rel.)")
    axs[1].set_title("Spectrum (smoothed)", fontsize=9)
    fig.tight_layout()
    fig.savefig(os.path.join(OUT_FIG, "if_signal.pdf"))
    plt.close(fig)

    with open(OUT_DATA, "w") as fh:
        json.dump(results, fh, indent=2)
    print(json.dumps(results, indent=2))


if __name__ == "__main__":
    main()
