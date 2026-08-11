# Round 44: SLOW-BIAS configuration, full honest pipeline.
# Circuit change (board-realistic): C_q4 22n->10u, 10u on casb/casb2, cbus
# 47n->470n. All bias memories pushed to tau >= 1ms (below audio band): bias
# state freezes at the run average, identical in LUT measurement and in
# operation. 43d already showed HD2 -92.4 -> -101.9 from C_q4 alone WITHOUT
# refreshing the LUT; this round re-derives the LUT for the full slow-bias
# deck. Emits: bfdac_cosim44lut.cir (chopped) and bfdac_cosim44.cir (gate).
import os

OUT = r"C:\Users\ccros\Documents\LTspice"

def slow_bias(src):
    # C_q4 only: tau 2.2us -> 1ms freezes q4_base at the run average.
    # (cbus 470n / casb 10u variants broke statics and settling - Round 43e/44a.)
    return src.replace("C_q4 q4_base 0 22n", "C_q4 q4_base 0 10u")

# chopped LUT deck: gen_cosim40.py shuf must run FIRST (shuffled schedule
# so the ~1ms bias tau sees a stationary average, not a code-correlated ramp)
src = slow_bias(open(os.path.join(OUT, "bfdac_cosim44lut.cir")).read())
src = src.replace("* BFDAC CO-SIM v40 - FULL 64-code INL LUT, Si1555 cascode",
                  "* BFDAC CO-SIM v44lut - 64-code INL LUT, SLOW-BIAS, shuffled")
with open(os.path.join(OUT, "bfdac_cosim44lut.cir"), "w") as f:
    f.write(src)

# FFT gate deck from v39 (pwl dir patched after vectors exist)
src = slow_bias(open(os.path.join(OUT, "bfdac_cosim39.cir")).read())
src = src.replace("* BFDAC CO-SIM v39 - FFT GATE, REAL Si1555DL_N cascode",
                  "* BFDAC CO-SIM v44 - FFT GATE, SLOW-BIAS deck, predistorted")
src = src.replace("pwl37", "pwl44")
with open(os.path.join(OUT, "bfdac_cosim44.cir"), "w") as f:
    f.write(src)
print("bfdac_cosim44lut.cir + bfdac_cosim44.cir written")
