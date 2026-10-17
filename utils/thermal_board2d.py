# 2-D finite-difference thermal model of the tube-3 converter board coupled to
# an enclosure-wall node derived from geometry (simulated stand-in for the
# physical mock-up).  Transient: cold start, HP amp on at T_HP_ON, off at
# T_HP_OFF.  Dissipation inventory and tempco extrapolation as in
# utils/thermal_zones.py.  All geometry is parametric (env vars) because the
# enclosure and layout do not exist yet; the three enclosure cases bracket
# the wall-to-ambient figure.
#   python utils/thermal_board2d.py                 all three enclosure cases
#   CASE=anodised python utils/thermal_board2d.py   one case, prints the map
import os
import sys
import numpy as np
import scipy.sparse as sp
import scipy.sparse.linalg as spla

P = lambda k, d: float(os.environ.get(k, d))
SIGMA = 5.670e-8

# ---- board ---------------------------------------------------------------------
LX, LY = P("LX", 0.220), P("LY", 0.160)         # m, board outline
H = 0.002                                        # m, grid pitch
NX, NY = int(round(LX / H)), int(round(LY / H))
T_FR4 = 1.6e-3
K_FR4, K_CU = 0.3, 400.0
RHOC_FR4, RHOC_CU = 1850 * 1100, 8960 * 385      # J/m3K
CU_LAYERS = [70e-6, 70e-6, 35e-6, 35e-6]         # 2 oz planes x2, 1 oz signal x2
PLANE_FILL = 0.9                                 # copper fraction on planes inside a zone
GAP_FILL = 0.15                                  # copper fraction across isolation splits (req. 5)
GAP_W = 0.004                                    # m, split width
H_AIR = 6.0                                      # W/m2K, board faces to inner air (both faces)

# zone rectangles (x0, y0, x1, y1) in m.  W along the wall-coupled long edge,
# D along the far edge, A centred, T beside A.
Z = {
    "W": (0.0, 0.0, LX, 0.032),
    "D": (0.0, LY - 0.032, LX, LY),
    "A": (0.080, 0.050, 0.140, 0.110),
    "T": (0.150, 0.050, 0.200, 0.110),
}
# per-zone dissipation, W (stereo), from utils/thermal_zones.py inventory
PZ = {"W": 12.06, "D": 4.0, "T": 2.0}
# discrete hot spots in A (part, x, y, W) - static, code-independent
PARTS = [
    ("M6p", 0.098, 0.100, 0.09), ("M6m", 0.122, 0.100, 0.09),
    ("M5p", 0.098, 0.092, 0.09), ("M5m", 0.122, 0.092, 0.09),
    ("MRp", 0.104, 0.084, 0.10), ("MRm", 0.116, 0.084, 0.10),
    ("QR1p", 0.104, 0.076, 0.11), ("QR1m", 0.116, 0.076, 0.11),
    ("Mpadp", 0.090, 0.060, 0.10), ("Mpadm", 0.130, 0.060, 0.10),
]
P_CELLS = 0.29                                   # 128 cells spread over A
# wall coupling: W zone on a gap pad; four standoffs at the corners
R_PAD_AREA = 0.5 * (LX * 0.032)                  # K.m2/W  -> 0.5 K/W over the W strip
R_STANDOFF = 20.0                                # K/W each
STANDOFFS = [(0.006, 0.006), (LX - 0.006, 0.006), (0.006, LY - 0.006), (LX - 0.006, LY - 0.006)]

# ---- enclosure ------------------------------------------------------------------
TUBE = (P("TUBE_L", 0.30), P("TUBE_W", 0.14), P("TUBE_H", 0.07))   # m
CASES = {
    # emissivity, fin area multiplier, forced-convection h (0 = natural)
    "bare":     dict(eps=0.10, fin=1.0, h_forced=0.0),
    "anodised": dict(eps=0.85, fin=1.0, h_forced=0.0),
    "finned":   dict(eps=0.85, fin=2.5, h_forced=0.0),
}
C_WALL = P("C_WALL", 1350.0)                     # J/K
P_HP = P("P_HP", 22.0)
R_HP_WALL = 0.3

def r_wall_amb(case, T_wall_c, T_amb_c):
    L, W, Hh = TUBE
    area = 2 * (L * W + L * Hh + W * Hh)
    dT = max(T_wall_c - T_amb_c, 1.0)
    h_nat = 1.42 * (dT / Hh) ** 0.25 * 1.3        # vertical-plate correlation, +30 % for top/edges
    h = (case["h_forced"] or h_nat) * case["fin"]
    Tm = (T_wall_c + T_amb_c) / 2 + 273.15
    h_rad = case["eps"] * SIGMA * 4 * Tm ** 3     # radiation from the envelope only (fins see each other)
    return 1.0 / (h * area + h_rad * area / case["fin"] * 1.0)

# ---- grid properties -------------------------------------------------------------
xs = (np.arange(NX) + 0.5) * H
ys = (np.arange(NY) + 0.5) * H
XX, YY = np.meshgrid(xs, ys, indexing="ij")

def in_rect(r):
    return (XX >= r[0]) & (XX < r[2]) & (YY >= r[1]) & (YY < r[3])

zone_mask = {z: in_rect(r) for z, r in Z.items()}
fill = np.full((NX, NY), 0.6)                     # general routing area
for m in zone_mask.values():
    fill[m] = PLANE_FILL
# isolation splits around each zone perimeter
for r in Z.values():
    ring = in_rect((r[0] - GAP_W, r[1] - GAP_W, r[2] + GAP_W, r[3] + GAP_W)) & ~in_rect((r[0] + GAP_W, r[1] + GAP_W, r[2] - GAP_W, r[3] - GAP_W))
    fill[ring] = np.minimum(fill[ring], GAP_FILL)
kt = K_FR4 * T_FR4 + K_CU * fill * sum(CU_LAYERS)            # W/K per square
cap = (RHOC_FR4 * T_FR4 + RHOC_CU * fill * sum(CU_LAYERS)) * H * H   # J/K per cell

# ---- sources ------------------------------------------------------------------------
Q = np.zeros((NX, NY))
for z, p in PZ.items():
    m = zone_mask[z]; Q[m] += p / m.sum()
Q[zone_mask["A"]] += P_CELLS / zone_mask["A"].sum()
part_idx = {}
for name, x, y, p in PARTS:
    i, j = int(x / H), int(y / H)
    Q[i, j] += p; part_idx[name] = (i, j)

# ---- conductance matrix: board cells + wall node (index N) ---------------------------
N = NX * NY
idx = lambda i, j: i * NY + j
rows, cols, vals = [], [], []
def add(a, b, g):
    rows.extend([a, b, a, b]); cols.extend([a, b, b, a]); vals.extend([g, g, -g, -g])
for i in range(NX):
    for j in range(NY):
        a = idx(i, j)
        if i + 1 < NX:
            add(a, idx(i + 1, j), 2 * kt[i, j] * kt[i + 1, j] / (kt[i, j] + kt[i + 1, j]))
        if j + 1 < NY:
            add(a, idx(i, j + 1), 2 * kt[i, j] * kt[i, j + 1] / (kt[i, j] + kt[i, j + 1]))
# board faces to inner air (air ~ wall temperature)
g_air = 2 * H_AIR * H * H
for i in range(NX):
    for j in range(NY):
        add(idx(i, j), N, g_air)
# W strip on gap pad
for i in range(NX):
    for j in range(NY):
        if zone_mask["W"][i, j]:
            add(idx(i, j), N, H * H / R_PAD_AREA)
for x, y in STANDOFFS:
    add(idx(int(x / H), int(y / H)), N, 1 / R_STANDOFF)
G0 = sp.csr_matrix((vals, (rows, cols)), shape=(N + 1, N + 1))
Cvec = np.append(cap.ravel(), C_WALL)
Qvec = np.append(Q.ravel(), 0.0)

# ---- transient -------------------------------------------------------------------------
T_AMB = P("T_AMB", 25.0)
DT = 10.0
T_END, T_HP_ON, T_HP_OFF = 4 * 3600, 2 * 3600, 3 * 3600

def run(case_name, verbose=True):
    case = CASES[case_name]
    T = np.full(N + 1, T_AMB)
    log = []
    t = 0.0
    Rwa_prev = None; lu = None
    while t < T_END:
        hp = T_HP_ON <= t < T_HP_OFF
        Rwa = r_wall_amb(case, T[N], T_AMB)
        if lu is None or abs(Rwa - Rwa_prev) / Rwa > 0.02:
            G = G0.tolil(); G[N, N] += 1 / Rwa
            A = (sp.diags(Cvec / DT) + G.tocsr()).tocsc()
            lu = spla.splu(A); Rwa_prev = Rwa
        q = Qvec.copy(); q[N] += T_AMB / Rwa
        if hp:  # HP amp heat: into the wall through its heatsink (heatsink node eliminated: P flows to wall)
            q[N] += P_HP
        T = lu.solve(Cvec / DT * T + q)
        t += DT
        if int(t) % 60 == 0:
            Tb = T[:N].reshape(NX, NY)
            log.append((t, T[N], Rwa, Tb[zone_mask["W"]].mean(), Tb[zone_mask["A"]].mean(),
                        Tb[zone_mask["D"]].mean(), Tb[zone_mask["T"]].mean(),
                        {k: Tb[i, j] for k, (i, j) in part_idx.items()},
                        Tb[zone_mask["A"]].max() - Tb[zone_mask["A"]].min()))
    return log, T[:N].reshape(NX, NY)

def at(log, t):
    return min(log, key=lambda r: abs(r[0] - t))

def report(case_name):
    log, Tb = run(case_name)
    ss = at(log, T_HP_ON - 60); hp = at(log, T_HP_OFF - 60); off = at(log, T_END - 60)
    print(f"\n=== case '{case_name}': tube {TUBE[0]*1e3:.0f}x{TUBE[1]*1e3:.0f}x{TUBE[2]*1e3:.0f} mm, "
          f"eps {CASES[case_name]['eps']}, fin x{CASES[case_name]['fin']}, R_wall_amb at line-out = {ss[2]:.2f} K/W ===")
    print("  state           wall     W      A      D      T   | A gradient | M6p   MRp   QR1p  Mpadp")
    for name, r in (("line-out ss", ss), ("HP on ss", hp), ("HP off +60min", off)):
        p = r[7]
        print(f"  {name:14s} {r[1]:6.1f} {r[3]:6.1f} {r[4]:6.1f} {r[5]:6.1f} {r[6]:6.1f} |   {r[8]:5.1f} K   "
              f"| {p['M6p']:5.1f} {p['MRp']:5.1f} {p['QR1p']:5.1f} {p['Mpadp']:5.1f}")
    dA_hp = hp[4] - ss[4]
    # warm-up: time for A to come within 1 K of its line-out steady state
    t1 = next((r[0] for r in log if r[0] < T_HP_ON and abs(r[4] - ss[4]) < 1.0), None)
    # HP step: time for A to move 1 K after HP on, and to settle within 1 K of HP ss
    tstep = next((r[0] for r in log if r[0] >= T_HP_ON and r[4] - ss[4] > 1.0), None)
    tsettle = next((r[0] for r in log if r[0] >= T_HP_ON and abs(r[4] - hp[4]) < 1.0), None)
    print(f"  array A: line-out {ss[4]:.1f} C, HP step +{dA_hp:.1f} K, warm-up to 1 K {t1/60 if t1 else float('nan'):.0f} min, "
          f"HP step 1 K after {((tstep - T_HP_ON)/60) if tstep else float('nan'):.0f} min, settled after {((tsettle - T_HP_ON)/60) if tsettle else float('nan'):.0f} min")
    print(f"  replica-vs-target spreads in A (static): M6p-MRp {ss[7]['M6p']-ss[7]['MRp']:+.1f} K, M5p-MRp {ss[7]['M5p']-ss[7]['MRp']:+.1f} K, "
          f"QR1p-cells(A mean) {ss[7]['QR1p']-ss[4]:+.1f} K; change of M5p-MRp over the HP step {(hp[7]['M5p']-hp[7]['MRp'])-(ss[7]['M5p']-ss[7]['MRp']):+.2f} K")
    # extrapolation (sweep slopes, see thermal_zones.py)
    def hd(base, new, pct_applied, pct):
        add = 10 * np.log10(10 ** (new / 10) - 10 ** (base / 10)) + 20 * np.log10(pct / pct_applied)
        return 10 * np.log10(10 ** (base / 10) + 10 ** (add / 10))
    for label, d in (("HP-enable step", dA_hp), ("5 K ambient", 5.0)):
        c2 = 2e-3 * d / 4.37 * 100; ve = 2e-3 * d / 7.2 * 100; vf = 0.3e-3 * d / 1.75 * 100
        print(f"  drift @ {label} ({d:.1f} K): CASB2-fixed HD4 {hd(-132.3,-128.5,1,c2):6.1f} | QR1 Veb HD3 {hd(-134.6,-121.5,1,ve):6.1f} | MR/M5 HD2 {hd(-128.5,-120.9,1,vf):6.1f} dBc")
    np.save(os.path.join(os.path.dirname(__file__), f"thermal_board2d_{case_name}.npy"), Tb)
    return Tb

def ascii_map(Tb, step=4):
    lo, hi = Tb.min(), Tb.max(); ramp = " .:-=+*#%@"
    print(f"\n  board map at end (HP off +60 min), {lo:.1f}..{hi:.1f} C, x -> (wall edge at bottom)")
    for j in range(NY - 1, -1, -step):
        print("  " + "".join(ramp[min(int((Tb[i, j] - lo) / (hi - lo + 1e-9) * len(ramp)), len(ramp) - 1)] for i in range(0, NX, step // 2)))

if __name__ == "__main__":
    print(f"board {LX*1e3:.0f}x{LY*1e3:.0f} mm, {NX}x{NY} cells; copper {sum(CU_LAYERS)*1e6:.0f} um total, plane fill {PLANE_FILL}, split fill {GAP_FILL}; T_amb {T_AMB} C")
    print(f"in-plane conductance: zone {K_CU*PLANE_FILL*sum(CU_LAYERS):.3f} W/K/sq, split {K_CU*GAP_FILL*sum(CU_LAYERS):.3f} W/K/sq")
    only = os.environ.get("CASE")
    for c in ([only] if only else CASES):
        Tb = report(c)
        if only:
            ascii_map(Tb)
