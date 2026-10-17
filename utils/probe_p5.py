# Short (3 us) node-level probe of a patch_p5 plant: patches <src> -> tmp<dst>,
# runs LTspice, prints DC / ripple of the I/V nodes and the amp's differential
# input and output slew. Env passes through to patch_p5 (IVMODE, CCOL, CVF ...).
#   python probe_p5.py <src_tag> <dst_tag>
import os
import re
import subprocess
import sys
import numpy as np
sys.path.insert(0, os.path.dirname(__file__))
from read_ltraw import read_raw

LT = r"C:\Users\ccros\Documents\LTspice"
LTS = r"C:\Program Files\ADI\LTspice\LTspice.exe"
src, dst = sys.argv[1], "tmp" + sys.argv[2]
subprocess.run([sys.executable, os.path.join(os.path.dirname(__file__), "patch_p5.py"), src, dst], check=True)
p = os.path.join(LT, f"bfdac_cosim{dst}.cir")
s = open(p).read()
rload = os.environ.get("IVMODE", "tia") == "rload"
nodes = (["V(col_p)", "V(vf_p)", "V(out_d)", "V(diffout)", "V(inv_d)", "V(ninv_d)"] if rload else
         ["V(col_p)", "V(out_p)", "V(diffout)", "V(v_vg)"])
s = re.sub(r"\.tran 2n [0-9.]+u 0", ".tran 2n 3u 0", s)
s = re.sub(r"\.save V\(diffout\) V\(nsch\)", ".save " + " ".join(nodes), s)
open(p, "w").write(s)
subprocess.run([LTS, "-b", p], check=True)
n, d = read_raw(os.path.join(LT, f"bfdac_cosim{dst}.raw"))
t = d[0]; m = t > 1.5e-6; tt = t[m]
for k in nodes[:4]:
    x = d[n.index(k)][m]
    print(f"{k:12s} mean {x.mean():8.4f}  pp {x.max()-x.min():8.4f}")
if rload:
    e = (d[n.index("V(ninv_d)")] - d[n.index("V(inv_d)")])[m]
    o = d[n.index("V(out_d)")][m]
else:
    e = (d[n.index("V(v_vg)")] - d[n.index("V(col_p)")])[m]
    o = d[n.index("V(out_p)")][m]
print(f"amp diff input pp {1e3*(e.max()-e.min()):.2f} mV; output slew max "
      f"{np.abs(np.diff(o)/np.diff(tt)).max()/1e6:.1f} V/us")
for ext in (".cir", ".raw", ".log", ".op.raw", ".net"):
    try: os.remove(os.path.join(LT, f"bfdac_cosim{dst}{ext}"))
    except FileNotFoundError: pass
try: os.remove(os.path.join(LT, f"cosim{dst}_code.npy"))
except FileNotFoundError: pass
