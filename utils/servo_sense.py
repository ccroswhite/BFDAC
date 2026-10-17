"""CASB2 servo sense-node audit (bom 17(k), 2026-10-01).

The ruled servo holds the DC mean of mid_p (M6 source) at a 3.0 V tap.  Before
the loop deck is built this script checks what that "DC mean" actually is on
the locked plant: V_gs(M6) is sqrt(I)-nonlinear, so mean(mid_p) may depend on
program level; the loop would then move casb2 with the music envelope.

Usage: python utils/servo_sense.py TAG [TAG ...]
Reads bfdac_cosim<TAG>.raw (needs V(mid_p) V(mid_m) in .save), reports per-TAG:
  mean(mid_p/m) over whole frames after a discard, p-p ripple, rms ripple,
  spectrum of mid_p at the fundamental, and the spread of the per-frame mean.
"""
import sys
import numpy as np
from read_ltraw import read_raw

LT = r"C:\Users\ccros\Documents\LTspice"
Ts = 162.7604e-9          # RTZ frame, same as the deck .param
DISCARD_US = 40.0         # settle discard (plant poles are < 10 us)


def frame_means(t, v, t0, t1):
    """Mean of v over every whole frame in [t0, t1) on the non-uniform grid."""
    out = []
    k0 = int(np.ceil(t0 / Ts))
    k1 = int(np.floor(t1 / Ts))
    for k in range(k0, k1):
        a, b = k * Ts, (k + 1) * Ts
        m = (t >= a) & (t < b)
        if m.sum() < 4:
            continue
        tt = np.concatenate(([a], t[m], [b]))
        vv = np.concatenate(([np.interp(a, t, v)], v[m], [np.interp(b, t, v)]))
        out.append(np.trapezoid(vv, tt) / Ts)
    return np.array(out)


def report(tag):
    names, data = read_raw(rf"{LT}\bfdac_cosim{tag}.raw")
    t = data[0]
    t0 = DISCARD_US * 1e-6
    sel = t >= t0
    print(f"=== {tag}: {len(t)} pts, t_end {t[-1]*1e6:.1f} us, analysed from {DISCARD_US:.0f} us ===")
    for node in ("V(mid_p)", "V(mid_m)"):
        if node not in names:
            print(f"  {node}: not saved")
            continue
        v = data[names.index(node)]
        fm = frame_means(t, v, t0, t[-1])
        vs = v[sel]
        tmean = np.trapezoid(vs, t[sel]) / (t[sel][-1] - t[sel][0])
        # per-frame-mean spectrum at the stream fundamental (bin / M of fs = 1/Ts)
        n = len(fm)
        spec = np.abs(np.fft.rfft((fm - fm.mean()) * np.hanning(n))) * 2 / n * 2
        f = np.fft.rfftfreq(n, Ts)
        k = np.argmax(spec[1:]) + 1
        print(f"  {node}: time-mean {tmean*1e3:9.3f} mV | frame-mean mean {fm.mean()*1e3:9.3f} mV, "
              f"sd {fm.std()*1e3:7.3f} mV, p-p {np.ptp(fm)*1e3:7.2f} mV | "
              f"raw p-p {np.ptp(vs)*1e3:7.1f} mV | largest frame-mean tone {spec[k]*1e3:.3f} mV @ {f[k]/1e3:.2f} kHz")
    return


if __name__ == "__main__":
    for tag in sys.argv[1:]:
        report(tag)
