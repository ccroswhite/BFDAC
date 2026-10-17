"""Fast static-INL probe for the base-drive network (2026-09-27, after the
G1 failure: real rs/rp drive -> HD2 -90 dBc, compensated caps -> -63).

Takes a finished cosim deck as template, replaces the PWL cell selections by
DC (cells 1..N selected, the rest off), shortens the transient to a few
periods and measures the averaged I/V output vs N.  The residual of V(N)
from a straight line is the code-dependent per-cell charge - the mechanism
behind the D1 failure - and is obtained in seconds instead of 95 min.

    python drive_inl.py <template_tag> [label]   (e.g. 121 ideal, 122 real)
Env: NS (0,8,...,64) comma list of N;  PERIODS (24);  KEEP=1 keep decks
Prints V_diff(N), linear-fit residual in ppm of full scale and the fitted
quadratic (HD2 proxy: a2/a1 * FS/4 in dBc for a full-scale sine).
"""
import os
import re
import subprocess
import sys
import numpy as np

LT = r"C:\Users\ccros\Documents\LTspice"
LTS = r"C:\Program Files\ADI\LTspice\LTspice.exe"
TS = 162.7604e-9
NS = [int(x) for x in os.environ.get("NS", "0,8,16,24,32,40,48,56,64").split(",")]
PER = int(os.environ.get("PERIODS", 24))


def build(src, n, tag):
    out = re.sub(r'^Vsel(\d+)\s+sel\1\s+0\s+PWL.*$',
                 lambda m: "Vsel%s sel%s 0 DC %d" % (m.group(1), m.group(1), 1 if int(m.group(1)) <= n else 0),
                 src, flags=re.M)
    out = re.sub(r'^Vnsch\s+nsch\s+0\s+PWL.*$', "Vnsch nsch 0 DC 0", out, flags=re.M)
    out = re.sub(r'^\.tran.*$', ".tran 0.5n %.6gu 0" % (PER * TS * 1e6), out, flags=re.M)
    out = re.sub(r'^\.save.*$', ".save V(out_p) V(out_m)", out, flags=re.M)
    t1, t2 = (PER - 8) * TS, PER * TS
    meas = (".meas TRAN vop AVG V(out_p) FROM %.6gu TO %.6gu\n.meas TRAN vom AVG V(out_m) FROM %.6gu TO %.6gu\n"
            % (t1 * 1e6, t2 * 1e6, t1 * 1e6, t2 * 1e6))
    out = out.replace(".end", meas + ".end")
    path = os.path.join(LT, "bfdac_inl%s_%02d.cir" % (tag, n))
    open(path, "w").write(out)
    return path


def run(path):
    subprocess.run([LTS, "-b", path], check=True)
    log = open(path.replace(".cir", ".log"), errors="ignore").read()
    v = {}
    for k in ("vop", "vom"):
        m = re.search(r"^%s:\s*AVG\(V\(out_[pm]\)\s*\)=(\S+)" % k, log, flags=re.M | re.I)
        v[k] = float(m.group(1))
    return v["vop"], v["vom"]


def main():
    tag = sys.argv[1]
    label = sys.argv[2] if len(sys.argv) > 2 else tag
    src = open(os.path.join(LT, "bfdac_cosim%s.cir" % tag)).read()
    rows = []
    for n in NS:
        p = build(src, n, tag)
        vop, vom = run(p)
        rows.append((n, vop, vom, vom - vop))
        if not os.environ.get("KEEP"):
            for ext in (".cir", ".log", ".raw", ".op.raw"):
                try:
                    os.remove(p.replace(".cir", ext))
                except OSError:
                    pass
    N = np.array([r[0] for r in rows], float)
    V = np.array([r[3] for r in rows])
    a1, a0 = np.polyfit(N, V, 1)
    fs = a1 * 64
    resid = V - (a1 * N + a0)
    c2, c1, c0 = np.polyfit(N - 32, V, 2)
    # V = c1*x + c2*x^2, x = 32*sin -> HD2/fund = c2*32/(2*c1)
    hd2 = 20 * np.log10(abs(c2 * 32 / (2 * c1))) if c1 else float("nan")
    print("drive_inl %s (%s): %d periods, avg of last 8" % (label, tag, PER))
    print("   N    V(out_p)    V(out_m)     V_diff      resid[ppm FS]")
    for (n, vop, vom, vd), r in zip(rows, resid):
        print("  %2d  %10.6f  %10.6f  %10.6f  %10.1f" % (n, vop, vom, vd, r / fs * 1e6))
    print("  FS %.4f V, gain %.5f V/cell, max |INL| %.1f ppm, quadratic HD2 proxy %.1f dBc"
          % (fs, a1, np.max(np.abs(resid)) / abs(fs) * 1e6, hd2))


if __name__ == "__main__":
    main()
