# BFDAC

BFDAC is a high-performance stereo DAC built around an Alinx ACVU13P/XCVU13P
SoM and a discrete current-steering analog carrier. The application processor
supplies PCM audio; the FPGA owns audio timing and conversion processing;
externally reclocked current cells and I/V stages produce balanced XLR outputs.

## Design documentation

Start with the [System Design Specification](docs/SYSTEM_ARCHITECTURE.md).
It explains the product goals, complete system, component responsibilities,
audio and clock flows, power architecture, planned physical arrangement,
operating sequences, calibration and manual bring-up.

Use the [Implementation Review and Gap Analysis](docs/IMPLEMENTATION_REVIEW.md)
alongside it to assess the implementation. That companion preserves the audit
evidence, findings R01–R20 and qualification gates against their named baselines.
It is separate from the description of the intended system.

The [control/coefficient protocol](docs/coef_format_v2.md) contains the detailed
register, image-layout and host-operation contracts.

## Hardware and implementation sources

- [BOM and circuit realization](bom.md)
- [KiCad project](hw/kicad/bfdac_analog.kicad_pro) and [schematic generator](utils/gen_kicad.py)
- [Analog reference netlist](hw/ref_netlist.md)
- [FPGA RTL](Xilinx) and [pin/timing constraints](Xilinx/vu13p_dac_top.xdc)
- [Decision and verification history](progress.md)
- [Archived implementation plan](BFDAC_IMPLEMENTATION_PLAN.md)

**PCB layout has not started.** The SoM connector seed is a mechanical
reference for later layout. FPGA implementation and physical qualification
are also distinct from unit-test or documentation completion; their evidence
and remaining work are tracked in the review companion.