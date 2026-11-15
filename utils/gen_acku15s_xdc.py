#!/usr/bin/env python3
"""ACKU15S-2: regenerate acku15s_dac_top.xdc pin assignments for XCKU15P-2FFVE1517I.

Sources of truth:
  datasheets/acku15s_pinmap_proposal.csv  - connector-routed signals (audited map)
  datasheets/_acku15s_manual.txt          - DDR4/QSPI/clock tables (SoM fixed pins)
  datasheets/_ku15p_pkgpins.csv           - KU15P IO-name -> package-pin lookup

NOTE: the manual's printed DDR4 pin-number column is misaligned at page breaks
(the PDF extraction drops cells).  IO names are reliable and unique, so every
DDR4 signal is resolved through the package-pin CSV, NOT the printed column.

The XDC's timing/CDC/pblock content is preserved; only PACKAGE_PIN lines and
the DDR4/cascode pin blocks are rewritten, plus targeted text updates.
"""
import csv
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
XDC = ROOT / "Xilinx" / "acku15s_dac_top.xdc"
PINMAP = ROOT / "datasheets" / "acku15s_pinmap_proposal.csv"
PKG = ROOT / "datasheets" / "_ku15p_pkgpins.csv"
MANUAL = ROOT / "datasheets" / "_acku15s_manual.txt"


def load_sources():
    pins = {}  # port token (as in get_ports) -> (pkg_pin, comment)

    for row in csv.DictReader(PINMAP.open()):
        pins[row["port"]] = (
            row["fpga_pin"],
            f"{row['som_sig']} {row['conn']}-{row['jpin']}",
        )

    io2pin = {r["pin_func"]: r["pin"] for r in csv.DictReader(PKG.open())}
    sig2io = {}
    for line in MANUAL.open(errors="replace"):
        m = re.match(r"\s*(DDR4_\S+)\s+(IO_\S+)", line)
        if m:
            sig2io[m.group(1)] = m.group(2)

    ddr4 = {}  # top-level port token -> (pin, SoM signal name)
    for sig, io in sig2io.items():
        pin = io2pin[io]
        s = sig[5:]  # drop DDR4_
        if re.fullmatch(r"D\d+", s):
            port = f"ddr4_dq[{s[1:]}]"
        elif re.fullmatch(r"DQS\d+_[PN]", s):
            n, pol = s[:-2], s[-1]
            port = f"ddr4_dqs_{'t' if pol == 'P' else 'c'}[{n[3:]}]"
        elif re.fullmatch(r"DM\d+", s):
            port = f"ddr4_dm_dbi_n[{s[2:]}]"
        elif re.fullmatch(r"A\d+", s):
            port = f"ddr4_addr[{s[1:]}]"
        else:
            port = {
                "WE_B": "ddr4_addr[14]", "CAS_B": "ddr4_addr[15]",
                "RAS_B": "ddr4_addr[16]", "BA0": "ddr4_ba[0]",
                "BA1": "ddr4_ba[1]", "BG0": "ddr4_bg[0]",
                "ACT_B": "ddr4_act_n", "CS_B": "ddr4_cs_n[0]",
                "CKE": "ddr4_cke[0]", "OTD": "ddr4_odt[0]",
                "RST": "ddr4_reset_n", "CLK_P": "ddr4_ck_t[0]",
                "CLK_N": "ddr4_ck_c[0]", "CLKREF_P": "ddr4_clkref_p",
                "CLKREF_N": "ddr4_clkref_n",
            }.get(s)
            if port is None:
                continue  # ALERT_B, PAR - no top-level ports
        ddr4[port] = (pin, sig)

    fixed = {
        "clk_200m_p": ("G12", "IO_L5P_HDGC_94 SoM 200 MHz osc"),
        "clk_200m_n": ("G11", "IO_L5N_HDGC_94 SoM 200 MHz osc"),
        "qspi1_cs_n": ("AV11", "IO_L2N_T0L_N3_FWE_FCS2_B_65 SoM QSPI1"),
        "qspi1_dq[0]": ("AM12", "IO_L22P_T3U_N6_DBC_AD0P_D04_65 SoM QSPI1"),
        "qspi1_dq[1]": ("AN12", "IO_L22N_T3U_N7_DBC_AD0N_D05_65 SoM QSPI1"),
        "qspi1_dq[2]": ("AR13", "IO_L21P_T3L_N4_AD8P_D06_65 SoM QSPI1"),
        "qspi1_dq[3]": ("AR12", "IO_L21N_T3L_N5_AD8N_D07_65 SoM QSPI1"),
    }
    return pins, ddr4, fixed


def fmt(pin, comment, port_expr, width=45):
    base = f"set_property PACKAGE_PIN {pin:<5} [get_ports {port_expr}]"
    return f"{base:<{width}};# {comment}"


def main():
    pins, ddr4, fixed = load_sources()
    lines = XDC.read_text(encoding="utf-8").splitlines()

    # ---- locate the cascode pin block and the DDR4 section -------------------
    cas_i = [i for i, l in enumerate(lines)
             if "PACKAGE_PIN" in l and "cascode_" in l]
    ddr4_i = [i for i, l in enumerate(lines)
              if "PACKAGE_PIN" in l and "ddr4_" in l]
    cas_lo, cas_hi = min(cas_i), max(cas_i)
    ddr4_lo, ddr4_hi = min(ddr4_i), max(ddr4_i)
    assert cas_hi < ddr4_lo

    # ---- regenerate cascode block (128 pins, J4 col-mirrored) ----------------
    cas_block = []
    for ch in "lr":
        for i in range(64):
            pin, cmt = pins[f"cascode_{ch}[{i}]"]
            cas_block.append(
                fmt(pin, cmt, f"{{cascode_{ch}[{i}]}}"))
        cas_block.append("")

    # ---- regenerate DDR4 block ------------------------------------------------
    def d(port):
        pin, sig = ddr4[port]
        return fmt(pin, f"{sig} (fixed SoM)", f"{{{port}}}" if "[" in port else port)

    dd = [d("ddr4_clkref_p"), d("ddr4_clkref_n"), ""]
    for i in range(17):
        dd.append(d(f"ddr4_addr[{i}]"))
    dd += ["", d("ddr4_ba[0]"), d("ddr4_ba[1]"), d("ddr4_bg[0]"),
           d("ddr4_act_n"), d("ddr4_cs_n[0]"), d("ddr4_cke[0]"),
           d("ddr4_odt[0]"), d("ddr4_reset_n"), d("ddr4_ck_t[0]"),
           d("ddr4_ck_c[0]"), ""]
    for byte in range(8):
        dd.append(f"# Byte {byte} (bank {66 if byte < 4 else 68 if byte < 8 else 67})")
        for i in range(byte * 8, byte * 8 + 8):
            dd.append(d(f"ddr4_dq[{i}]"))
        dd += [d(f"ddr4_dqs_t[{byte}]"), d(f"ddr4_dqs_c[{byte}]"),
               d(f"ddr4_dm_dbi_n[{byte}]")]
    dd_block = dd

    # ---- scalar-pin replacement pass -----------------------------------------
    seen = set()
    out = []
    i = 0
    while i < len(lines):
        l = lines[i]
        if i == cas_lo:
            out.extend(cas_block)
            i = cas_hi + 1
            continue
        if i == ddr4_lo:
            out.extend(dd_block)
            i = ddr4_hi + 1
            continue
        m = re.search(
            r"set_property PACKAGE_PIN\s+(\S+)\s+\[get_ports\s+\{?([A-Za-z_0-9]+(?:\[\d+\])?)\}?\]",
            l)
        if m:
            port = m.group(2)
            for table in (pins, fixed, ddr4):
                if port in table:
                    pin, cmt = table[port]
                    l = fmt(pin, cmt, f"{{{port}}}" if "[" in port else port)
                    seen.add(port)
                    break
            else:
                print(f"WARN: no pin for port {port}")
        out.append(l)
        i += 1

    # ---- insert missing pin lines (ports auto-placed on the VU13P dev build) --
    ap_pin_lines = [
        fmt(pins["spi_ap_sclk"][0], pins["spi_ap_sclk"][1], "spi_ap_sclk"),
        fmt(pins["spi_ap_cs_n"][0], pins["spi_ap_cs_n"][1], "spi_ap_cs_n"),
        fmt(pins["spi_ap_mosi"][0], pins["spi_ap_mosi"][1], "spi_ap_mosi"),
        fmt(pins["spi_ap_miso"][0], pins["spi_ap_miso"][1], "spi_ap_miso"),
        fmt(pins["spi_ap_irq_n"][0], pins["spi_ap_irq_n"][1], "spi_ap_irq_n"),
    ]
    for idx, l in enumerate(out):
        if "spi_ap_sclk" in l and "PACKAGE_PIN" in l:
            break  # already inserted
        if "set_false_path -from [get_ports {spi_ap_sclk" in l:
            out[idx:idx] = ap_pin_lines
            break

    text = "\n".join(out) + "\n"

    # ---- targeted textual fixups ----------------------------------------------
    repl = [
        # header
        ("""# *** PENDING (ACKU15S-2): all PACKAGE_PIN / bank assignments below are still
# *** the VU13P-era values. Rewrite from datasheets/acku15s_pinmap_proposal.csv
# *** (cascode col-mirrored J4 69/70/71, mclk B94_L6 GC, clk_200m B94_L5,
# *** control J1 banks 90/91, cf flash J2 bank 65, qspi1 fixed SoM pins,
# *** LVCMOS18 throughout, cascode DRIVE=8).""",
         """# Pin assignments regenerated by utils/gen_acku15s_xdc.py (ACKU15S-2):
#   connector signals <- datasheets/acku15s_pinmap_proposal.csv
#   DDR4/QSPI/clocks  <- ACKU15S V1.0 manual tables (fixed SoM pins,
#                      IO-name resolved via _ku15p_pkgpins.csv; the manual's
#                      printed pin column is misaligned at page breaks)
#   cascode col-mirrored J4 banks 69/70/71, control J1 banks 90/91,
#   cf flash J2 bank 65, qspi1 fixed SoM pins, LVCMOS18, cascode DRIVE=8."""),

        # clk_200m section
        ("""# 200 MHz SOM system clock (differential) -- drives SPI control plane (clk_200m domain)
# Uses C1_DDR4_CLKREF on bank 73 GC pins (C1 DDR4 controller unused).
# C0_DDR4_CLKREF (AD33/AE33) remains dedicated to C0 MIG on banks 61/62/63.""",
         """# 200 MHz SOM system clock (differential) -- drives SPI control plane (clk_200m domain).
# SoM oscillator on B94_L5_P/N = G12/G11 (HDGC, fixed on-module; not connector-routed)."""),

        # mclk comment
        ("""# Bank 65 TRUE GC pair B65_L12 (J6-C30/C29) - moved from B71_L12 (J1-A17/A16,
# J28/J29) on 2026-10-08: the clock block sits on the analog/right edge next to
# J6, J1 is the noisy/left edge. Carrier drives mclk_p single-ended LVCMOS18
# and leaves mclk_n reserved/no-connect. RTL uses IBUF on mclk_p.""",
         """# GC pair B94_L6 (J4-B4/B3) on the FF end of the connector row: the carrier
# clock block faces the analog/FF side. Carrier drives mclk_p single-ended
# LVCMOS18 and leaves mclk_n reserved/no-connect. RTL uses IBUF on mclk_p."""),

        # clk_sel comment
        ("""# Quasi-static control output; B65_L16_P (J6-A19) since 2026-10-08 (was
# B71_L13_P / J26, J1-B5) - same move as mclk, drives the XO enables in the
# clock block on the analog edge.""",
         """# Quasi-static control output; J1-A1 on the AP-facing end, drives the
# XO enables in the carrier clock block."""),

        # XMOS SPI comment
        ("# J1 connector, bank 71 single-ended pins",
         """# J1 rows A7-A11, bank 90 (AP-facing connector end).
# SPI_XMOS_* via U501 MAX22445C isolation on the carrier ctrl sheet."""),

        # AP SPI comment
        ("""# 4b. SPI Control Bus — AP port (host AP SPI master, isolated on ACKU15S carrier)
#     VU13P dev build: no dedicated carrier pins — auto-placed.""",
         """# 4b. SPI Control Bus — AP port (host AP SPI master, J1 rows A17-A22 bank 91).
#     Isolated via U509 MAX22445C + U513 MAX22445F on the carrier ctrl sheet."""),

        # ext_rst comment
        ("""# 5b. External reset from the application processor (through the ISO7710 on the
#     carrier control sheet, 2026-10-07): bank 71 B71_L2_N = J1 pin A1.""",
         """# 5b. External reset from the application processor through isolation on the
#     carrier control sheet: J1-B11, bank 90."""),

        # i2s comment
        ("""# J1 bank 71. BCLK/LRCLK are outputs; DATA is sampled with a qualified delay.
# R27 (B71_L2_N, J1-A1) = ext_rst_n (5b).
# H28 (B71_L11_N, J1-B16) = i2s_data2: second AP-domain source (host app
# processor) via U503 ch2; selected by i2s_src_sel (SPI reg 0x1C bit 5).""",
         """# J1 rows A2-A6, bank 90. BCLK/LRCLK are outputs; DATA is sampled with a
# qualified delay.
# i2s_data2 (J1-A6): second AP-domain source (host app processor) via U503
# ch2; selected by i2s_src_sel (SPI reg 0x1C bit 5)."""),

        # led_status
        ("""# BC33 is in bank 61, which the SOM powers at VCCO=1.2 V for DDR4 (C0).
set_property IOSTANDARD LVCMOS12 [get_ports led_status]""",
         """# ACKU15S: led_status exits to the carrier on J1-B4 (bank 90, 1.8 V).
set_property IOSTANDARD LVCMOS18 [get_ports led_status]"""),

        ("""# Board-level debug LEDs on J1 (B71_L18/L10, verified free in connector CSV)
# [3]=clk_locked [2]=ddr4_calib_done [1]=i2s_err [0]=force_zero""",
         """# Board-level debug LEDs on J1-B6..B9 (bank 90)
# [3]=clk_locked [2]=ddr4_calib_done [1]=i2s_err [0]=force_zero"""),

        # qspi1 section header
        ("""# 11. QSPI Flash 1 (coefficient storage, bank 65)
#     Flash 0 uses dedicated config pins (CCLK/FCS_B/D00-D03) via STARTUPE3.
#     Flash 1 directly accessible as user I/O on bank 65.""",
         """# 11. QSPI Flash 1 (coefficient storage)
#     Flash 0 uses dedicated config pins (CCLK/FCS_B/D00-D03) via STARTUPE3.
#     Flash 1 is wired on-SoM to fixed bank-65 pins (MT25QU512ABB1EW9)."""),

        # cf section header
        ("""# 11b. Carrier coefficient flash (bom item 18b, Macronix selection)
#      Four MX66UM2G45GXRI00 2-Gb devices on one x1 SPI bus, bank 70 (J1,
#      VCCIO_70 = V18). All four CS populated. Engine rate: clk_200m/2 =
#      100 MHz x1 SPI (CF_CKDIV_LOG2 = 1).""",
         """# 11b. Carrier coefficient flash (bom item 18b, Macronix selection)
#      Four MX66UM2G45GXRI00 2-Gb devices on one x1 SPI bus, bank 65 (J2,
#      AP-facing end, VCCIO_65 = V18). All four CS populated. Engine rate:
#      clk_200m/2 = 100 MHz x1 SPI (CF_CKDIV_LOG2 = 1)."""),

        # cascode section tail comment (bank description)
        ("""# Package pins: banks 64+65 = LEFT channel (J6), banks 67+66 = RIGHT channel
# (J5 + J6). cascode_r[48..63] moved from bank 69 (J1, the carrier's noisy
# left edge) to bank 66 L15-L21/L24 (J6, analog edge) on 2026-10-08.""",
         """# Package pins: J4 (FF-facing end), column-mirrored -- cascode_l on cols
# A/B, cascode_r on cols C/D, bit-for-bit row mirrored (L[2i]/L[2i+1] at row N
# mirrors R[2i]/R[2i+1] at row N) so carrier trace lengths are symmetric.
# L: banks 71/70/69, R: banks 71/70/69 (same VCCIO via J3)."""),

        # DDR4 section header
        ("""# 9. DDR4 Interface
# C0 controller pin LOCs from "ACVU13P FPGA Onboard Part Pin Assignment -
# DDR4 Modules.csv" (Alinx SOM). 64-bit config: bytes 0-7 (D0-D63).
# Bytes 8/9 (D64-D79, DQS8/9, DM8/9 -- the SOM's 5th x16 device) are
# UNCONNECTED: DDR4 MIG maxes at 72-bit, we run 64-bit (2026-08-11 note).
# IOSTANDARD / DCI / output impedance are set by the ddr4_0 IP (PG150);
# only PACKAGE_PIN is constrained here.
# addr[16:14] carry RAS/CAS/WE per DDR4 command encoding: A14=WE_B,
# A15=CAS_B, A16=RAS_B.""",
         """# 9. DDR4 Interface
# ACKU15S SoM: 4x NT5AD512M16C4-HR, 64-bit non-ECC, banks 66-68, 2666 Mbps,
# ref clk AR32/AT32. Pins from the SoM manual DDR4 table, IO-name resolved
# via _ku15p_pkgpins.csv (printed pin column in the manual is misaligned at
# page breaks). ALERT_B (AK34) and PAR (AV32) are routed on the SoM but not
# used by this non-ECC controller config. SoM 5th x16 chip (D64-79,
# DQS8/9, DM8/9 on bank 67) is unconnected: Xilinx MIG caps DataWidth at
# 72 (64+ECC), 80-bit non-ECC unsupported; option (a) ruled 2026-11-14.
# IOSTANDARD / DCI / output impedance are set by the ddr4_0 IP (PG150);
# only PACKAGE_PIN is constrained here.
# addr[16:14] carry RAS/CAS/WE per DDR4 command encoding: [14]=WE_B,
# [15]=CAS_B, [16]=RAS_B (dedicated SoM pins, not part of the A0-A13 bus)."""),

        # SLR floorplan: KU15P is monolithic, drop SLR pblocks
        ("""# -----------------------------------------------------------------------------
# 12. Stage-1A SLR Floorplan (post-route timing closure, 8.39M-tap build)
#
# Post-route analysis showed ~14.5k dsp_clk paths at ~-0.5 ns dominated by the
# s3 broadcast tree (cap/clr/we/addr) fanning across the die, plus ~487 SLL
# crossings of the SLR0/SLR1 boundary.  Each stereo channel fits inside one
# SLR (~400 BRAM tiles, 364 DSPs), and the coefficient URAM banks are now
# duplicated per channel (gen_ch[0]/gen_ch[1]) so the 2,304-wire URAM->DSP_B
# bus never crosses the interposer.
#
# SLR1 owns the cascode_l outputs (Banks 64/65); SLR2 owns cascode_r
# (Banks 66/67) and was nearly empty.  SLR0 stays open for the DDR4 MIG
# (Banks 61-63), u_boot_loader, and u_coef_subsys.
# -----------------------------------------------------------------------------
create_pblock pb_stereo_fir_l
add_cells_to_pblock pb_stereo_fir_l \\
    [get_cells {u_dsp_core/u_stereo_fir/u_l_fir \\
                u_dsp_core/u_stereo_fir/gen_ch[0].gen_uram_coef[*].u_uram}]
resize_pblock pb_stereo_fir_l -add {SLR1}

create_pblock pb_stereo_fir_r
add_cells_to_pblock pb_stereo_fir_r \\
    [get_cells {u_dsp_core/u_stereo_fir/u_r_fir \\
                u_dsp_core/u_stereo_fir/gen_ch[1].gen_uram_coef[*].u_uram}]
resize_pblock pb_stereo_fir_r -add {SLR2}""",
         """# -----------------------------------------------------------------------------
# 12. Stage-1A floorplan
#
# NOTE (ACKU15S-2): the VU13P SLR pblocks were removed -- XCKU15P is a
# monolithic die (single SLR), there are no SLL crossings to manage. The
# 8.39M-build SLR partition rationale (pb_stereo_fir_l/r on SLR1/SLR2) does
# not apply. If the first KU15P route congests, revisit with clock-region
# pblocks instead. The reset-relaxation constraints below are retained."""),
    ]

    for old, new in repl:
        if old not in text:
            print(f"WARN: fixup block not found: {old[:70]!r}...")
        text = text.replace(old, new, 1)

    XDC.write_text(text, encoding="utf-8", newline="\n")
    print(f"OK: {XDC.name} rewritten; {len(seen)} scalar pins + "
          f"{len(cas_block)} cascode + {len(dd_block)} DDR4 lines")


if __name__ == "__main__":
    sys.exit(main())
