# Round 38: MPN pass leg 1 - scan the LTspice vendor VDMOS library for real
# n-channel FETs meeting the Round 36 cascode requirement: low capacitance
# (Cgs <= ~35p), 100mA capable at sane Vov, Vds >= 20V.
import re

txt = open(r"C:\Users\ccros\AppData\Local\LTspice\lib\cmp\standard.mos",
           encoding="utf-16-le", errors="ignore").read()
rows = []
for m in re.finditer(r"\.model\s+(\S+)\s+VDMOS\(([^)]*)\)", txt):
    name, body = m.group(1), m.group(2)
    if "pchan" in body.lower():
        continue
    def g(k, d=None):
        mm = re.search(rf"\b{k}=([\d.eE+-]+)([pnum]?)", body, re.IGNORECASE)
        if not mm:
            return d
        return float(mm.group(1)) * {"p": 1e-12, "n": 1e-9, "u": 1e-6,
                                     "m": 1e-3, "": 1}[mm.group(2).lower()]
    cgs, cgd, kp = g("Cgs"), g("Cgdmax"), g("Kp")
    vds, ron, vto = g("Vds"), g("Ron"), g("Vto")
    mfg = re.search(r"mfg=(\S+)", body)
    if cgs is None or kp is None:
        continue
    vov = (0.2 / kp) ** 0.5
    if cgs <= 35e-12 and vov <= 3.0 and (vds or 0) >= 20:
        rows.append((cgs * 1e12, (cgd or 0) * 1e12, kp, vov, vds or 0,
                     vto, name, mfg.group(1) if mfg else "?"))
rows.sort()
print(f"{'CgspF':>6} {'CgdpF':>6} {'Kp':>7} {'Vov@.1A':>8} {'Vds':>5} "
      f"{'Vto':>5}  name (mfg)")
for r in rows[:30]:
    print(f"{r[0]:6.1f} {r[1]:6.1f} {r[2]:7.3f} {r[3]:8.2f} {r[4]:5.0f} "
          f"{r[5]:5.2f}  {r[6]} ({r[7]})")
print(f"{len(rows)} candidates")
