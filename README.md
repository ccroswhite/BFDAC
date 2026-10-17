# BFDAC

FPGA-controlled stereo discrete current-steering DAC on an Alinx ACVU13P/XCVU13P
SoM and a custom analog carrier.

## Engineering review: start here

[System Architecture and Engineering Review Specification](docs/SYSTEM_ARCHITECTURE.md)

This is the current system-level handoff document. It explains design intent,
FPGA implementation, analog conversion, power/grounding, PCB interfaces,
calibration, bring-up and verification evidence against a named Git baseline.
It includes **20 open review findings and explicit release gates**.

**The design is not manufacturing- or bitstream-release approved.** Known
RTL/schematic disagreements include I2S clock ownership, master-clock signaling
and family polarity. Sample-rate/watchdog behavior, real-cadence DPD deadlines,
SPI diagnostic gating, isolation and output protection also need review.
Passing unit tests or schematic ERC is not a complete system correctness proof.
Read the specification's open-findings section before relying on older notes.

## Supporting sources

- [BOM and circuit rationale](bom.md)
- [Requirements, decisions and historical evidence](progress.md)
- [SPI/coefficient formats and bring-up procedures](docs/coef_format_v2.md)
- [FPGA RTL](Xilinx) and [pin/timing constraints](Xilinx/vu13p_dac_top.xdc)
- [KiCad project](hw/kicad/bfdac_analog.kicad_pro) and [schematic generator](utils/gen_kicad.py)
- [Analog reference netlist](hw/ref_netlist.md)
- [Archived implementation plan](BFDAC_IMPLEMENTATION_PLAN.md) — historical, not a current architecture specification

For verification entry points and their limitations, see Section 11 of the
system specification. FPGA implementation and hardware qualification remain
separate from documentation and unit-test completion.