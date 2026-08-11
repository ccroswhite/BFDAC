# Replica-DAC option C (bom.md open item #6): transistor-level replica vs
# behavioral B-source, mapped through the dem_study glitch framework.
#
# Profiles (bfdac_cosim29-series, q_rise measured at k = 1,2,4,8):
#   C24  = cosim24 re-run baseline (behavioral B_ff/B_snk, this machine)
#   V29  = cosim29  raw transistor replica (cell + PNP/NPN mirrors)
#   V29C = cosim29c + 5 mA constant mirror bleed
#   V29E = cosim29e + bleed + spike caps (22p diode filter, 2.2n casb/q5ce)
#
# Each profile uses its own measured worst-|k| rise/fall asymmetry.
# Schemes: the ratified const-k K=4 parity+2nd-order greedy mapper, plus
# DWA classic (RTZ-eligible) for reference.
import numpy as np

src = open("dem_study.py").read()
prefix = src[: src.index("schemes = [")]
g = {}
exec(compile(prefix, "dem_study.py", "exec"), g)

run_constk = g["run_constk"]
run_scheme = g["run_scheme"]
glitch_err = g["glitch_err"]
code = g["code"]
K_MEAS = g["K_MEAS"]
NFFT = g["NFFT"]
BAND = g["BAND"]
BIN = g["BIN"]

SIG_P = np.abs(np.fft.rfft(code - code.mean()))[BIN] ** 2

def err_sndr(e):
    E = np.abs(np.fft.rfft(e - np.mean(e))) ** 2
    mask = BAND.copy()
    mask[BIN] = False
    return 10 * np.log10(SIG_P / E[mask].sum())

# q_rise (V*s at diffout) per deck, k = 1,2,4,8; per-cell = q_rise / k
PROFILES = {
    #                 q_rise(k=1)        q_rise(k=2)        q_rise(k=4)        q_rise(k=8)       worst asym
    "C24  behavioral": (np.array([-9.81950848796e-9, -1.96392851702e-8, -3.92780991656e-8, -7.85592301429e-8]), 7.0e-5),
    "V29  raw":        (np.array([-9.91058934063e-9, -1.97388593087e-8, -3.93943388453e-8, -7.86712433286e-8]), 9.3e-4),
    "V29C bleed":      (np.array([-9.87426219793e-9, -1.97069238625e-8, -3.93628428377e-8, -7.86383629900e-8]), 8.9e-5),
    "V29E bleed+caps": (np.array([-9.87788698004e-9, -1.97083423303e-8, -3.93595754082e-8, -7.86273773096e-8]), 1.2e-4),
    "V29G unit-cells":  (np.array([-9.88210044894e-9, -1.97626384344e-8, -3.95214155639e-8, -7.90371176649e-8]), 8.4e-5),
    "V29M scaled-dev":  (np.array([-9.87426219793e-9, -1.97482164672e-8, -3.95011765255e-8, -7.90371142360e-8]), 5.2e-5),
    "V29N scaled+20m":  (np.array([-9.87747710534e-9, -1.97546265112e-8, -3.95177054348e-8, -7.90787249600e-8]), 4.7e-5),
}

def make_qpc(qrise):
    qpc = qrise / K_MEAS
    slope = (qpc[-1] - qpc[-2]) / (K_MEAS[-1] - K_MEAS[-2])
    def fn(k):
        k = np.asarray(k, float)
        return np.where(k <= 8, np.interp(k, K_MEAS, qpc), qpc[-1] + slope * (k - 8))
    return fn

schemes = [
    run_constk(4, shape_par=True, greedy=True, g2=0.5, name="K=4 par+2nd g2=.5"),
    run_scheme("DWA classic", lambda c: c),
]

print("Replica-DAC option C: glitch SNDR (dB) through dem_study framework")
print(f"{'profile':<18}" + "".join(f"{n:>22}" for n, *_ in schemes))
for pname, (qrise, asym) in PROFILES.items():
    qfn = make_qpc(qrise)
    row = f"{pname:<18}"
    for name, y_mis, k, carr in schemes:
        dc = np.diff(carr, prepend=carr[0])
        e = glitch_err(qfn, k, dc, asym=asym)
        row += f"{err_sndr(carr + e):>22.1f}"
    print(row)

print()
print("per-cell q_pc flatness (max dev from k=8 value):")
for pname, (qrise, asym) in PROFILES.items():
    qpc = qrise / K_MEAS
    dev = np.max(np.abs(qpc - qpc[-1]) / np.abs(qpc[-1]))
    print(f"  {pname:<18} {dev*100:7.3f} %   worst asym = {asym:.1e}")
