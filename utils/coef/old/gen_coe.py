# gen_coe.py  —  LEGACY / RETIRED
#
# This script targeted the original Artix-7 systolic architecture
# (81x upsample, 128 DSP slices, 64 BRAM shard .mem files).
# That architecture has been superseded by the XCVU13P URAM design.
#
# USE gen_coe_super.py FOR ALL NEW WORK:
#
#   Legacy BRAM shards (.mem):
#     python gen_coe_super.py --method chord-dave --fs_in 48000
#
#   1M-tap QSPI binary (.bin):
#     python gen_coe_super.py --architecture 1m-folded --method chord-dave --fs_in 48000
#
#   URAM loader format (.txt, for XCVU13P simulation and hardware):
#     python gen_coe_super.py --architecture uram --method chord-dave --fs_in 48000
#     python gen_coe_super.py --architecture uram --method dcs-f1 --fs_in 48000
#     python gen_coe_super.py --architecture uram --method msb-reference --fs_in 48000
#     python gen_coe_super.py --architecture uram --method berkeley --fs_in 48000
#     python gen_coe_super.py --architecture uram --method merason --fs_in 48000
#     python gen_coe_super.py --architecture uram --method dcs-f2 --fs_in 48000
#
# Named DAC Personas supported in gen_coe_super.py:
#   chord-dave    Chord DAVE         — Linear Phase Brick-Wall, Kaiser beta=14
#   dcs-f1        dCS Vivaldi F1     — Slow Roll-Off, Kaiser beta=8
#   dcs-f2        dCS Vivaldi F2     — Extended Bandwidth to 25 kHz
#   msb-reference MSB Reference      — Minimum Phase, Hann window
#   berkeley      Berkeley Alpha 3   — Apodising FIRLS + Blackman-Harris
#   merason       Merason            — PCM1794A Burr-Brown Warmth, Kaiser beta=11
#   nagra         Nagra              — Swiss Precision, Kaiser beta=9
#   hybrid        Hybrid Phase       — 60% min-phase + 40% linear
#
# This file is kept for reference only. Do not use for new designs.

import sys
print("gen_coe.py is retired. Please use gen_coe_super.py instead.")
print("See header comments for usage examples.")
sys.exit(0)