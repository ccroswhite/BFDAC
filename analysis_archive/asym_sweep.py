# Round 28: rise/fall asymmetry sensitivity of the CHOSEN DEM (K=4 par+2nd g2=.5)
# Reuses dem_study.py physics verbatim (execs its prefix up to the schemes list),
# runs only the chosen scheme, and sweeps the asym parameter over the values
# measured in bfdac_cosim26* (3.3V FF drive candidates) vs the old 1.8V baseline.
import numpy as np

src = open("dem_study.py").read()
prefix = src[: src.index("schemes = [")]
g = {}
exec(compile(prefix, "dem_study.py", "exec"), g)

run_constk = g["run_constk"]
glitch_err = g["glitch_err"]
err_sndr_g = g["err_sndr"] if "err_sndr" in g else None
qpc_ffwd = g["qpc_ffwd"]
qpc_const = g["qpc_const"]
code = g["code"]
np_ = g["np"]

# err_sndr needs SIG_P/BAND/BIN from module tail; rebuild here
BAND = g["BAND"]
BIN = g["BIN"]
SIG_P = np.abs(np.fft.rfft(code - code.mean()))[BIN] ** 2

def err_sndr(e):
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    return 10 * np.log10(SIG_P / E[mask].sum())

name, y_mis, k, carr = run_constk(4, shape_par=True, greedy=True, g2=0.5,
                                  name="K=4 par+2nd g2=.5")
dc = np.diff(carr, prepend=carr[0])

cases = [
    ("1.8V LVFET @null (verified baseline)", 0.71e-4),
    ("target ceiling for 128dB budget",       2.0e-4),
    ("1.8V LVFET, FF skew=0 (no trim!)",      1.15e-3),
    ("2N7002 @3.3V, skew=+0.5n",              7.3e-3),
    ("2N7002 @3.3V, skew=+1.5n (null)",       1.9e-5),
    ("2N7002 @2.8V, skew=+0.5n",              5.9e-3),
    ("RK7002BM @3.3V, skew=+0.5n",            2.3e-2),
]

print(f"scheme: {name}  k_mean={k.mean():.2f}  k_max={k.max()}")
print(f"{'case':<40}{'asym':>10} | {'gl_ffwd':>8}{'gl_asymOnly':>12}")
for label, a in cases:
    e_ff = glitch_err(qpc_ffwd, k, dc, asym=a)
    e_asy = glitch_err(qpc_const, k, dc, asym=a)
    print(f"{label:<40}{a:10.2e} | {err_sndr(e_ff):8.1f}{err_sndr(e_asy):12.1f}")
