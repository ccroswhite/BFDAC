# N2: JITTER INJECTION gates. Reuse the gate-77 stream/deck (same pwl77 sel
# vectors, same code file) but replace the shared RTZ window sources pwa/pwb
# (PULSE) with PWL trains whose per-period rise/fall edge times are perturbed
# by white gaussian jitter (independent per clock edge, common to all 64 cells
# = reclock-flop model). Differential measurement: pavg(78x) - pavg(77) is the
# pure jitter-induced error (deterministic part cancels exactly).
# Variants: 78a sigma=10ps, 78b sigma=1ps.
import numpy as np
import os

LT = r"C:\Users\ccros\Documents\LTspice"
M = 16384
TS = 162.7604e-9
TC = TS / 8
T0 = TC                 # rise-begin offset (deck .param t0=tc)
TEDGE = 3e-9
TWID = 6 * TC           # on-window (deck .param twid=6*tc)
SKEW = 1e-9             # pwb skew

VARIANTS = {"78a": 10e-12, "78b": 1e-12, "78c": 0.0}
rng = np.random.default_rng(300)

def pwl_train(skew, dr, df):
    lines = ["0 0"]
    for k in range(M):
        tr = k * TS + T0 + skew + dr[k]
        tf = k * TS + T0 + TEDGE + TWID + skew + df[k]
        lines.append(f"{tr*1e9:.6f}n 0")
        lines.append(f"{(tr+TEDGE)*1e9:.6f}n 1")
        lines.append(f"{tf*1e9:.6f}n 1")
        lines.append(f"{(tf+TEDGE)*1e9:.6f}n 0")
    lines.append(f"{(M*TS)*1e9:.6f}n 0")
    return "\n".join(lines) + "\n"

src77 = open(os.path.join(LT, "bfdac_cosim77.cir")).read()
for tag, sig in VARIANTS.items():
    # independent jitter per clock edge; pwa/pwb edges are distinct flop edges
    d = rng.normal(0, sig, (4, M))
    pd = os.path.join(LT, f"pwl{tag}")
    os.makedirs(pd, exist_ok=True)
    open(os.path.join(pd, "pwa.txt"), "w").write(pwl_train(0.0, d[0], d[1]))
    open(os.path.join(pd, "pwb.txt"), "w").write(pwl_train(SKEW, d[2], d[3]))
    src = src77.replace("v77", f"v{tag}")
    src = src.replace(
        "Vpwa pwa 0 PULSE(0 1 {t0} {tedge} {tedge} {twid} {Ts})",
        f'Vpwa pwa 0 PWL file="{pd}\\pwa.txt"')
    src = src.replace(
        "Vpwb pwb 0 PULSE(0 1 {t0+skew} {tedge} {tedge} {twid} {Ts})",
        f'Vpwb pwb 0 PWL file="{pd}\\pwb.txt"')
    assert "PULSE" not in src
    open(os.path.join(LT, f"bfdac_cosim{tag}.cir"), "w").write(src)
    np.save(os.path.join(LT, f"cosim{tag}_code.npy"),
            np.load(os.path.join(LT, "cosim77_code.npy")))
    print(f"{tag}: sigma_t {sig*1e12:.1f} ps, deck + pwa/pwb PWL written "
          f"(sel vectors shared from pwl77)")
