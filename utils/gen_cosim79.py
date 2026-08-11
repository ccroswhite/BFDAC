# N3: RAIL/REFERENCE NOISE injection. Gate-77 deck, differential.
# 79a: V_ref (cell-current reference, behind 100R+10uF = 159Hz pole) gets
#      1mV tones at 997Hz + 9973Hz.
# 79b: vcc15 (replica-FF source rail) gets 10mV of the same tones.
# Readout: tone amplitude at diffout + intermod sidebands around the 13.9k
# fund in pavg(79x)-pavg(77) -> V/V sensitivity per rail -> nV budget line
# from the actual regulator noise densities (bom).
import os

LT = r"C:\Users\ccros\Documents\LTspice"
F1, F2 = 997.0, 9973.0

src77 = open(os.path.join(LT, "bfdac_cosim77.cir")).read()

# replace each DC source with a B-source V = DC + tones
REPL = {
    "79a": ("V_ref   vref  0        DC 1.25",
            f"B_ref vref 0 V={{1.25 + 1m*sin(2*pi*{F1}*time) + 1m*sin(2*pi*{F2}*time)}}"),
    "79b": ("V_p15r  vcc15  0  DC 15",
            f"B_p15r vcc15 0 V={{15 + 10m*sin(2*pi*{F1}*time) + 10m*sin(2*pi*{F2}*time)}}"),
}

for tag, (old, new) in REPL.items():
    assert old in src77, old
    src = src77.replace(old, new)
    src = src.replace("v77", f"v{tag}")
    open(os.path.join(LT, f"bfdac_cosim{tag}.cir"), "w").write(src)
    print(f"{tag}: {new.split('=')[0].strip()} tone injection deck written")
