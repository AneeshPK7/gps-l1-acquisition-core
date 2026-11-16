"""
Generate ROM images and test vectors for the RTL from the bit-true model.

Outputs (relative to the project root):
  hw/mem/twiddle.hex          512 x 32-bit  {re[15:0], im[15:0]}  Q2.14
  hw/mem/code_rom.hex         32768 x 16-bit {re[7:0], im[7:0]}   addr = (prn-1)*1024 + m
  hw/sim/vectors/<set>/samples.hex    ntests*1024 x 32-bit AXI-Stream words (4 codes / word)
  hw/sim/vectors/<set>/expected.hex   ntests lines x 12 words (see EXP_FIELDS)
  hw/sim/vectors/<set>/meta.hex       ntests
  hw/sim/vectors/<set>/cases.json     human-readable description
  hw/sim/vectors/fft/{in,out}.hex     FFT unit-test frames (impulse, tone, random, GNSS)

Usage:  python3 model/gen_vectors.py [--regress N]
"""
import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
import gps_acq_model as G  # noqa: E402
import bit_true_model as B  # noqa: E402

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), ".."))
MEM = os.path.join(ROOT, "hw", "mem")
VEC = os.path.join(ROOT, "hw", "sim", "vectors")

EXP_FIELDS = ["prn", "thresh", "exp_k", "exp_tau", "exp_peak", "exp_second", "exp_det",
              "present", "true_k", "true_tau_q4", "id", "reserved"]

# Directed tests T1..T8 exactly as in the report (same RNG sequence as gps_acq_model.main)
DIRECTED = [
    ("T1", "Strong signal (60 dB-Hz)", 1, 3000, 512.0, 60, True),
    ("T2", "Negative Doppler", 5, -4000, 87.3, 52, True),
    ("T3", "Zero Doppler", 12, 0, 1000.5, 52, True),
    ("T4", "Upper band edge", 20, 5000, 201.7, 52, True),
    ("T5", "Lower band edge", 31, -5000, 15.0, 52, True),
    ("T6", "Doppler between bins", 9, -2400, 640.2, 52, True),
    ("T7", "UAV motion (+260 Hz)", 17, 1260, 333.3, 50, True),
    ("T8", "Noise only", 3, 0, 0.0, 52, False),
]


def h32(v):
    return f"{int(v) & 0xFFFFFFFF:08x}"


def h16(v):
    return f"{int(v) & 0xFFFF:04x}"


def write_roms():
    os.makedirs(MEM, exist_ok=True)
    with open(os.path.join(MEM, "twiddle.hex"), "w") as f:
        for r, i in zip(B.TW_RE, B.TW_IM):
            f.write(h16(r) + h16(i) + "\n")
    with open(os.path.join(MEM, "code_rom.hex"), "w") as f:
        for prn in range(1, 33):
            cr, ci = B.code_rom(prn)
            for r, i in zip(cr, ci):
                f.write(f"{int(r) & 0xFF:02x}{int(i) & 0xFF:02x}\n")


def pack_words(codes):
    c = (np.asarray(codes) & 0x7).reshape(-1, 4)
    return [int(w[0] | (w[1] << 8) | (w[2] << 16) | (w[3] << 24)) for w in c]


def write_set(name, cases):
    """cases: list of dicts with prn, fd, cp, present, codes, label."""
    d = os.path.join(VEC, name)
    os.makedirs(d, exist_ok=True)
    meta = []
    with open(os.path.join(d, "samples.hex"), "w") as fs, \
         open(os.path.join(d, "expected.hex"), "w") as fe:
        for n, c in enumerate(cases):
            for w in pack_words(c["codes"]):
                fs.write(h32(w) + "\n")
            r = B.acquire(c["codes"], c["prn"])
            true_k = int(np.clip(np.round(c["fd"] / 1000.0), -5, 5)) if c["present"] else 0
            true_tau = c["cp"] * 1.024e6 / 1.023e6
            words = [c["prn"], B.THRESH_DEFAULT, r["k"], r["tau"], r["peak"], r["second"],
                     int(r["detected"]), int(c["present"]), true_k,
                     int(round(true_tau * 16)) % (16 * B.N), n, 0]
            fe.write(" ".join(h32(w) for w in words) + "\n")
            meta.append(dict(label=c["label"], prn=c["prn"], fd=c["fd"], cp=c["cp"],
                             cn0=c["cn0"], present=c["present"], model=r))
    with open(os.path.join(d, "meta.hex"), "w") as f:
        f.write(h32(len(cases)) + "\n")
    with open(os.path.join(d, "cases.json"), "w") as f:
        json.dump(meta, f, indent=2)
    return meta


def directed_cases():
    rng = np.random.default_rng(2026)
    G.make_if(7, 3000.0, 350.0, 50.0, rng)       # demo signal drawn first in gps_acq_model.main
    out = []
    for tid, label, prn, fd, cp, cn0, present in DIRECTED:
        x = G.make_if(prn, fd, cp, cn0, rng, present=present)
        out.append(dict(label=f"{tid} {label}", prn=prn, fd=fd, cp=cp, cn0=cn0,
                        present=present, codes=B.if_to_codes(x)))
    return out


def random_cases(n, seed=7):
    rng = np.random.default_rng(seed)
    out = []
    for i in range(n):
        prn = int(rng.integers(1, 33))
        fd = float(rng.uniform(-5000, 5000))
        cp = float(rng.uniform(0, 1023))
        cn0 = float(rng.uniform(46, 58))
        present = bool(rng.uniform() > 0.15)
        x = G.make_if(prn, fd, cp, cn0, rng, present=present)
        out.append(dict(label=f"R{i + 1}", prn=prn, fd=fd, cp=cp, cn0=cn0,
                        present=present, codes=B.if_to_codes(x)))
    return out


def write_fft_vectors():
    """Four back-to-back frames: impulse, tone, full-scale random, real GNSS baseband."""
    rng = np.random.default_rng(11)
    n = np.arange(B.N)
    frames = []
    imp = np.zeros(B.N, dtype=np.int64)
    imp[0] = 12000
    frames.append((imp, np.zeros(B.N, dtype=np.int64)))
    tone = 9000 * np.exp(2j * np.pi * 37 * n / B.N)
    frames.append((np.round(tone.real).astype(np.int64), np.round(tone.imag).astype(np.int64)))
    frames.append((rng.integers(-32768, 32768, B.N), rng.integers(-32768, 32768, B.N)))
    x = G.make_if(4, 2000, 100.0, 50, rng)
    frames.append(B.front_end(B.if_to_codes(x)))
    d = os.path.join(VEC, "fft")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "in.hex"), "w") as fi, open(os.path.join(d, "out.hex"), "w") as fo:
        for xr, xi in frames:
            yr, yi = B.fft_sdf(xr, xi)
            for a, b in zip(xr, xi):
                fi.write(h16(a) + h16(b) + "\n")
            for a, b in zip(yr, yi):
                fo.write(h16(a) + h16(b) + "\n")


def write_c_header(name, cases):
    """sw/test_vectors.h: directed vectors + bit-true expected results for the PS HIL test."""
    path = os.path.join(ROOT, "sw", "test_vectors.h")
    with open(path, "w") as f:
        f.write("/* Generated by model/gen_vectors.py - do not edit. */\n")
        f.write("#ifndef TEST_VECTORS_H\n#define TEST_VECTORS_H\n#include <stdint.h>\n\n")
        f.write(f"#define TV_NUM {len(cases)}\n\n")
        f.write("typedef struct { const char *name; int prn, k, tau, detected;"
                " uint32_t peak, second; } tv_expected_t;\n\n")
        f.write("static const tv_expected_t tv_expected[TV_NUM] = {\n")
        for c in cases:
            r = B.acquire(c["codes"], c["prn"])
            f.write(f'    {{"{c["label"].split()[0]}", {c["prn"]}, {r["k"]}, {r["tau"]}, '
                    f'{int(r["detected"])}, {r["peak"]}u, {r["second"]}u}},\n')
        f.write("};\n\n")
        f.write("static const uint32_t tv_samples[TV_NUM][1024] __attribute__((aligned(64))) = {\n")
        for c in cases:
            words = pack_words(c["codes"])
            f.write("  {\n")
            for i in range(0, len(words), 8):
                f.write("    " + ", ".join(f"0x{w:08x}u" for w in words[i:i + 8]) + ",\n")
            f.write("  },\n")
        f.write("};\n\n#endif\n")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--regress", type=int, default=24, help="number of random cases")
    args = ap.parse_args()
    write_roms()
    write_fft_vectors()
    directed = directed_cases()
    meta = write_set("directed", directed)
    write_c_header("directed", directed)
    for m in meta:
        r = m["model"]
        print(f"{m['label']:<32} k={r['k']:+d} tau={r['tau']:4d} ratio={r['ratio']:6.2f} "
              f"det={r['detected']}")
    write_set("regress", random_cases(args.regress))
    print(f"wrote ROMs to {MEM} and vectors to {VEC}")


if __name__ == "__main__":
    main()
