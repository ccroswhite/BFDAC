"""Generate the KiCad schematic for the locked BFDAC analog channel from
hw/ref_netlist.json.

Output (hw/kicad/):
  bfdac_analog.kicad_pro   project
  bfdac_analog.kicad_sch   root: 64x CELL sheets + CORE + IV + REFS
  cell.kicad_sch           one current cell (drawn once, instanced 64x)
  core.kicad_sch           cascode / replica-ff / padding / bus / reference
  iv.kicad_sch             P5 TIA, both rails
  refs.kicad_sch           rail & reference table (realisation per bom 9)
  refmap.json              deck element -> KiCad ref/pins (for xcheck)

Wiring style: every pin gets a 2.54 mm stub and a label; shared nets are
global labels, per-cell interface nets are hierarchical pins.  This is a
netlist-correct capture meant for review + layout hand-off; cosmetic
re-arrangement is done in eeschema afterwards.
"""
import json, os, re, uuid, sys
from copy import deepcopy

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
REF = os.path.join(ROOT, "hw", "ref_netlist.json")
OUT = os.path.join(ROOT, "hw", "kicad")
LIBDIR = r"C:\Program Files\KiCad\10.0\share\kicad\symbols"
LOCALLIB = "bfdac"          # project library hw/kicad/bfdac.kicad_sym (THAT300)
PROJECT = "bfdac_analog"
VERSION = "20250114"

# ---------------------------------------------------------------- s-expr
def tokenize(s):
    for m in re.finditer(r'"(?:[^"\\]|\\.)*"|\(|\)|[^\s()]+', s):
        yield m.group(0)

def parse(tokens):
    stack = [[]]
    for t in tokens:
        if t == "(":
            stack.append([])
        elif t == ")":
            n = stack.pop(); stack[-1].append(n)
        else:
            stack[-1].append(t)
    return stack[0]

def dump(node, ind=0):
    if isinstance(node, str):
        return node
    if all(isinstance(c, str) for c in node):
        return "(" + " ".join(node) + ")"
    out = "(" + " ".join(c for c in node if isinstance(c, str))
    kids = [c for c in node if not isinstance(c, str)]
    # keep leading atoms first, then children on new lines
    parts = []
    for c in node:
        if isinstance(c, str):
            continue
        parts.append("\n" + "\t" * (ind + 1) + dump(c, ind + 1))
    return out + "".join(parts) + "\n" + "\t" * ind + ")"

_libcache = {}
def lib(libname):
    if libname not in _libcache:
        d = OUT if libname == LOCALLIB else LIBDIR
        with open(os.path.join(d, libname + ".kicad_sym"), encoding="utf-8") as f:
            _libcache[libname] = parse(tokenize(f.read()))[0]
    return _libcache[libname]

# THAT300 SO-14 pinout (datasheet 600041 Rev 04 Fig. 1, confirmed 2026-09-28):
# 1 C1, 2 B1, 3 E1, 4 SUB, 5 E3, 6 B3, 7 C3, 8 C4, 9 B4, 10 E4, 11 SUB, 12 E2, 13 B2, 14 C2
THAT300_PINS = {1: ("1", "2", "3"), 2: ("14", "13", "12"), 3: ("7", "6", "5"), 4: ("8", "9", "10")}  # (C, B, E)
THAT300_SUB = ("4", "11")
# Si1555DL SOT-363 (Vishay 71079 top view): 1 S1, 2 G1, 3 D2, 4 S2, 5 G2, 6 D1; device 1 = N, 2 = P
SI1555_N = {"S": "1", "G": "2", "D": "6"}
SI1555_P = {"D": "3", "S": "4", "G": "5"}
# 2SA1036K SMT3 / SC-59 (Rohm, confirmed by user 2026-09-28): 1 E, 2 B, 3 C
SA1036_PINS = {"E": "1", "B": "2", "C": "3"}

def _unit_from_device(name, unit, devlibid, pinnums, suffix=""):
    """One unit body: graphics copied from a Device symbol, pins re-numbered.
    pinnums: {device pin name: package pin number}."""
    dev, pins = get_symbol(devlibid)
    devname = devlibid.split(":")[1]
    gfx = [c for c in dev if isinstance(c, list) and c[0] == "symbol" and c[1] == '"%s_0_1"' % devname][0]
    body = "".join("\n\t\t" + dump(c, 2) for c in gfx[2:])
    kinds = {"B": "input", "G": "input"}
    for p in pins:
        body += ('\n\t\t(pin %s line (at %g %g %d) (length 2.54) (name "%s" %s) (number "%s" %s))'
                 % (kinds.get(p["name"], "passive"), p["x"], p["y"], int(p["ang"]), p["name"] + suffix, FONT,
                    pinnums[p["name"]], FONT))
    return '\n\t(symbol "%s_%d_1"%s\n\t)' % (name, unit, body)

def _pin(kind, x, y, ang, name, num):
    return ('\n\t\t(pin %s line (at %g %g %d) (length 2.54) (name "%s" %s) (number "%s" %s))'
            % (kind, x, y, ang, name, FONT, num, FONT))

def _box_unit(name, unit, left, right, width=None):
    """Rectangle body with pins stacked on the left/right at 2.54 pitch.
    left/right: lists of (number, name, kind); kind = KiCad electrical type."""
    n = max(len(left), len(right), 1)
    h = snap(2.54 * (n + 1))
    w = width or 20.32
    body = ('\n\t\t(rectangle (start %g %g) (end %g %g) (stroke (width 0.254) (type default)) (fill (type background)))'
            % (-w / 2, h / 2, w / 2, -h / 2))
    for i, (num, nm, kind) in enumerate(left):
        body += _pin(kind, -w / 2 - 2.54, h / 2 - 2.54 * (i + 1), 0, nm, num)
    for i, (num, nm, kind) in enumerate(right):
        body += _pin(kind, w / 2 + 2.54, h / 2 - 2.54 * (i + 1), 180, nm, num)
    return '\n\t(symbol "%s_%d_1"%s\n\t)' % (name, unit, body)

# --- Alinx ACVU13P carrier side: Samtec ADM6-60-01.5-L-4-2-A-TR, 4 rows x 60 = 240 pins
ALINX_CSV = os.path.join(ROOT, "Alinx", "ACVU13P-Pin-Assignment-20260703.csv")
CASCODE_XDC = os.path.join(ROOT, "Alinx", "cascode_pins_gen.txt")

def alinx_connectors():
    """{connector: {pin: (signal, fpga_pin)}} from the Alinx pin-assignment CSV."""
    import csv
    J = {}
    conn = None
    for r in csv.reader(open(ALINX_CSV, encoding="utf-8-sig")):
        if r and r[0].startswith("Connector"):
            conn = r[0].split()[1]; J[conn] = {}; continue
        if len(r) >= 3 and conn and r[0] not in ("Pin", ""):
            J[conn][r[0]] = (r[1].strip(), r[2].strip())
    return J

def cascode_map(chan="l"):
    """{index: bank signal name} for cascode_<chan>[i] from the XDC fragment."""
    m = {}
    for line in open(CASCODE_XDC):
        mm = re.search(r"PACKAGE_PIN (\w+)\s+\[get_ports \{cascode_(\w)\[(\d+)\]\}\]\s*;#\s*(\S+)", line)
        if mm and mm.group(2) == chan:
            m[int(mm.group(3))] = mm.group(4)
    return m

def _is_gnd(sig):
    return sig.replace(" ", "") == "GND"

def _alinx_symbol(name, pins, used):
    """240-pin connector as 4 units (rows A..D).  `used` = {pin: netname-ish label};
    GND pins are passive, other unused pins are electrical type no_connect so
    ERC stays quiet while the footprint keeps all 240 pads."""
    units = ""
    for u, row in enumerate("ABCD"):
        col = []
        for k in range(1, 61):
            p = "%s%d" % (row, k)
            sig = pins[p][0]
            if p in used:
                col.append((p, used[p], "passive"))
            elif _is_gnd(sig):
                col.append((p, "GND", "passive"))
            else:
                col.append((p, sig.replace(" ", "") or "NC", "no_connect"))
        units += _box_unit(name, u + 1, col[:30], col[30:], width=45.72)
    return units

# Control-plane IOs on J1 bank 71 (MUST match vu13p_dac_top.xdc s4-s7, s10, 5b).  {Alinx signal: label}
CTRL_PINS = {
    "B71_L3_P": "SPI_SCLK", "B71_L3_N": "SPI_CS_N", "B71_L15_P": "SPI_MOSI", "B71_L15_N": "SPI_MISO",   # T26 R26 H29 G29
    "B71_L5_P": "FPGA_IRQ_N", "B71_L2_N": "EXT_RST_N",                                                  # P28 R27
    "B71_L11_P": "I2S_BCLK", "B71_L2_P": "I2S_LRCLK", "B71_L5_N": "I2S_DATA",                           # H27 T27 N28
    "B71_L1_N": "RLY_LINE_MUTE",                                                                    # R28; RLY_LEVEL0/1 (P26/N29) STRUCK 2026-10-07: level is digital (bom 7 ruling), RTL ports remain -> no-connect
    "B71_L4_N": "PG_ALL",                                                                           # J1-B7 / N29: wired-AND rail power-good -> FPGA (bom 17(m), LVCMOS18; xdc port TBD)
    "B71_L18_N": "LED_DBG0", "B71_L18_P": "LED_DBG1", "B71_L10_N": "LED_DBG2", "B71_L10_P": "LED_DBG3",  # D28 E28 K27 K26
}
CTRL_PINS.update({"B71_L7_P": "TEST_SELECT_N", "B71_L7_N": "TEST_STEP_N", "B71_L8_P": "TEST_LED"})
JTAG_PINS = {"FPGA_TCK": "JTAG_TCK", "FPGA_TMS": "JTAG_TMS", "FPGA_TDI": "JTAG_TDI", "FPGA_TDO": "JTAG_TDO"}

def alinx_used():
    """(J, {connector: {pin: label}}) - every electrically live carrier pin on the eight
    ACVU13P connectors.  Shared by the symbol library and the sheets so they agree."""
    J = alinx_connectors()
    s2p = {c: {v[0].replace(" ", ""): p for p, v in J[c].items()} for c in J}
    used = {c: {} for c in J}
    for i, s in cascode_map("l").items():
        used["J6"][s2p["J6"][s]] = "DAT%02d" % (i + 1)
    for i, s in cascode_map("r").items():   # bank 67 on J5, bank 66 on J6 (cascode_r[48..63] moved off J1 bank 69 2026-10-08)
        c = "J5" if s in s2p["J5"] else "J6"
        assert s in s2p[c], ("cascode_r pin not on J5/J6 (analog edge)", i, s)
        used[c][s2p[c][s]] = "DATR%02d" % (i + 1)
    # 2026-10-08 layout ruling: clock block sits on the analog/right side next to J6 -> its FPGA pins moved off J1 (left/noisy
    # edge) to J6 bank 65.  MCLK on the true GC pair B65_L12 (AW28/AY28); _N reserved (no-connect) for an LVDS option.
    used["J6"][s2p["J6"]["B65_L12_P"]] = "MCLK_FPGA"      # J6-C30 / AW28  (was J1-A17 B71_L12_P / J28)
    used["J6"][s2p["J6"]["B65_L16_P"]] = "CLK_SEL"        # J6-A19 / AR25  (was J1-B5  B71_L13_P / J26)
    used["J1"].update({s2p["J1"][s]: n for s, n in CFLASH_PINS.items()})
    used["J1"].update({s2p["J1"][s]: n for s, n in CTRL_PINS.items()})
    used["J6"].update({s2p["J6"][s]: n for s, n in JTAG_PINS.items()})
    used["J6"][s2p["J6"]["VCCAUX_PG"]] = "SOM_PG"
    used["J2"][s2p["J2"]["VUP_SELECTMAP_DONE"]] = "FPGA_DONE"   # configuration DONE -> OUT sheet unmute gate (bom 7)
    used["J5"][s2p["J5"]["FPGA_VP_IN"]] = "FPGA_VP_IN"
    used["J5"][s2p["J5"]["FPGA_VN_IN"]] = "FPGA_VN_IN"
    for k in range(3):
        used["J2"][s2p["J2"]["BOOT_M%d" % k if k else "BOOT_MO"]] = "BOOT_M%d" % k   # CSV spells M0 with the letter O
    for c in J:
        for p, (s, f) in J[c].items():
            s = s.replace(" ", "")
            if s.startswith("VCCIO_"):
                used[c][p] = s
            elif s == "+12V":
                used[c][p] = "+12V"
    return J, used

def conn_nets(J, used, c, G, GND):
    """Per-pin nets for connector c: labels -> global nets, GND -> GND, rest no-connect (symbol etype)."""
    nets = {}
    for p, (s, f) in J[c].items():
        if p in used[c]:
            lab = used[c][p]
            if lab.startswith("CF_"):
                nets[p] = ("L", lab)
            elif lab.startswith("DAT"):
                nets[p] = G(lab + "_1V8")      # LVCMOS18 leg -> XLAT sheet (SN74AXC8T245) -> DATnn at 3.3 V -> cell D
            elif lab.startswith("VCCIO_"):
                nets[p] = G("v18")
            elif lab == "+12V":
                nets[p] = G("v12som")
            elif lab in ("FPGA_VP_IN", "FPGA_VN_IN"):
                nets[p] = GND
            else:
                nets[p] = G(lab)
        elif _is_gnd(s):
            nets[p] = GND
    return nets

ALINX_DESCR = {
    "J1": "banks 69/70/71 - coefficient-flash QSPI (bom 18a), control plane (SPI/I2S/IRQ/reset/relays/LEDs); mclk/clk_sel and cascode_r[48..63] moved to J6 2026-10-08 (noisy/left edge keeps digital only)",
    "J2": "+12 V module supply (52 pins) + SelectMAP (unused) + BOOT_M0..2 mode straps",
    "J3": "MGT quads 230-233 - unused, all no-connect; GND tied",
    "J4": "MGT quads 224/227/228/229 - unused, all no-connect; GND tied",
    "J5": "banks 66/67/68 - cascode_r[0..47] (bank 67), VCCIO_66/67/68, SYSMON VP/VN (tied to GND), MGT 225/226 unused",
    "J6": "banks 64/65/66 - cascode_l data (64/65), cascode_r[48..63] (bank 66 L15-L21/L24), mclk (B65_L12_P GC, LVCMOS18), clk_sel (B65_L16_P), JTAG (FPGA_TCK/TMS/TDI/TDO), VCCAUX_PG, VCCIO_65_EX",
    "J7": "MGT quads 125-128 - unused, all no-connect; GND tied",
    "J8": "MGT quads 129/130/131/133 - unused, all no-connect; GND tied",
}

def _sym(name, units_body, footprint, datasheet, descr, ref="Q"):
    prop = lambda k, v, hide: '\n\t(property "%s" "%s" (at 0 0 0) %s%s)' % (k, v, "(hide yes) " if hide else "", FONT)
    return ('\n(symbol "%s" (pin_names (offset 0) (hide yes)) (exclude_from_sim no) (in_bom yes) (on_board yes)' % name
            + prop("Reference", ref, False) + prop("Value", name, False)
            + prop("Footprint", footprint, True) + prop("Datasheet", datasheet, True)
            + prop("Description", descr, True) + units_body + "\n\t(embedded_fonts no)\n)")

def write_local_lib():
    """hw/kicad/bfdac.kicad_sym: package-true symbols not in the KiCad libs."""
    # THAT300: units 1-4 = Q1..Q4 (NPN), unit 5 = substrate pins
    that = "".join(_unit_from_device("THAT300", u, "Device:Q_NPN", dict(zip("CBE", THAT300_PINS[u])), str(u))
                   for u in THAT300_PINS)
    that += ('\n\t(symbol "THAT300_5_1"\n\t\t(rectangle (start -2.54 2.54) (end 2.54 -2.54) (stroke (width 0.254) (type default)) (fill (type background)))'
             + _pin("passive", -5.08, 0, 0, "SUB", THAT300_SUB[0]) + _pin("passive", 5.08, 0, 180, "SUB", THAT300_SUB[1]) + '\n\t)')
    # Si1555DL: unit 1 = N half, unit 2 = P half
    si = (_unit_from_device("Si1555DL", 1, "Device:Q_NMOS", SI1555_N)
          + _unit_from_device("Si1555DL", 2, "Device:Q_PMOS", SI1555_P))
    sa = _unit_from_device("2SA1036K", 1, "Device:Q_PNP", SA1036_PINS)
    # TI REF70 (SNAS781 rev G, Table 6-1, identical for FKH LCCC-8 and DGK VSSOP-8): 1 EN 2 VIN 3 GND 4 GND 5 GND 6 OUTS 7 OUTF 8 GND
    ref70 = _box_unit("REF7050", 1,
                      [("2", "VIN", "power_in"), ("1", "EN", "input"), ("3", "GND", "power_in"), ("4", "GND", "passive"),
                       ("5", "GND", "passive"), ("8", "GND", "passive")],
                      [("7", "OUTF", "power_out"), ("6", "OUTS", "input")])
    # LMK1C1108 TSSOP-16 (SNAS814A pin functions): 1 CLKIN 2 1G 3 Y0 4 GND 5 VDD 6 Y4 7 GND 8 Y6 9 Y7 10 VDD 11 Y5 12 GND 13 Y2 14 VDD 15 Y3 16 Y1
    lmk1c = _box_unit("LMK1C1108", 1,
                      [("1", "CLKIN", "input"), ("2", "1G", "input"), ("5", "VDD", "power_in"), ("10", "VDD", "power_in"),
                       ("14", "VDD", "power_in"), ("4", "GND", "power_in"), ("7", "GND", "power_in"), ("12", "GND", "power_in")],
                      [("3", "Y0", "output"), ("16", "Y1", "output"), ("13", "Y2", "output"), ("15", "Y3", "output"),
                       ("6", "Y4", "output"), ("11", "Y5", "output"), ("8", "Y6", "output"), ("9", "Y7", "output")])
    # Crystek CCHD-957 (9x14 mm, 4 pads): 1 E/D, 2 GND, 3 OUT, 4 Vcc  - VERIFIED datasheet Rev N p.2 (pad table); E/D open or >= 0.7 Vcc = active, <= 0.3 Vcc = High Z, -350 uA max pin-1 disable current
    xo = _box_unit("CCHD-957", 1, [("1", "E/D", "input"), ("2", "GND", "power_in")], [("3", "OUT", "output"), ("4", "Vcc", "power_in")])
    # Micron MT25QU02GCBB8E12 24-ball T-PBGA 5x5, package code 12 - VERIFIED mt25q-qlkt-U02-CBB-S-IT Rev C Fig. 4 (page rendered):
    # A4 RESET# (pin config 8 = dedicated RESET# with internal pull-up + HOLD# shared on D4), B2 C, B3 VSS, B4 VCC, C2 S#,
    # C4 W#/DQ2, D2 DQ1, D3 DQ0, D4 HOLD#/DQ3; all other balls DNU.  The from-memory map had RESET# on B4 (= VCC) and VCC on
    # C3 (= DNU) - the flash would have been unpowered.  Fixed 2026-10-08.
    qf = _box_unit("MT25QU02G", 1,
                   [("C2", "S#", "input"), ("B2", "C", "input"), ("A4", "RESET#", "input"),
                    ("B4", "VCC", "power_in"), ("B3", "VSS", "power_in")],
                   [("D3", "DQ0", "bidirectional"), ("D2", "DQ1", "bidirectional"),
                    ("C4", "DQ2", "bidirectional"), ("D4", "DQ3", "bidirectional")])
    # Alinx module connectors (carrier side): all eight, only the live pins are electrically connected
    J, used = alinx_used()
    jsyms = "".join(_sym("ACVU13P_%s" % c, _alinx_symbol("ACVU13P_%s" % c, J[c], used[c]), "", "https://www.samtec.com/products/adm6",
                         "Alinx ACVU13P module connector %s (carrier: Samtec ADM6-60-01.5-L-4-2-A-TR); %s" % (c, ALINX_DESCR[c]), ref="J")
                    for c in sorted(J))
    # ADI/Maxim MAX22445 (W SOIC-16, 3 forward A->B + 1 reverse B->A): 1 VDDA 2 GNDA 3 IN1 4 IN2 5 IN3 6 OUT4 7 ENA 8 GNDA | 9 GNDB 10 ENB 11 IN4 12 OUT3 13 OUT2 14 OUT1 15 GNDB 16 VDDB
    # - VERIFIED 2026-10-10 against the datasheet pin-configuration figure (user) and the ADI KiCad symbol (datasheets/MAX22445FAWE_/KiCADv6); pin-for-pin the ISO7741 layout
    max22445 = _box_unit("MAX22445", 1,
                         [("1", "VDDA", "power_in"), ("3", "IN1", "input"), ("4", "IN2", "input"), ("5", "IN3", "input"),
                          ("6", "OUT4", "output"), ("7", "ENA", "input"), ("2", "GNDA", "power_in"), ("8", "GNDAB", "passive")],
                         [("16", "VDDB", "power_in"), ("14", "OUT1", "output"), ("13", "OUT2", "output"), ("12", "OUT3", "output"),
                          ("11", "IN4", "input"), ("10", "ENB", "input"), ("9", "GNDB", "power_in"), ("15", "GNDBB", "passive")])
    # ADI/Maxim MAX22444 (W SOIC-16, 4 forward A->B): 1 VDDA 2 GNDA 3 IN1 4 IN2 5 IN3 6 IN4 7 I.C. 8 GNDA | 9 GNDB 10 ENB 11 OUT4 12 OUT3 13 OUT2 14 OUT1 15 GNDB 16 VDDB
    # - VERIFIED 2026-10-10 (same figure). No ENA on this variant; pin 7 I.C. = "leave unconnected or connect to GNDA or VDDA" (pin description, user 2026-10-10) -> tied to GNDA
    max22444 = _box_unit("MAX22444", 1,
                         [("1", "VDDA", "power_in"), ("3", "IN1", "input"), ("4", "IN2", "input"), ("5", "IN3", "input"),
                          ("6", "IN4", "input"), ("7", "IC", "passive"), ("2", "GNDA", "power_in"), ("8", "GNDAB", "passive")],
                         [("16", "VDDB", "power_in"), ("14", "OUT1", "output"), ("13", "OUT2", "output"), ("12", "OUT3", "output"),
                          ("11", "OUT4", "output"), ("10", "ENB", "input"), ("9", "GNDB", "power_in"), ("15", "GNDBB", "passive")])
    # TI ISO1640 (SOIC-8 D, bidirectional I2C) - VERIFIED SLLSFC2D Table 5-1: 1 VCC1 2 SDA1 3 SCL1 4 GND1 | 5 GND2 6 SCL2 7 SDA2 8 VCC2.
    # ("ISO1610" does not exist - TI 404; ISO1640 is the part.)  VCC1 3.0-5.5 V, VCC2 2.25-5.5 V (sec 6.3) - no 1.8 V side.
    iso1640 = _box_unit("ISO1640", 1,
                        [("1", "VCC1", "power_in"), ("2", "SDA1", "bidirectional"), ("3", "SCL1", "bidirectional"), ("4", "GND1", "power_in")],
                        [("8", "VCC2", "power_in"), ("7", "SDA2", "bidirectional"), ("6", "SCL2", "bidirectional"), ("5", "GND2", "power_in")])
    # TI SN74AXC8T245 RHL/RGY VQFN-24 (3.5 x 5.5, 0.5 mm) - VERIFIED 2026-10-10 against the datasheet Figure 4-2 pin-configuration figure (user):
    # 1 VCCA 2 DIR1 3-10 A1..A8 11 DIR2 12 GND 13 GND 14-21 B8..B1 22 /OE 23 VCCB 24 VCCB 25 PAD (ground recommended).
    # NOTE: the TI/UL KiCad symbol in datasheets/CAXC8T245QWRGYRQ1 labels pin 23 "VCCA" - the figure and the pin-function table say VCCB; the figure wins.
    axc8 = _box_unit("SN74AXC8T245", 1,
                     [("1", "VCCA", "power_in"), ("2", "DIR1", "input"), ("11", "DIR2", "input")]
                     + [(str(2 + i), "A%d" % i, "bidirectional") for i in range(1, 9)]
                     + [("12", "GND", "power_in"), ("13", "GND", "passive"), ("25", "PAD", "passive")],
                     [("24", "VCCB", "power_in"), ("23", "VCCB", "passive"), ("22", "~{OE}", "input")]
                     + [(str(22 - i), "B%d" % i, "bidirectional") for i in range(1, 9)])
    # TI TMP117 (WSON-6 DRV): 1 SCL 2 GND 3 ALERT 4 ADD0 5 V+ 6 SDA  - VERIFIED SNOSD82D (thermal pad floating)
    tmp117 = _box_unit("TMP117", 1,
                       [("5", "V+", "power_in"), ("1", "SCL", "input"), ("6", "SDA", "bidirectional"), ("2", "GND", "power_in")],
                       [("4", "ADD0", "input"), ("3", "ALERT", "open_collector")])
    # ADI ADP7158 (LFCSP-10, CP-10-9) - VERIFIED datasheet Rev C Table 6 / Fig. pinout 2026-10-12:
    # 1/2 VOUT, 3 VOUT_SENSE, 4 BYP, 5 EN, 6 REF_SENSE, 7 REF, 8 VREG, 9/10 VIN, EPAD 11 = GND.
    adp7158 = _box_unit("ADP7158", 1,
                        [("9", "VIN", "power_in"), ("10", "VIN", "passive"), ("8", "VREG", "power_in"),
                         ("5", "EN", "input"), ("4", "BYP", "passive")],
                        [("1", "VOUT", "power_out"), ("2", "VOUT", "passive"), ("3", "VOUT_SENSE", "input"),
                         ("6", "REF_SENSE", "input"), ("7", "REF", "passive"), ("11", "EP", "power_in")])
    # TI TPS3890 supervisor (DSE WSON-6 1.5x1.5) - VERIFIED SBVS227 pin table 2026-10-12:
    # 1 SENSE 2 GND 3 MR 4 VDD 5 CT 6 RESET(open-drain).  Adjustable variant VITN/VITP = 1.15 V
    # (the "400 mV reference" in the 17(m) notes was wrong - SENSE divider re-scaled to suit).
    tps3890 = _box_unit("TPS3890", 1,
                        [("4", "VDD", "power_in"), ("3", "MR", "input"), ("5", "CT", "passive")],
                        [("1", "SENSE", "input"), ("6", "RESET", "open_collector"), ("2", "GND", "power_in")])
    # TI UCD90120A (RGC VQFN-64 + EP) - pin map VERIFIED SLVSAN9C Table "Pin Functions" 2026-10-12.
    # Unit 1 = everything wired (13 MON, PMBus, straps, supplies, JTAG); unit 2 = unused GPIO/PWM/NC pins
    # (placed once as a stub so every package pin is accounted for).  MON1-9 are 0-2.5 V; MON10-13 are
    # 0.2-2.5 V, so negative-rail sense networks go on MON7/8/9.  Pin 58 = V33FB (3.3 V supply feedback).
    NC = "no_connect"
    ucd_l = ([(str(i), "MON%d" % i, "input") for i in range(1, 7)]
             + [("59", "MON7", "input"), ("62", "MON8", "input"), ("63", "MON9", "input"),
                ("50", "MON10", "input"), ("52", "MON11", "input"), ("54", "MON12", "input"), ("56", "MON13", "input")]
             + [("9", "RESET", "input"), ("10", "TRCK", "input")]
             + [("49", "AVSS1", "power_in"), ("48", "AVSS2", "power_in"), ("64", "AVSS3", "power_in"),
                ("8", "DVSS1", "power_in"), ("26", "DVSS2", "power_in"), ("43", "DVSS3", "power_in"), ("65", "EP", "power_in")])
    ucd_r = ([("15", "PMBUS_CLK", "bidirectional"), ("16", "PMBUS_DATA", "bidirectional"),
              ("27", "PMBALERT", "open_collector"), ("28", "PMBUS_CNTRL", "input"),
              ("61", "PMBUS_ADDR0", "input"), ("60", "PMBUS_ADDR1", "input")]
             + [("7", "V33DIO1", "power_in"), ("44", "V33DIO2", "power_in"), ("45", "V33D", "power_in"),
                ("46", "V33A", "power_in"), ("47", "BPCAP", "passive"), ("58", "V33FB", "passive")]
             + [("40", "TRST", "input"), ("36", "TCK", NC), ("37", "TDO", NC), ("38", "TDI", "input"), ("39", "TMS", "input")])
    ucd2 = ([(str(p), n, NC) for p, n in
             ((11, "GPIO1"), (12, "GPIO2"), (13, "GPIO3"), (14, "GPIO4"), (17, "FPWM1/GPIO5"), (18, "FPWM2/GPIO6"),
              (19, "FPWM3/GPIO7"), (20, "FPWM4/GPIO8"), (21, "FPWM5/GPIO9"), (22, "FPWM6/GPIO10"),
              (23, "FPWM7/GPIO11"), (24, "FPWM8/GPIO12"), (25, "GPIO13"), (29, "GPIO14"), (30, "GPIO15"))]
             + [(str(p), n, NC) for p, n in ((51, "NC1"), (53, "NC2"), (55, "NC3"), (57, "NC4"))])
    ucd2r = [(str(p), n, NC) for p, n in
             ((31, "PWM1/GPI1"), (32, "PWM2/GPI2"), (33, "GPIO16"), (34, "GPIO17"), (35, "GPIO18"),
              (41, "PWM4/GPI4"), (42, "PWM3/GPI3"))]
    ucd = _box_unit("UCD90120A", 1, ucd_l, ucd_r, width=25.4) + _box_unit("UCD90120A", 2, ucd2, ucd2r, width=25.4)
    out = ('(kicad_symbol_lib (version %s) (generator "gen_kicad") (generator_version "9.0")' % VERSION
           + jsyms
           + _sym("MAX22445", max22445, FP["ADI_WSOIC16"], "https://www.analog.com/media/en/technical-documentation/data-sheets/max22444-max22446.pdf",
                  "ADI MAX22445 quad digital isolator 3/1, 200 Mbps (50 Mbps characterised at VDD 1.8 V), 1.71-5.5 V per side, W SOIC-16 (bom 21, ruled 2026-10-09); pin map verified 2026-10-10", ref="U")
           + _sym("MAX22444", max22444, FP["ADI_WSOIC16"], "https://www.analog.com/media/en/technical-documentation/data-sheets/max22444-max22446.pdf",
                  "ADI MAX22444 quad digital isolator 4/0, 1.71-5.5 V per side, W SOIC-16 (bom 21: AP reset -> FPGA + 3 spare); pin map verified 2026-10-10", ref="U")
           + _sym("SN74AXC8T245", axc8, FP["TI_RGY24"], "https://www.ti.com/lit/ds/symlink/sn74axc8t245.pdf",
                  "TI SN74AXC8T245 octal 0.65-3.6 V dual-supply translator, VQFN-24 RHL (3.5x5.5, 0.5 mm, EP) - user ruling 2026-10-10 (VQFN over TSSOP); DIR1/DIR2 high = A->B; pin map verified against datasheet Fig. 4-2 2026-10-10", ref="U")
           + _sym("ISO1640", iso1640, FP["SOIC8"], "https://www.ti.com/lit/ds/symlink/iso1640.pdf",
                  "TI ISO1640 bidirectional I2C isolator, SOIC-8 D (bom 20); pin map verified SLLSFC2D 2026-10-08. Supply: side 1 3.0-5.5 V, side 2 2.25-5.5 V (NOT 1.8 V capable)", ref="U")
           + _sym("TMP117", tmp117, FP["WSON6"], "https://www.ti.com/lit/ds/symlink/tmp117.pdf",
                  "TI TMP117 +-0.1 C I2C temperature sensor, WSON-6 (bom 20); ADD0 strap selects 0x48..0x4B; pin map verified SNOSD82D 2026-10-08; thermal pad NOT connected internally - leave unsoldered on rigid PCB for best accuracy (datasheet)", ref="U")
           + _sym("LMK1C1108", lmk1c, FP["TSSOP16"], "https://www.ti.com/lit/ds/symlink/lmk1c1108.pdf",
                  "TI 1:8 LVCMOS clock fanout, 20 fs additive, TSSOP-16", ref="U")
           + _sym("CCHD-957", xo, FP["CCHD957"], "https://www.crystek.com/crystal/spec-sheets/clock/CCHD-957.pdf",
                  "Crystek CCHD-957 ultra-low phase noise HCMOS XO, 9x14 mm, 3.3 V +-0.3, 15 mA typ, 15 pF load, floor -169 dBc/Hz typ; pin map + footprint verified Rev N 2026-10-08", ref="Y")
           + _sym("MT25QU02G", qf, FP["TPBGA24"], "https://www.micron.com/products/nor-flash/serial-nor-flash/part-catalog/mt25qu02gcbb8e12-0sit",
                  "Micron 2 Gb 1.8 V quad SPI NOR, 24-ball T-PBGA 5x5 6x8 mm (package code 12); 4 on one bus = 8 Gb coefficient store (bom 18/18a); ball map + footprint verified Rev C 2026-10-08", ref="U")
           + _sym("THAT300", that, FP["SOIC14"], "https://thatcorp.com/datashts/THAT_300-Series_Datasheet.pdf",
                  "THAT 300 quad matched NPN array, SO-14; units 1-4 = Q1..Q4, unit 5 = substrate pins 4/11")
           + _sym("Si1555DL", si, FP["SOT363"], "https://www.vishay.com/docs/71079/si1555dl.pdf",
                  "Vishay complementary N+P MOSFET pair, SOT-363; unit 1 = N half (S1 G1 D1 = 1 2 6), unit 2 = P half (D2 S2 G2 = 3 4 5)")
           + _sym("2SA1036K", sa, FP["SC59"], "https://fscdn.rohm.com/en/products/databook/datasheet/discrete/transistor/bipolar/2sa1036kt146q-e.pdf",
                  "Rohm PNP -32 V 0.5 A, SMT3/SC-59: 1 E, 2 B, 3 C")
           + _sym("REF7050", ref70, FP["LCC8"], "https://www.ti.com/lit/ds/symlink/ref70.pdf",
                  "TI REF7050 5.000 V precision reference, LCCC-8 (FKH) / VSSOP-8 (DGK) same pinout: 1 EN 2 VIN 3/4/5/8 GND 6 OUTS 7 OUTF", ref="U")
           + _sym("ADP7158", adp7158, FP["ADI_LFCSP10"], "https://www.analog.com/media/en/technical-documentation/data-sheets/adp7158.pdf",
                  "ADI ADP7158 2 A ultralow-noise RF LDO, LFCSP-10 (CP-10-9); pin map verified Rev C 2026-10-12; VREG/EN to VIN, REF_SENSE to REF, BYP/REF 1 uF each (bom 17(l), V33FF rail)", ref="U")
           + _sym("TPS3890", tps3890, FP["TI_DSE6"], "https://www.ti.com/lit/ds/symlink/tps3890.pdf",
                  "TI TPS389001 adjustable supervisor, DSE WSON-6 1.5x1.5; VITN 1.15 V on SENSE; RESET open-drain; pin map verified SBVS227 2026-10-12 ** VERIFY EP/footprint **", ref="U")
           + _sym("UCD90120A", ucd, FP["TI_RGC64"], "https://www.ti.com/lit/ds/symlink/ucd90120a.pdf",
                  "TI UCD90120A 13-input PMBus rail monitor + sequencer, VQFN-64 RGC 9x9; telemetry only (NOT mute path) - bom 17(m2)/(m3); pin map verified SLVSAN9C 2026-10-12 ** VERIFY footprint EP dims **", ref="U")
           + "\n)\n")
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, LOCALLIB + ".kicad_sym"), "w", encoding="utf-8") as f:
        f.write(out)
    with open(os.path.join(OUT, "sym-lib-table"), "w", encoding="utf-8") as f:
        f.write('(sym_lib_table\n  (version 7)\n  (lib (name "%s")(type "KiCad")(uri "${KIPRJMOD}/%s.kicad_sym")(options "")(descr "BFDAC project symbols"))\n)\n'
                % (LOCALLIB, LOCALLIB))
    _libcache.pop(LOCALLIB, None)

def write_local_footprints():
    """hw/kicad/bfdac.pretty + fp-lib-table.  ADM6-60-01.5-L-4-2-A from the Samtec print
    'RECOMMENDED PCB LAYOUT FOR ADM6-XXX-XX.X-XXX-X-X-X' Rev A (ECN-358211, 6/5/2019, datasheets/samtec_adm6_footprint.pdf):
    rows A..D, 0.635 pitch, 60 positions, pin 1 at +x; row pitch 0.96 A-B and C-D, 1.58 B-C (3.50 total);
    pad dia 0.356 +-0.05; TABLE 1 -60: A (envelope) 42.82, B (pin span) 37.465, C (alignment NPTH span) 40.27;
    NPTH dia 0.95 +-0.05: pin-60 end (left, -x) 1.27 toward row A, pin-1 end (right, +x) ON the centreline
    (print re-read 2026-10-08; matches the Alinx AXVU13G carrier .brd footprint exactly - earlier +-1.27 diagonal was a misread);
    body 5.00 wide, 1.00 x 45 deg chamfers on two corners; stencil 0.102 thick, 1:1 apertures."""
    n, pitch = 60, 0.635
    A, B, C = 42.82, 37.465, 40.27
    rows = {"A": -1.75, "B": -0.79, "C": 0.79, "D": 1.75}
    pad = 0.356
    L = ['(footprint "Samtec_ADM6-60-01.5-L-4-2-A" (version 20240108) (generator "gen_kicad") (generator_version "1") (layer "F.Cu")',
         '  (descr "Samtec AcceleRate HD ADM6-60-01.5-L-4-2-A, 4x60 0.635 mm, solder-ball terminal, 1.5 mm lead style, alignment pins; Samtec footprint print Rev A")',
         '  (tags "Samtec ADM6 AcceleRate HD mezzanine 0.635")',
         '  (attr smd)',
         '  (property "Reference" "REF**" (at 0 -3.6 0) (layer "F.SilkS") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Value" "ADM6-60-01.5-L-4-2-A" (at 0 3.6 0) (layer "F.Fab") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Datasheet" "https://www.samtec.com/products/adm6" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Description" "" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U()]
    hx, hy = A / 2, 2.5
    ch = 1.0
    # body outline (fab) with the two keying chamfers: pin-1 corner (top-right, row A side) and bottom-left
    outline = [(hx - ch, -hy), (hx, -hy + ch), (hx, hy), (-hx + ch, hy), (-hx, hy - ch), (-hx, -hy), (hx - ch, -hy)]
    for (x0, y0), (x1, y1) in zip(outline, outline[1:]):
        L.append('  (fp_line (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.1) (type default)) (layer "F.Fab") (uuid "%s"))' % (x0, y0, x1, y1, U()))
    # silkscreen: outline 0.1 outside the body, pin-1 marker beyond the A01 pad
    sx, sy = hx + 0.1, hy + 0.1
    silk = [(sx - ch, -sy), (sx, -sy + ch), (sx, sy), (-sx + ch, sy), (-sx, sy - ch), (-sx, -sy), (sx - ch, -sy)]
    for (x0, y0), (x1, y1) in zip(silk, silk[1:]):
        L.append('  (fp_line (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.12) (type default)) (layer "F.SilkS") (uuid "%s"))' % (x0, y0, x1, y1, U()))
    L.append('  (fp_circle (center %.3f %.3f) (end %.3f %.3f) (stroke (width 0.12) (type default)) (fill solid) (layer "F.SilkS") (uuid "%s"))'
             % (B / 2 + 1.0, rows["A"] - 0.9, B / 2 + 1.0 + 0.15, rows["A"] - 0.9, U()))
    # courtyard = envelope + 0.25 (note 2: other components keep out of the envelope)
    cx, cy = hx + 0.25, hy + 0.25
    L.append('  (fp_rect (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd") (uuid "%s"))' % (-cx, -cy, cx, cy, U()))
    L.append('  (fp_text user "${REFERENCE}" (at 0 0 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.8 0.8) (thickness 0.12))))' % U())
    for r, y in rows.items():
        for i in range(n):
            x = B / 2 - i * pitch
            L.append('  (pad "%s%d" smd circle (at %.4f %.3f) (size %.3f %.3f) (layers "F.Cu" "F.Paste" "F.Mask") (solder_mask_margin 0.05) (uuid "%s"))'
                     % (r, i + 1, x, y, pad, pad, U()))
    for x, y in ((-C / 2, -1.27), (C / 2, 0.0)):
        L.append('  (pad "" np_thru_hole circle (at %.3f %.3f) (size 0.95 0.95) (drill 0.95) (layers "*.Cu" "*.Mask") (uuid "%s"))' % (x, y, U()))
    L.append(')')
    d = os.path.join(OUT, LOCALLIB + ".pretty")
    os.makedirs(d, exist_ok=True)
    with open(os.path.join(d, "Samtec_ADM6-60-01.5-L-4-2-A.kicad_mod"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")
    # Crystek CCHD-957, 9x14 mm SMD XO - datasheet Rev N 25-Aug-2026 p.2 (datasheets/CCHD-957.pdf), SUGGESTED PAD LAYOUT:
    # pads 0.050 x 0.090 in (1.27 x 2.28 mm), centres 0.200 in (5.08) apart in x and 0.280 in (7.11) in y;
    # body 0.560 x 0.360 in (14.2 x 9.14), 0.210 in (5.3) tall; pad 1 = E/D at the dot corner (top view bottom-left),
    # numbering CCW: 1 E/D, 2 GND, 3 OUT, 4 Vcc (bottom view 1 top-left, 2 top-right, 3 bottom-right, 4 bottom-left).
    bx, by = 14.2 / 2, 9.14 / 2
    px, py, pw, ph = 5.08 / 2, 7.11 / 2, 1.27, 2.28
    X = ['(footprint "Crystek_CCHD-957" (version 20240108) (generator "gen_kicad") (generator_version "1") (layer "F.Cu")',
         '  (descr "Crystek CCHD-957 9x14 mm SMD oscillator, 4 pads 1.27x2.28 on 5.08x7.11 mm; datasheet Rev N suggested pad layout")',
         '  (tags "Crystek CCHD-957 oscillator XO 9x14")',
         '  (attr smd)',
         '  (property "Reference" "REF**" (at 0 -5.6 0) (layer "F.SilkS") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Value" "CCHD-957" (at 0 5.6 0) (layer "F.Fab") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Datasheet" "https://www.crystek.com/crystal/spec-sheets/clock/CCHD-957.pdf" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Description" "" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (fp_rect (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.1) (type default)) (fill none) (layer "F.Fab") (uuid "%s"))' % (-bx, -by, bx, by, U()),
         '  (fp_circle (center %.3f %.3f) (end %.3f %.3f) (stroke (width 0.1) (type default)) (fill solid) (layer "F.Fab") (uuid "%s"))' % (-bx + 1.2, by - 1.2, -bx + 1.5, by - 1.2, U()),
         '  (fp_rect (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.12) (type default)) (fill none) (layer "F.SilkS") (uuid "%s"))' % (-bx - 0.15, -by - 0.15, bx + 0.15, by + 0.15, U()),
         '  (fp_circle (center %.3f %.3f) (end %.3f %.3f) (stroke (width 0.12) (type default)) (fill solid) (layer "F.SilkS") (uuid "%s"))' % (-bx - 0.8, by + 0.4, -bx - 0.65, by + 0.4, U()),
         '  (fp_rect (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd") (uuid "%s"))' % (-bx - 0.25, -by - 0.25, bx + 0.25, by + 0.25, U()),
         '  (fp_text user "${REFERENCE}" (at 0 0 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.8 0.8) (thickness 0.12))))' % U()]
    for num, (x, y) in enumerate(((-px, py), (px, py), (px, -py), (-px, -py)), 1):
        X.append('  (pad "%d" smd roundrect (at %.3f %.3f) (size %.2f %.2f) (layers "F.Cu" "F.Paste" "F.Mask") (roundrect_rratio 0.2) (uuid "%s"))' % (num, x, y, pw, ph, U()))
    X.append(')')
    with open(os.path.join(d, "Crystek_CCHD-957.kicad_mod"), "w", encoding="utf-8") as f:
        f.write("\n".join(X) + "\n")
    # Micron MT25Q package code 12: 24-ball T-PBGA, 5x5 grid, 1.0 mm pitch, 6 x 8 mm body, A1 absent (Fig. 6 of
    # mt25q-qlkt-U02-CBB-S-IT Rev C): 24x ball dia 0.4 post-reflow on dia 0.40 SMD pads; grid centred (4 CTR both ways).
    # Top view: A1 top-left, columns 1..5 left to right (x = -2..+2), rows A..E top to bottom (y = -2..+2).
    bx, by = 3.0, 4.0
    M = ['(footprint "Micron_T-PBGA-24_6x8mm_Layout5x5_P1.0mm" (version 20240108) (generator "gen_kicad") (generator_version "1") (layer "F.Cu")',
         '  (descr "Micron 24-ball T-PBGA, 5x5 grid 1.0 mm pitch, 6x8 mm body, A1 absent (MT25Q package code 12); dia 0.40 SMD pads per datasheet")',
         '  (tags "BGA 24 5x5 1.0 Micron MT25Q T-PBGA")',
         '  (attr smd)',
         '  (property "Reference" "REF**" (at 0 -5.0 0) (layer "F.SilkS") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Value" "MT25QU02G" (at 0 5.0 0) (layer "F.Fab") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Datasheet" "https://www.micron.com/products/nor-flash/serial-nor-flash/part-catalog/mt25qu02gcbb8e12-0sit" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Description" "" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U()]
    fab = [(-bx + 1.0, -by), (bx, -by), (bx, by), (-bx, by), (-bx, -by + 1.0), (-bx + 1.0, -by)]
    for (x0, y0), (x1, y1) in zip(fab, fab[1:]):
        M.append('  (fp_line (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.1) (type default)) (layer "F.Fab") (uuid "%s"))' % (x0, y0, x1, y1, U()))
    s = 0.15
    for (x0, y0), (x1, y1) in (((-bx - s, by + s), (bx + s, by + s)), ((bx + s, -by - s), (bx + s, by + s)), ((-bx - s, -by - s), (bx + s, -by - s)), ((-bx - s, -by - s), (-bx - s, by + s))):
        M.append('  (fp_line (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.12) (type default)) (layer "F.SilkS") (uuid "%s"))' % (x0, y0, x1, y1, U()))
    M.append('  (fp_circle (center %.3f %.3f) (end %.3f %.3f) (stroke (width 0.12) (type default)) (fill solid) (layer "F.SilkS") (uuid "%s"))' % (-bx - 0.6, -by - 0.6, -bx - 0.45, -by - 0.6, U()))
    M.append('  (fp_rect (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd") (uuid "%s"))' % (-bx - 0.25, -by - 0.25, bx + 0.25, by + 0.25, U()))
    M.append('  (fp_text user "${REFERENCE}" (at 0 0 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U())
    for ri, r in enumerate("ABCDE"):
        for c in range(1, 6):
            if r == "A" and c == 1:
                continue
            M.append('  (pad "%s%d" smd circle (at %.1f %.1f) (size 0.4 0.4) (layers "F.Cu" "F.Paste" "F.Mask") (solder_mask_margin 0.05) (uuid "%s"))' % (r, c, c - 3.0, ri - 2.0, U()))
    M.append(')')
    with open(os.path.join(d, "Micron_T-PBGA-24_6x8mm_Layout5x5_P1.0mm.kicad_mod"), "w", encoding="utf-8") as f:
        f.write("\n".join(M) + "\n")
    # Neutrik NC3MD-H (D-series horizontal PCB XLR, male) - Neutrik drawing S1-NC3MD-H (datasheets/NC3MD-H-B/nc3md-h-3.pdf, read 2026-10-10):
    # PCB layout, component side, panel at the top: pins 2 / 3 / 1 in a row at x = -4 / 0 / +4, G 5.0 behind pin 3, all 4 holes O1.2;
    # locating peg O2.3 5.0 in front of pin 3; pin row 22.5 behind the panel rear face (= flange front); flange 2.3 thick, 26 wide,
    # 31 tall centred 12.5 above the PCB -> the flange reaches 3 mm BELOW the board, so the board edge must stop behind the flange
    # (>= 20.2 in front of the pin row; drawn at 19.7 on User.1); body 21.7 behind the flange; nose 2.7 in front of the flange.
    N = ['(footprint "Neutrik_NC3MD-H" (version 20240108) (generator "gen_kicad") (generator_version "1") (layer "F.Cu")',
         '  (descr "Neutrik NC3MD-H / NC3MD-H-B 3-pole male XLR receptacle, D-size metal shell, horizontal PCB mount; pins 1/2/3/G O1.2 at 4 mm, O2.3 locating peg; Neutrik drawing S1-NC3MD-H")',
         '  (tags "Neutrik XLR NC3MD-H D-series horizontal")',
         '  (attr through_hole)',
         '  (property "Reference" "REF**" (at 0 8.5 0) (layer "F.SilkS") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Value" "NC3MD-H-B" (at 0 -10 0) (layer "F.Fab") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Datasheet" "https://www.neutrik.com/en/product/nc3md-h-b" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         '  (property "Description" "" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U(),
         # body behind the flange (26 wide = flange width, 21.7 long) + flange + nose on Fab; silk only behind the board edge
         '  (fp_rect (start -13 -20.2) (end 13 1.5) (stroke (width 0.1) (type default)) (fill none) (layer "F.Fab") (uuid "%s"))' % U(),
         '  (fp_rect (start -13 -22.5) (end 13 -20.2) (stroke (width 0.1) (type default)) (fill none) (layer "F.Fab") (uuid "%s"))' % U(),
         '  (fp_rect (start -10 -25.2) (end 10 -22.5) (stroke (width 0.1) (type default)) (fill none) (layer "F.Fab") (uuid "%s"))' % U(),
         '  (fp_text user "panel rear face / flange front" (at 0 -23.6 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.8 0.8) (thickness 0.12))))' % U(),
         '  (fp_line (start -13 -19.7) (end 13 -19.7) (stroke (width 0.15) (type dash)) (layer "User.1") (uuid "%s"))' % U(),
         '  (fp_text user "board edge max (flange 3 mm below PCB)" (at 0 -18.6 0) (layer "User.1") (uuid "%s") (effects (font (size 0.8 0.8) (thickness 0.12))))' % U(),
         '  (fp_rect (start -13.15 -19.7) (end 13.15 1.65) (stroke (width 0.12) (type default)) (fill none) (layer "F.SilkS") (uuid "%s"))' % U(),
         '  (fp_rect (start -13.25 -25.45) (end 13.25 6.5) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd") (uuid "%s"))' % U(),
         '  (fp_text user "${REFERENCE}" (at 0 -8 0) (layer "F.Fab") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))' % U()]
    for nm, x, y in (("1", 4.0, 0.0), ("2", -4.0, 0.0), ("3", 0.0, 0.0), ("G", 0.0, 5.0)):
        N.append('  (pad "%s" thru_hole circle (at %.1f %.1f) (size 2.0 2.0) (drill 1.2) (layers "*.Cu" "*.Mask") (uuid "%s"))' % (nm, x, y, U()))
    N.append('  (pad "" np_thru_hole circle (at 0 -5) (size 2.3 2.3) (drill 2.3) (layers "*.Cu" "*.Mask") (uuid "%s"))' % U())
    N.append(')')
    with open(os.path.join(d, "Neutrik_NC3MD-H.kicad_mod"), "w", encoding="utf-8") as f:
        f.write("\n".join(N) + "\n")
    # TI SN74LVC1G74 DQE0008A X2SON-8, from datasheet Rev. G land-pattern
    # example (8 pads, 0.50 x 0.175 mm, 0.35 mm row pitch, 0.90 mm column pitch).
    D = ['(footprint "TI_DQE_X2SON-8_1.4x1.0mm_P0.35mm" (version 20240108) (generator "gen_kicad") (generator_version "1") (layer "F.Cu")',
         '  (descr "TI SN74LVC1G74 DQE0008A X2SON-8, 1.4x1.0 mm; TI datasheet Rev G recommended land pattern")',
         '  (tags "TI SN74LVC1G74 DQE X2SON-8 0.35mm")',
         '  (attr smd)',
         '  (property "Reference" "REF**" (at 0 -1.1 0) (layer "F.SilkS") (uuid "%s") (effects (font (size 0.7 0.7) (thickness 0.11))))' % U(),
         '  (property "Value" "SN74LVC1G74DQER" (at 0 1.1 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.65 0.65) (thickness 0.1))))' % U(),
         '  (property "Datasheet" "https://www.ti.com/lit/ds/symlink/sn74lvc1g74.pdf" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U(),
         '  (property "Description" "TI DQE0008A recommended copper land pattern; pin map per datasheet Figure 5-2" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U(),
         '  (fp_rect (start -0.525 -0.725) (end 0.525 0.725) (stroke (width 0.1) (type default)) (fill none) (layer "F.Fab") (uuid "%s"))' % U(),
         '  (fp_circle (center -0.78 -0.80) (end -0.73 -0.80) (stroke (width 0.1) (type default)) (fill solid) (layer "F.SilkS") (uuid "%s"))' % U(),
         '  (fp_rect (start -0.95 -0.875) (end 0.95 0.875) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd") (uuid "%s"))' % U(),
         '  (fp_text user "${REFERENCE}" (at 0 0 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U()]
    dqe_pads = (
        ("1", -0.45, -0.525), ("2", -0.45, -0.175),
        ("3", -0.45,  0.175), ("4", -0.45,  0.525),
        ("5",  0.45,  0.525), ("6",  0.45,  0.175),
        ("7",  0.45, -0.175), ("8",  0.45, -0.525))
    for num, x, y in dqe_pads:
        D.append('  (pad "%s" smd roundrect (at %.3f %.3f) (size 0.500 0.175) (layers "F.Cu" "F.Paste" "F.Mask") (roundrect_rratio 0.28) (solder_mask_margin 0.05) (uuid "%s"))'
                 % (num, x, y, U()))
    D.append(')')
    with open(os.path.join(d, "TI_DQE_X2SON-8_1.4x1.0mm_P0.35mm.kicad_mod"), "w", encoding="utf-8") as f:
        f.write("\n".join(D) + "\n")
    # TI OPA1612 DRG0008A WSON-8. Pinout is the same as the OPA1612 SOIC-8;
    # pad 4 and the exposed thermal pad are both V-. TI land pattern: 8 x
    # 0.70 x 0.25 mm lands, 0.50 mm pitch, 2.70 mm row spacing, 1.20 x 2.00 mm EP.
    O = ['(footprint "TI_OPA1612_DRG_WSON-8_3x3mm_P0.5mm_EP1.2x2.0mm" (version 20240108) (generator "gen_kicad") (generator_version "1") (layer "F.Cu")',
         '  (descr "TI OPA1612 DRG0008A WSON-8, 3x3 mm; datasheet land pattern; exposed pad tied to V- (pad 4)")',
         '  (tags "TI OPA1612 DRG WSON-8 0.5mm PowerPAD")',
         '  (attr smd)',
         '  (duplicate_pad_numbers_are_jumpers no)',
         '  (property "Reference" "REF**" (at 0 -2.1 0) (layer "F.SilkS") (uuid "%s") (effects (font (size 0.8 0.8) (thickness 0.12))))' % U(),
         '  (property "Value" "OPA1612AIDRGR" (at 0 2.1 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.7 0.7) (thickness 0.1))))' % U(),
         '  (property "Datasheet" "https://www.ti.com/lit/ds/symlink/opa1612.pdf" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U(),
         '  (property "Description" "TI DRG0008A land pattern; thermal pad and optional vias map to V- (pad 4)" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U(),
         '  (fp_rect (start -1.55 -1.55) (end 1.55 1.55) (stroke (width 0.1) (type default)) (fill none) (layer "F.Fab") (uuid "%s"))' % U(),
         '  (fp_circle (center -1.68 -1.68) (end -1.63 -1.68) (stroke (width 0.1) (type default)) (fill solid) (layer "F.SilkS") (uuid "%s"))' % U(),
         '  (fp_rect (start -1.8 -1.8) (end 1.8 1.8) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd") (uuid "%s"))' % U(),
         '  (fp_text user "${REFERENCE}" (at 0 0 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U()]
    opa_pads = (
        ("1", -1.35, -0.75), ("2", -1.35, -0.25),
        ("3", -1.35,  0.25), ("4", -1.35,  0.75),
        ("5",  1.35,  0.75), ("6",  1.35,  0.25),
        ("7",  1.35, -0.25), ("8",  1.35, -0.75))
    for num, x, y in opa_pads:
        O.append('  (pad "%s" smd roundrect (at %.3f %.3f) (size 0.700 0.250) (layers "F.Cu" "F.Paste" "F.Mask") (roundrect_rratio 0.2) (solder_mask_margin 0.05) (uuid "%s"))'
                 % (num, x, y, U()))
    O.append('  (pad "4" smd rect (at 0 0) (size 1.200 2.000) (property pad_prop_heatsink) (layers "F.Cu" "F.Mask") (zone_connect 2) (uuid "%s"))' % U())
    # Four optional 0.20 mm vias follow TI's DRG land-pattern example.
    for x, y in ((0, -0.75), (-0.35, 0), (0.35, 0), (0, 0.75)):
        O.append('  (pad "4" thru_hole circle (at %.3f %.3f) (size 0.400 0.400) (drill 0.200) (property pad_prop_heatsink) (layers "*.Cu" "*.Mask") (remove_unused_layers no) (zone_connect 2) (uuid "%s"))'
                 % (x, y, U()))
    # The datasheet's stencil example specifies 84% paste coverage for the EP.
    for x in (-0.32, 0.32):
        for y in (-0.50, 0.50):
            x0, x1, y0, y1 = x - 0.28, x + 0.28, y - 0.45, y + 0.45
            O.append('  (fp_poly (pts (xy %.3f %.3f) (xy %.3f %.3f) (xy %.3f %.3f) (xy %.3f %.3f)) (layer "F.Paste") (uuid "%s"))'
                     % (x0, y0, x1, y0, x1, y1, x0, y1, U()))
    O.append(')')
    with open(os.path.join(d, "TI_OPA1612_DRG_WSON-8_3x3mm_P0.5mm_EP1.2x2.0mm.kicad_mod"), "w", encoding="utf-8") as f:
        f.write("\n".join(O) + "\n")
    # TI BUF634A DDA0008B HSOIC-8. Thermal pad is V-; footprint uses pad 4
    # for the EP so the current 8-pin schematic symbol carries the V- net.
    B = ['(footprint "TI_BUF634A_DDA_HSOIC-8_P1.27mm_EP2.95x4.9mm" (version 20240108) (generator "gen_kicad") (generator_version "1") (layer "F.Cu")',
         '  (descr "TI BUF634A DDA0008B HSOIC-8 PowerPAD; TI land pattern; exposed pad tied to V- (pad 4)")',
         '  (tags "TI BUF634A DDA0008B HSOIC-8 PowerPAD")',
         '  (attr smd)',
         '  (duplicate_pad_numbers_are_jumpers no)',
         '  (property "Reference" "REF**" (at 0 -3.2 0) (layer "F.SilkS") (uuid "%s") (effects (font (size 0.9 0.9) (thickness 0.13))))' % U(),
         '  (property "Value" "BUF634AIDDAR" (at 0 3.2 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.8 0.8) (thickness 0.12))))' % U(),
         '  (property "Datasheet" "https://www.ti.com/lit/ds/symlink/buf634a.pdf" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U(),
         '  (property "Description" "TI DDA0008B land pattern; pad 4 duplicate maps the PowerPAD and thermal vias to V- per TI Figure 11-1" (at 0 0 0) (layer "F.Fab") hide (uuid "%s") (effects (font (size 0.6 0.6) (thickness 0.1))))' % U(),
         '  (fp_rect (start -1.95 -2.45) (end 1.95 2.45) (stroke (width 0.1) (type default)) (fill none) (layer "F.Fab") (uuid "%s"))' % U(),
         '  (fp_rect (start -3.75 -2.70) (end 3.75 2.70) (stroke (width 0.05) (type default)) (fill none) (layer "F.CrtYd") (uuid "%s"))' % U(),
         '  (fp_text user "${REFERENCE}" (at 0 0 0) (layer "F.Fab") (uuid "%s") (effects (font (size 0.7 0.7) (thickness 0.1))))' % U()]
    buf_pads = (
        ("1", -2.70, -1.905), ("2", -2.70, -0.635),
        ("3", -2.70,  0.635), ("4", -2.70,  1.905),
        ("5",  2.70,  1.905), ("6",  2.70,  0.635),
        ("7",  2.70, -0.635), ("8",  2.70, -1.905))
    for num, x, y in buf_pads:
        B.append('  (pad "%s" smd rect (at %.3f %.3f) (size 1.550 0.600) (layers "F.Cu" "F.Mask" "F.Paste") (uuid "%s"))'
                 % (num, x, y, U()))
    B.append('  (pad "4" smd rect (at 0 0) (size 2.950 4.900) (property pad_prop_heatsink) (layers "F.Cu") (zone_connect 2) (uuid "%s"))' % U())
    B.append('  (pad "" smd rect (at 0 0) (size 2.710 3.400) (layers "F.Mask") (uuid "%s"))' % U())
    B.append('  (pad "" smd rect (at 0 0) (size 2.710 3.400) (layers "F.Paste") (uuid "%s"))' % U())
    # The TI Figure 11-1 staggered 13-via array; all duplicate pad 4 (V-).
    buf_thermal_vias = (
        (-0.889, -1.524), (0.000, -1.524), (0.889, -1.524),
        (-0.635, -0.762), (0.635, -0.762),
        (-0.889,  0.000), (0.000,  0.000), (0.889,  0.000),
        (-0.635,  0.762), (0.635,  0.762),
        (-0.889,  1.524), (0.000,  1.524), (0.889,  1.524))
    for x, y in buf_thermal_vias:
        B.append('  (pad "4" thru_hole circle (at %.3f %.3f) (size 0.660 0.660) (drill 0.254) (property pad_prop_heatsink) (layers "*.Cu" "*.Mask") (remove_unused_layers no) (zone_connect 2) (uuid "%s"))'
                 % (x, y, U()))
    B.append(')')
    with open(os.path.join(d, "TI_BUF634A_DDA_HSOIC-8_P1.27mm_EP2.95x4.9mm.kicad_mod"), "w", encoding="utf-8") as f:
        f.write("\n".join(B) + "\n")
    # vendor-supplied footprints (user downloads under datasheets/<part>/KiCADv6/footprints.pretty), copied verbatim
    for src, dst in VENDOR_FOOTPRINTS:
        with open(os.path.join(ROOT, "datasheets", src), encoding="utf-8") as f:
            txt = f.read()
        txt = re.sub(r'^\(footprint "[^"]*"', '(footprint "%s"' % dst, txt, count=1)   # library name = file name
        with open(os.path.join(d, dst + ".kicad_mod"), "w", encoding="utf-8") as f:
            f.write(txt)
    with open(os.path.join(OUT, "fp-lib-table"), "w", encoding="utf-8") as f:
        f.write('(fp_lib_table\n  (version 7)\n  (lib (name "%s")(type "KiCad")(uri "${KIPRJMOD}/%s.pretty")(options "")(descr "BFDAC project footprints"))\n)\n'
                % (LOCALLIB, LOCALLIB))

# (source under datasheets/, footprint name in bfdac.pretty) - official vendor land patterns, user ruling 2026-10-10
VENDOR_FOOTPRINTS = [
    (r"MAX22445FAWE_\KiCADv6\footprints.pretty\21-0042B_16_MXM.kicad_mod", "ADI_21-0042B_16_WSOIC"),       # MAX22444/22445 W SOIC-16 (ADI pkg 21-0042B)
    (r"ADP7158ACPZ_3_3_R7\KiCADv6\footprints.pretty\CP-10-9_ADI.kicad_mod", "ADI_CP-10-9_LFCSP-10"),      # ADP7158 LFCSP-10 3x3 EP (ADI pkg CP-10-9)
    (r"CAXC8T245QWRGYRQ1\KiCADv6\footprints.pretty\VQFN25_RGY_TEX.kicad_mod", "TI_RGY_VQFN-24_3.5x5.5mm_P0.5mm_EP"),   # SN74AXC8T245 RHL/RGY VQFN-24 (nominal density; -L/-M variants left in datasheets/), pad 25 = EP
]

# ACVU13 SoM connector placement on the carrier - extracted 2026-10-08 from the Alinx AXVU13G.1.0 carrier .brd (Allegro 16.6)
# with KiCad 10's Allegro importer (utils/brd_connectors.py) and cross-checked against the SoM bottom DXF (utils/som_connectors.py).
# Frame: SoM centre at the origin, x right, y UP, carrier viewed from the top (the SoM sits component-side up, so no mirror).
# Each ADM6-60 is 240 pads 4x60 at 0.635, rows at +-0.79/+-1.75, span 37.465; all eight sit 47.499 from the centre along
# one axis and +-22.159 along the other.  rot = KiCad footprint orientation for bfdac:Samtec_ADM6-60-01.5-L-4-2-A
# (rot 0: pin 1 at +x, row A at -y(KiCad) = up).  Verified pad-for-pad against the Alinx board (A1/A60/D1/D60 + both NPTH).
# SoM-native frame (SoM bottom DXF, SoM's own top view) is this table rotated -90 deg: Alinx mounts the SoM turned 90 deg.
SOM_CONNECTORS = {  # ref: (dx, dy_up, rot_deg)   pin 1 end / row A side noted
    "J1": (-47.499, +22.159, -90),   # left edge, upper;  pin 1 at the bottom end, row A inboard (+x)
    "J2": (-47.499, -22.159, -90),   # left edge, lower;  pin 1 bottom, row A inboard
    "J3": (-22.159, -47.499,   0),   # bottom edge, left; pin 1 at the right end, row A inboard (+y)
    "J4": (+22.159, -47.499,   0),   # bottom edge, right; pin 1 right, row A inboard
    "J5": (+47.499, -22.159,  90),   # right edge, lower; pin 1 at the top end, row A inboard (-x)
    "J6": (+47.499, +22.159,  90),   # right edge, upper; pin 1 top, row A inboard
    "J7": (+22.159, +47.499,   0),   # top edge, right;  pin 1 right, row A OUTBOARD (+y)
    "J8": (-22.159, +47.499,   0),   # top edge, left;   pin 1 right, row A outboard
}
# SoM board = 106 x 106 (DXF BG_OUTLINE), centre = connector-pattern centre.  Two hole sets (SoM STEP ACVU13.1.stp + Alinx carrier .brd):
#  corners  (+-48.682, 97.364 mm square, 4.318 from the SoM edge): SoM 'MH_250H125' = dia 3.175 hole / 6.35 pad (M3 standoffs);
#           the Alinx carrier drills these dia 4.0 with a 6.35 ring.
#  inner    (+-39.0, 78 mm square): dia 4.0 hole / 5.5 ring on BOTH the SoM and the carrier = SUPPORT STANDOFFS (user 2026-10-08;
#           the SoM's FAN90X90 heatsink shares this pattern).  Swept the Alinx carrier: no other drill >= 0.8 mm under the 106 x 106 SoM.
#  Carrier rings are plated, each on its own isolated net (Net_2..Net_9 in the Alinx brd).
SOM_SIZE = 106.0
SOM_MOUNT_HOLES = ([(sx * 48.682, sy * 48.682, 4.0, 6.35, "standoff") for sx in (-1, 1) for sy in (-1, 1)]
                   + [(sx * 39.0, sy * 39.0, 4.0, 5.5, "support standoff") for sx in (-1, 1) for sy in (-1, 1)])
SOM_SEED_CENTRE = (150.0, 150.0)   # KiCad sheet position of the SoM centre in the seed board

def write_som_seed_board():
    """hw/kicad/som_seed.kicad_pcb: J1..J8 placed per SOM_CONNECTORS with the local ADM6 footprint, plus the SoM outline
    (106 x 106) and mounting-hole marks on User.Comments.  Separate file on purpose - never overwrites a real layout; copy the
    footprints into the board or start the layout from it and 'Update PCB from Schematic' with re-link by reference."""
    fp = open(os.path.join(OUT, LOCALLIB + ".pretty", "Samtec_ADM6-60-01.5-L-4-2-A.kicad_mod"), encoding="utf-8").read().strip()
    assert fp.startswith('(footprint "Samtec_ADM6-60-01.5-L-4-2-A"') and fp.endswith(")")
    body = fp[len('(footprint "Samtec_ADM6-60-01.5-L-4-2-A"'):-1]
    body = body.replace('(layer "F.Cu")', '', 1)
    cx0, cy0 = SOM_SEED_CENTRE
    L = ['(kicad_pcb (version 20241229) (generator "gen_kicad") (generator_version "10.0")',
         '  (general (thickness 1.6) (legacy_teardrops no))', '  (paper "A3")',
         '  (layers (0 "F.Cu" signal) (2 "B.Cu" signal) (9 "F.Adhes" user "F.Adhesive") (11 "B.Adhes" user "B.Adhesive")'
         ' (13 "F.Paste" user) (15 "B.Paste" user) (5 "F.SilkS" user "F.Silkscreen") (7 "B.SilkS" user "B.Silkscreen")'
         ' (1 "F.Mask" user) (3 "B.Mask" user) (17 "Dwgs.User" user "User.Drawings") (19 "Cmts.User" user "User.Comments")'
         ' (21 "Eco1.User" user "User.Eco1") (23 "Eco2.User" user "User.Eco2") (25 "Edge.Cuts" user) (27 "Margin" user)'
         ' (31 "F.CrtYd" user "F.Courtyard") (29 "B.CrtYd" user "B.Courtyard") (35 "F.Fab" user) (33 "B.Fab" user))',
         '  (setup (pad_to_mask_clearance 0))', '  (net 0 "")']
    for ref, (dx, dy, rot) in SOM_CONNECTORS.items():
        x, y = cx0 + dx, cy0 - dy
        b = body.replace('(property "Reference" "REF**"', '(property "Reference" "%s"' % ref, 1)
        L.append('  (footprint "%s:Samtec_ADM6-60-01.5-L-4-2-A" (layer "F.Cu") (uuid "%s") (at %.3f %.3f %d)%s)' % (LOCALLIB, U(), x, y, rot, b))
    h = SOM_SIZE / 2
    L.append('  (gr_rect (start %.3f %.3f) (end %.3f %.3f) (stroke (width 0.15) (type dash)) (fill none) (layer "Cmts.User") (uuid "%s"))'
             % (cx0 - h, cy0 - h, cx0 + h, cy0 + h, U()))
    for mx, my, drill, ring, what in SOM_MOUNT_HOLES:
        for dia in (drill, ring):
            L.append('  (gr_circle (center %.3f %.3f) (end %.3f %.3f) (stroke (width 0.15) (type default)) (fill none) (layer "Cmts.User") (uuid "%s"))'
                     % (cx0 + mx, cy0 - my, cx0 + mx + dia / 2, cy0 - my, U()))
        L.append('  (gr_text "%s %.1f/%.2f" (at %.3f %.3f 0) (layer "Cmts.User") (uuid "%s") (effects (font (size 1 1) (thickness 0.15))))'
                 % (what, drill, ring, cx0 + mx, cy0 - my + 4.5, U()))
    L.append('  (gr_text "ACVU13 SoM footprint: 106 x 106 outline, 8 x ADM6-60 per Alinx AXVU13G.1.0 .brd (2026-10-08); corner standoffs 97.364 mm square, support standoffs 78 mm square (drill/ring per Alinx carrier)"'
             ' (at %.3f %.3f 0) (layer "Cmts.User") (uuid "%s") (effects (font (size 1.5 1.5) (thickness 0.2))))' % (cx0, cy0, U()))
    L.append(')')
    with open(os.path.join(OUT, "som_seed.kicad_pcb"), "w", encoding="utf-8") as f:
        f.write("\n".join(L) + "\n")

# Coefficient flash bus on J1 bank 70 (bom 18a, 2026-10-05: bank 70 is 51/51 free, VCCIO_70 = V18, no clock/
# cascode neighbours; MUST match vu13p_dac_top.xdc s11b).  {Alinx signal: schematic label}.  9 carrier IOs:
# C, DQ0..3, S#0..3.  RESET# (A4, dedicated, internal pull-up) is strapped to V18; DQ3 (D4) = HOLD# is the pulled-up data line; no CF_RST IO.
#   CF_CLK  J35 J1-A20 | CF_CS0 J36 J1-A19 | CF_DQ0 H36 J1-A23 | CF_DQ1 G36 J1-A22 | CF_DQ2 H34 J1-B20 | CF_DQ3 G34 J1-B19
#   CF_CS1  H37 J1-A26 | CF_CS2 H38 J1-A25 | CF_CS3 G37 J1-B29
CFLASH_PINS = {"B70_L3_P": "CF_CLK_J1", "B70_L3_N": "CF_CS0", "B70_L4_P": "CF_DQ0", "B70_L4_N": "CF_DQ1",
               "B70_L5_P": "CF_DQ2", "B70_L5_N": "CF_DQ3", "B70_L1_P": "CF_CS1", "B70_L1_N": "CF_CS2",
               "B70_L2_P": "CF_CS3"}
CFLASH_POPULATED = 4   # bom 18a ruling 2026-10-05 23:16 (user): 30+ designs x {44.1k, 48k} = 60+ filters -> 4 x 2 Gb = 8 Gb = 90 filters

def _find_sym(tree, name):
    for c in tree:
        if isinstance(c, list) and c and c[0] == "symbol" and c[1] == '"%s"' % name:
            return c
    raise KeyError(name)

def _prop(sym, key):
    for c in sym:
        if isinstance(c, list) and c[0] == "property" and c[1] == '"%s"' % key:
            return c
    return None

def get_symbol(libid):
    """Return (lib_symbols entry, pins) with `extends` resolved."""
    libname, name = libid.split(":")
    sym = deepcopy(_find_sym(lib(libname), name))
    ext = [c for c in sym if isinstance(c, list) and c[0] == "extends"]
    if ext:
        parent = ext[0][1].strip('"')
        psym = deepcopy(_find_sym(lib(libname), parent))
        # child properties override parent's
        for c in sym:
            if isinstance(c, list) and c[0] == "property":
                pp = _prop(psym, c[1].strip('"'))
                if pp is not None:
                    psym[psym.index(pp)] = c
                else:
                    psym.append(c)
        for c in psym:
            if isinstance(c, list) and c[0] == "symbol":
                c[1] = '"' + c[1].strip('"').replace(parent, name, 1) + '"'
        sym = psym
    sym[1] = '"%s"' % libid
    pins = []
    for c in sym:
        if isinstance(c, list) and c[0] == "symbol":
            unit = int(c[1].strip('"').rsplit("_", 2)[1])
            for p in c:
                if isinstance(p, list) and p[0] == "pin":
                    at = [q for q in p if isinstance(q, list) and q[0] == "at"][0]
                    nm = [q for q in p if isinstance(q, list) and q[0] == "name"][0][1].strip('"')
                    num = [q for q in p if isinstance(q, list) and q[0] == "number"][0][1].strip('"')
                    pins.append(dict(unit=unit, name=nm, num=num, etype=p[1],
                                     x=float(at[1]), y=float(at[2]), ang=float(at[3])))
    return sym, pins

# ---------------------------------------------------------------- sheet
def U():
    return str(uuid.uuid4())

FONT = "(effects (font (size 1.27 1.27)))"
STUB = 2.54

# Nets that are one-per-board: never get the _L/_R channel suffix.
# DUAL-MONO POL (user ruling 2026-10-12, bom 17(m3)): the POL rails are PER-CHANNEL - P15A / N15A / VEE15 /
# V_ROFF / V33FF / V33CLK (and the already-local VE1 / P5A) are absent here so they get _L / _R.
# Shared = the pre-regulator inputs (P16A/N16A/V8P3/V4P3, from the power tube), digital/SoM rails, PG_ALL
# (wired-AND across all 16 monitor devices) and the REF5 ladder.
SHARED_NETS = {"GND", "V18", "V33D", "V12SOM", "V33RLY", "VAP_IO", "GND_AP", "REF5", "REF5F",
               "P16A", "N16A", "V8P3", "V4P3", "V33CLK", "V33FF", "PG_ALL"}

def chan_ref(r, ch):
    """Reference designator for channel `ch`.  L keeps the deck-era numbering; R is offset so the two channels
    never collide: cells 1xxx -> 2xxx, refs 9xx -> 7xx, tail quads Q3xx -> Q4xx, core/IV 1..59 -> 61..119."""
    if ch != "R":
        return r
    m = re.fullmatch(r"([A-Z]+)(\d+)", r)
    if not m:
        return r
    n = int(m.group(2))
    n = n + 1000 if n >= 1000 else n - 200 if n >= 900 else n + 100 if n >= 300 else n + 60
    return "%s%d" % (m.group(1), n)

def snap(v):
    return round(v / 1.27) * 1.27

class Sheet:
    def __init__(self, fname, title, paper="A3"):
        self.fname, self.title, self.paper = fname, title, paper
        self.uuid = U()
        self.libsyms = {}
        self.items = []
        self.refmap = {}
        self.pins_used = set()
        self.chan = None

    def xref(self, r):
        return chan_ref(r, self.chan) if self.chan else r

    # --- primitives
    def wire(self, x1, y1, x2, y2):
        self.items.append('(wire (pts (xy %.3f %.3f) (xy %.3f %.3f)) (stroke (width 0) (type default)) (uuid "%s"))'
                          % (x1, y1, x2, y2, U()))

    def text(self, s, x, y, size=1.27):
        self.items.append('(text "%s" (exclude_from_sim no) (at %.3f %.3f 0) (effects (font (size %.2f %.2f)) (justify left bottom)) (uuid "%s"))'
                          % (s.replace('"', "'").replace("\n", "\\n"), x, y, size, size, U()))

    def label(self, name, x, y, ang, kind):
        just = {0: "left", 90: "left", 180: "right", 270: "right"}[ang]
        if kind == "L":
            self.items.append('(label "%s" (at %.3f %.3f %d) (fields_autoplaced yes) (effects (font (size 1.27 1.27)) (justify %s bottom)) (uuid "%s"))'
                              % (name, x, y, ang, just, U()))
        elif kind == "G":
            if self.chan and name.upper() not in SHARED_NETS:
                name = "%s_%s" % (name, self.chan)
            self.items.append('(global_label "%s" (shape passive) (at %.3f %.3f %d) (fields_autoplaced yes) (effects (font (size 1.27 1.27)) (justify %s)) (uuid "%s") '
                              '(property "Intersheetrefs" "${INTERSHEET_REFS}" (at %.3f %.3f 0) (hide yes) (effects (font (size 1.27 1.27)) (justify %s))))'
                              % (name, x, y, ang, just, U(), x, y, just))
        elif kind == "H":
            self.items.append('(hierarchical_label "%s" (shape passive) (at %.3f %.3f %d) (effects (font (size 1.27 1.27)) (justify %s)) (uuid "%s"))'
                              % (name, x, y, ang, just, U()))

    def power(self, libid, value, x, y, ref):
        x, y = snap(x), snap(y)
        sym, pins = get_symbol(libid)
        self.libsyms[libid] = sym
        refs = ["%s%04d" % (ref, self.npwr()) for _ in self.inst_paths]
        self.items.append(
            '(symbol (lib_id "%s") (at %.3f %.3f 0) (unit 1) (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no) (uuid "%s") '
            '(property "Reference" "%s" (at %.3f %.3f 0) (hide yes) %s) '
            '(property "Value" "%s" (at %.3f %.3f 0) %s) '
            '(property "Footprint" "" (at %.3f %.3f 0) (hide yes) %s) '
            '(property "Datasheet" "" (at %.3f %.3f 0) (hide yes) %s) '
            '(property "Description" "" (at %.3f %.3f 0) (hide yes) %s) '
            '(pin "1" (uuid "%s")) (instances (project "%s" %s)))'
            % (libid, x, y, U(), refs[0], x, y + 3, FONT, value, x, y + 5, FONT, x, y, FONT, x, y, FONT, x, y, FONT,
               U(), PROJECT, " ".join('(path "%s" (reference "%s") (unit 1))' % (p, r)
                                       for p, r in zip(self.inst_paths, refs))))

    # --- component with per-pin nets
    def place(self, libid, ref, value, x, y, nets, unit=1, deckname=None, footprint="", descr="",
              mpn="", pinmap=None, dnp=False):
        """nets: {pin_name: (kind, netname)}; kind L/G/H/GND/NC.  ref (and unit)
        may be lists of per-instance values (one per self.inst_paths entry).
        pinmap: {deck pin letter: package pin number} recorded in refmap so
        kicad_xcheck can match real-package pin numbers to the deck C/B/E."""
        x, y = snap(x), snap(y)
        sym, pins = get_symbol(libid)
        self.libsyms[libid] = sym
        refs = ref if isinstance(ref, list) else [ref] * len(self.inst_paths)
        refs = [self.xref(r) for r in refs]
        units = unit if isinstance(unit, list) else [unit] * len(self.inst_paths)
        unit = units[0]
        inst = " ".join('(path "%s" (reference "%s") (unit %d))' % (p, r, u)
                        for p, r, u in zip(self.inst_paths, refs, units))
        pinuu = " ".join('(pin "%s" (uuid "%s"))' % (p["num"], U()) for p in pins)
        self.items.append(
            '(symbol (lib_id "%s") (at %.3f %.3f 0) (unit %d) (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp %s) (uuid "%s") '
            '(property "Reference" "%s" (at %.3f %.3f 0) (effects (font (size 1.27 1.27)) (justify left))) '
            '(property "Value" "%s" (at %.3f %.3f 0) (effects (font (size 1.27 1.27)) (justify left))) '
            '(property "Footprint" "%s" (at %.3f %.3f 0) (hide yes) %s) '
            '(property "Datasheet" "" (at %.3f %.3f 0) (hide yes) %s) '
            '(property "Description" "%s" (at %.3f %.3f 0) (hide yes) %s) '
            '(property "MPN" "%s" (at %.3f %.3f 0) (hide yes) %s) '
            '%s (instances (project "%s" %s)))'
            % (libid, x, y, unit, "yes" if dnp else "no", U(), refs[0], x + 3.0, y - 1.3, value, x + 3.0, y + 1.3,
               footprint, x, y, FONT, x, y, FONT, descr, x, y, FONT, mpn, x, y, FONT, pinuu, PROJECT, inst))
        pinnets = {}
        for p in pins:
            if p["unit"] not in (0, unit):
                continue
            px, py = x + p["x"], y - p["y"]
            key = p["name"] if p["name"] in nets else p["num"]
            if key not in nets:
                if p.get("etype") == "no_connect":
                    continue
                raise KeyError("%s pin %s/%s has no net" % (libid, p["name"], p["num"]))
            kind, net = nets[key]
            if kind == "NC":
                self.items.append('(no_connect (at %.3f %.3f) (uuid "%s"))' % (px, py, U()))
                continue
            dx, dy = {0: (-1, 0), 90: (0, 1), 180: (1, 0), 270: (0, -1)}[int(p["ang"]) % 360]
            ex, ey = px + dx * STUB, py + dy * STUB
            self.wire(px, py, ex, ey)
            lab_ang = {(-1, 0): 180, (1, 0): 0, (0, -1): 90, (0, 1): 270}[(dx, dy)]
            if kind == "GND":
                if (dx, dy) == (0, 1):
                    self.power("power:GND", "GND", ex, ey, "#PWR"); net = "GND"
                else:
                    self.label("GND", ex, ey, lab_ang, "G"); net = "GND"
            else:
                self.label(net, ex, ey, lab_ang, kind)
            pinnets[p["num"]] = net
        if deckname:
            if pinmap:
                # deck letter -> net, plus the letter -> package pin number map
                # (a list = one map per instance, e.g. units of a shared quad)
                pm0 = pinmap[0] if isinstance(pinmap, list) else pinmap
                self.refmap[deckname] = dict(refs=refs, pins={k: pinnets[v] for k, v in pm0.items()},
                                             pinmap=pinmap)
            else:
                self.refmap[deckname] = dict(refs=refs, pins=pinnets)
        return pinnets

    _npwr = 0
    def npwr(self):
        Sheet._npwr += 1
        return Sheet._npwr

    def subsheet(self, name, fname, x, y, w, h, pins, sheet_uuid, page):
        """pins: [(name, side 'L'/'R', row, netkind, netname)]"""
        x, y, w, h = snap(x), snap(y), snap(w), snap(h)
        pl = []
        for nm, side, row, kind, net in pins:
            py = y + 2.54 * (row + 1)
            if side == "L":
                px, ang, ex = x, 180, x - STUB
                lab_ang = 180
            else:
                px, ang, ex = x + w, 0, x + w + STUB
                lab_ang = 0
            pl.append('(pin "%s" passive (at %.3f %.3f %d) (uuid "%s") (effects (font (size 1.27 1.27)) (justify %s)))'
                      % (nm, px, py, ang, U(), "right" if side == "L" else "left"))
            self.wire(px, py, ex, py)
            self.label(net, ex, py, lab_ang, kind)
        self.items.append(
            '(sheet (at %.3f %.3f) (size %.3f %.3f) (exclude_from_sim no) (in_bom yes) (on_board yes) (dnp no) (fields_autoplaced yes) '
            '(stroke (width 0.1524) (type solid)) (fill (color 0 0 0 0.0000)) (uuid "%s") '
            '(property "Sheetname" "%s" (at %.3f %.3f 0) (effects (font (size 1.27 1.27)) (justify left bottom))) '
            '(property "Sheetfile" "%s" (at %.3f %.3f 0) (hide yes) (effects (font (size 1.27 1.27)) (justify left top))) '
            '%s (instances (project "%s" (path "%s" (page "%s")))))'
            % (x, y, w, h, sheet_uuid, name, x, y - 0.6, fname, x, y + h + 0.6, " ".join(pl), PROJECT, self.inst_path, page))

    def write(self, root=False):
        hdr = ['(kicad_sch (version %s) (generator "eeschema") (generator_version "9.0") (uuid "%s") (paper "%s")'
               % (VERSION, self.uuid, self.paper),
               '(title_block (title "%s") (date "2026-09-26") (rev "A0") (company "BFDAC") (comment 1 "Locked plant = bfdac_cosim112.cir; generated by utils/gen_kicad.py"))' % self.title]
        libs = "(lib_symbols\n" + "\n".join(dump(s, 1) for s in self.libsyms.values()) + "\n)"
        body = "\n".join(self.items)
        tail = ['(sheet_instances (path "/" (page "1")))' if root else "",
                "(embedded_fonts no)", ")"]
        with open(os.path.join(OUT, self.fname), "w", encoding="utf-8") as f:
            f.write("\n".join(hdr + [libs, body] + tail))

# ---------------------------------------------------------------- netlists
def val(v, params):
    v = v.strip()
    m = re.fullmatch(r"\{(\w+)\}", v)
    if m:
        v = params[m.group(1)]
    try:
        x = float(v)
        if x >= 1000: return "%gk" % (x / 1e3)
        if x < 1e-3: return ("%gn" % (x * 1e9)) if x >= 1e-9 else "%gp" % (x * 1e12)
        return "%g" % x
    except ValueError:
        return v

# ---------------------------------------------------------------- parts (CELL sheet pass, 2026-09-28)
FP = dict(R0402="Resistor_SMD:R_0402_1005Metric", R0603="Resistor_SMD:R_0603_1608Metric",
          C0402="Capacitor_SMD:C_0402_1005Metric", L0603="Inductor_SMD:L_0603_1608Metric",
          SOT23_6="Package_TO_SOT_SMD:SOT-23-6", SOT23_5="Package_TO_SOT_SMD:SOT-23-5", SOT363="Package_TO_SOT_SMD:SOT-363_SC-70-6",
          VSSOP8="Package_SO:VSSOP-8_2.3x2mm_P0.5mm",
          DQE8="bfdac:TI_DQE_X2SON-8_1.4x1.0mm_P0.35mm",
          OPA_DRG8="bfdac:TI_OPA1612_DRG_WSON-8_3x3mm_P0.5mm_EP1.2x2.0mm",
          BUF_DDA8="bfdac:TI_BUF634A_DDA_HSOIC-8_P1.27mm_EP2.95x4.9mm",
          SOIC14="Package_SO:SOIC-14_3.9x8.7mm_P1.27mm",
          SC59="Package_TO_SOT_SMD:SC-59", C0603="Capacitor_SMD:C_0603_1608Metric", C0805="Capacitor_SMD:C_0805_2012Metric",
          R2010="Resistor_SMD:R_2010_5025Metric", CP63="Capacitor_THT:CP_Radial_D6.3mm_P2.50mm",
          CP8="Capacitor_THT:CP_Radial_D8.0mm_P3.50mm", R1206="Resistor_SMD:R_1206_3216Metric",
          R2512="Resistor_SMD:R_2512_6332Metric", C1206="Capacitor_SMD:C_1206_3216Metric",
          SOIC8="Package_SO:SOIC-8_3.9x4.9mm_P1.27mm", TSSOP16="Package_SO:TSSOP-16_4.4x5mm_P0.65mm",
          WQFN32="Package_DFN_QFN:QFN-32-1EP_5x5mm_P0.5mm_EP3.45x3.45mm",
          MSOP12EP="Package_SO:MSOP-12-1EP_3x4.039mm_P0.65mm_EP1.651x2.845mm_ThermalVias",
          SOT223="Package_TO_SOT_SMD:SOT-223", SOD123="Diode_SMD:D_SOD-123",
          RARR0612="Resistor_SMD:R_Array_Convex_4x0612", LCC8="Package_LCC:Analog_LCC-8_5x5mm_P1.27mm",
          CP5="Capacitor_THT:CP_Radial_D5.0mm_P2.50mm", FILM5="Capacitor_THT:C_Rect_L7.2mm_W7.2mm_P5.00mm_FKS2_FKP2_MKS2_MKP2",
          FILM5S="Capacitor_THT:C_Rect_L7.2mm_W2.5mm_P5.00mm_FKS2_FKP2_MKS2_MKP2",
          CCHD957="bfdac:Crystek_CCHD-957", TPBGA24="bfdac:Micron_T-PBGA-24_6x8mm_Layout5x5_P1.0mm",
          ADI_WSOIC16="bfdac:ADI_21-0042B_16_WSOIC", ADI_LFCSP10="bfdac:ADI_CP-10-9_LFCSP-10",
          TI_RGY24="bfdac:TI_RGY_VQFN-24_3.5x5.5mm_P0.5mm_EP",
          SOIC16W="Package_SO:SOIC-16W_7.5x10.3mm_P1.27mm", SOIC16="Package_SO:SOIC-16_3.9x9.9mm_P1.27mm", WSON6="Package_SON:WSON-6-1EP_2x2mm_P0.65mm_EP1x1.6mm",
          TI_DSE6="Package_SON:WSON-6_1.5x1.5mm_P0.5mm",
          TI_RGC64="Package_DFN_QFN:QFN-64-1EP_9x9mm_P0.5mm_EP3.8x3.8mm",
          HDR1x4="Connector_PinHeader_2.54mm:PinHeader_1x04_P2.54mm_Vertical",
          SOT23="Package_TO_SOT_SMD:SOT-23", LED0603="LED_SMD:LED_0603_1608Metric", C1210="Capacitor_SMD:C_1210_3225Metric",
          CPOLY8="Capacitor_SMD:CP_Elec_8x10.5", HDR2x10="Connector_PinHeader_2.54mm:PinHeader_2x10_P2.54mm_Vertical",
          HDR2x7_2MM="Connector_PinHeader_2.00mm:PinHeader_2x07_P2.00mm_Vertical",
          MINIFIT4="Connector_Molex:Molex_Mini-Fit_Jr_5566-04A2_2x02_P4.20mm_Vertical",
          MINIFIT6="Connector_Molex:Molex_Mini-Fit_Jr_5566-06A2_2x03_P4.20mm_Vertical",
          MINIFIT8="Connector_Molex:Molex_Mini-Fit_Jr_5566-08A2_2x04_P4.20mm_Vertical",
          MINIFIT24="Connector_Molex:Molex_Mini-Fit_Jr_5566-24A2_2x12_P4.20mm_Vertical",
          FX18="BFDAC_Footprints:Hirose_FX18-40S-0.8SV_2x20_P0.80mm_Vertical",
          REDCUBE="BFDAC_Footprints:Wuerth_REDCUBE_WP-BUFU-M4_PressFit",
          PHDR2x4="Connector_PinHeader_2.54mm:PinHeader_2x04_P2.54mm_Vertical",
          G6K2FY="Relay_SMD:Relay_DPDT_Omron_G6K-2F-Y")
def _ohms(s):
    """'59.0' / '4.99k' / '1M' -> ohms (Value-field notation used on the refs sheet)."""
    s = s.strip().lower()
    mult = 1e6 if s.endswith("m") else 1e3 if s.endswith("k") else 1.0
    return float(s.rstrip("mk")) * mult

def precision_r(value, code):
    """0603 precision position (bom 'RG1608P 0.1 %' class) -> best tolerance available per value (user ruling 2026-10-08
    23:44, Susumu vs Vishay): Susumu RG1608N-W 0.05 % / 10 ppm for 47 R..475k (datasheet range of the W grade),
    Vishay TNPW0603 B 0.1 % / 25 ppm below 47 R (Susumu only offers 0.1 % / 50 ppm there), Susumu RG1608P-B
    0.1 % / 25 ppm above 475k.  `code` = 4-char value code (same format for both vendors: 10R0, 1000, 4991)."""
    r = _ohms(value)
    if r < 47:
        return "TNPW0603%sBEEA" % code, "Vishay TNPW e3 0.1 % 25 ppm (Susumu W grade starts at 47 R)"
    if r <= 475e3:
        return "RG1608N-%s-W-T1" % code, "Susumu RG1608N 0.05 % 10 ppm"
    return "RG1608P-%s-B-T5" % code, "Susumu RG1608P 0.1 % 25 ppm (W grade ends at 475k)"

# PACKAGE POLICY (user 2026-10-08 23:51): 0603 is the default; 0402 ONLY out of necessity.  The only 0402 positions are the
# per-cell parts below (128 cells x 7 passives: array area + the FF-pin decoupling / base-stopper loop length).  Revisit
# once the cell layout is drawn - if the pitch is set by the SOIC-14 / DQE X2SON-8 anyway, rs/rp can grow to 0603 for free.
CELL_PARTS = {   # key: (value, footprint, MPN, description)
    "ff":   ("SN74LVC1G74", FP["DQE8"], "SN74LVC1G74DQER", "RTZ reclock D-FF, true Q/Qb, one per cell; DQE X2SON-8 pin map per TI datasheet Fig. 5-2; bom 1.2"),
    "fb":   ("120R@100MHz", FP["L0603"], "BLM18PG121SN1D", "per-FF 3.3 V rail isolation bead (bom 1.2 L/C4xx)"),
    "cff":  ("100n", FP["C0402"], "GRM155R71C104KA88D", "FF local decoupling, X7R 16 V (0402 by necessity: shortest loop at the FF VCC pin, x128)"),
    "rs":   ("1.35k", FP["R0402"], "TNPW04021K35FEEA", "base series rs, thin film 1 % (bom 1.2 R43x) (0402 by necessity: cell array area, x256)"),
    "rp":   ("301", FP["R0402"], "TNPW0402301RFEEA", "base shunt rp to VCM, thin film 1 % (bom 1.2 R44x) (0402 by necessity: cell array area, x256)"),
    "rstop": ("10", FP["R0402"], "TNPW040210R0FEEA", "base stopper, thin film 1 % (bom 2 Rs1/Rs2) (0402 by necessity: sits on the base pin, x256)"),
    "rt":   ("750", FP["R0603"], "RG1608N-7500-W-T1", "tail set resistor, Susumu RG1608N 0.05 % 10 ppm (bom 2 Rt; was RG1608P 0.1 %, best-tolerance ruling 2026-10-08)"),
    "rsum": ("10k", FP["R0603"], "RG1608N-1002-W-T1", "replica-ff sum resistor Rr1, Susumu RG1608N 0.05 % 10 ppm (bom 3; was 0.1 %)"),
    "pair": ("DMMT5551", FP["SOT363"], "DMMT5551-7", "same-die matched NPN steering pair (bom 2 Q1a/Q1b)"),
    "tail": ("THAT300", FP["SOIC14"], "300S14-U", "tail transistor, 1/4 of a THAT300 quad shared by 4 adjacent cells (bom 2 Q4)"),
}
CORE_PARTS = {  # CORE sheet pass 2026-09-28 (bom 3)
    "nmos": ("Si1555DL", FP["SOT363"], "Si1555DL-T1-GE3", "Vishay complementary pair, N half used; P half (unit B) tied to GND"),
    "rg":   ("100", FP["R0603"], "TNPW0603100RFEEA", "cascode gate stopper Rg5/Rg6, thin film 1 % (bom 3)"),
    "qr":   ("2SA1036K", FP["SC59"], "2SA1036KT146Q", "replica-ff PNP V-I (bom 3 QR)"),
    "re":   ("35.7", FP["R0603"], "TNPW060335R7BEEA", "replica emitter degeneration; deck 35.3 -> E96 35.7 (+1.1 %). Vishay TNPW0603 0.1 % 25 ppm: the Susumu W (0.05 %) grade starts at 47 R so RG1608N-35R7-W does not exist  ** OPTION: 2 x 71.5 R RG1608N-71R5-W in parallel = 35.75 keeps 0.05 % **"),
    "rsh":  ("156", FP["R0603"], "RG1608N-1560-W-T1", "replica node shunt Rsh, deck 156.25 -> 156 E96 (bom 3), Susumu RG1608N 0.05 % 10 ppm (was 0.1 %)"),
    "csh":  ("50p", FP["C0603"], "GRM1885C1H500JA01D", "replica node C, C0G 50 V 5 %"),
    "rpad": ("1.13k", FP["R1206"], "RQ73C2B1K13BTD", "padding source resistor: 4 x 1.13k in parallel = 282.5 (deck 286; PADB servo sets the 50 mA), 12.5 mA / 0.18 W each = 36 % of the TE RQ73 1206 0.5 W rating; precision thin film 0.1 % 10 ppm (RULED user 2026-10-09, DigiKey-verified 0.5 W) - thin film required for excess noise at 14 V DC"),
    "cpadb": ("100u", FP["CP63"], "UKL1C101MED", "padb bypass, Nichicon UKL low-leakage 16 V 6.3x11"),
    "cbus": ("47n", FP["C1206"], "GRM3195C1H473JA01D", "bus capacitor, C0G 50 V 1206 (bom 3 C_bus)"),
    "rbleed": ("910", FP["R0603"], "TNPW0603910RFEEA", "bus bleed 1.9 mA, thin film 1 %"),
    "rbias": ("100", FP["R0603"], "TNPW0603100RFEEA", "q4_base feed from 1.25 V ref (bom 2 Rb)"),
    "cq4":  ("220u", FP["CP8"], "UKL1C221MPD", "q4_base bypass, Nichicon UKL low-leakage 16 V 8x11.5 (bom 2 C_q4)"),
}
FPGA_PARTS = {  # FPGA interface + clock tree sheet, 2026-09-28 (bom 1.1 / 1.3)
    "j":     ("ADM6-60", "bfdac:Samtec_ADM6-60-01.5-L-4-2-A", "ADM6-60-01.5-L-4-2-A-TR", "Samtec AcceleRate HD 4x60 0.635 mm terminal for the Alinx ACVU13P module; footprint from the Samtec print Rev A (datasheets/samtec_adm6_footprint.pdf)"),
    "xo":    ("49.152 MHz", FP["CCHD957"], "CCHD-957-25-49.152", "Crystek CCHD-957 XO, 48k family (2nd source NDK NZ2520SDA 49.152); pinout + footprint verified Rev N 2026-10-08  ** was: REVIEW pinout **"),
    "xo2":   ("45.1584 MHz", FP["CCHD957"], "CCHD-957-25-45.1584", "Crystek CCHD-957 XO, 44.1k family; pinout + footprint verified Rev N 2026-10-08"),
    "inv":   ("SN74LVC1G04", FP["SOT23_5"], "SN74LVC1G04DBVR", "clk_sel inverter: Y301 E/D = !clk_sel, Y302 E/D = clk_sel (mux at the XO enables, bom item 15 option 2)"),
    "buf":   ("SN74LVC1G125", FP["SOT23_5"], "SN74LVC1G125DBVR", "FPGA mclk copy off the XO net (jitter irrelevant: FF retimes); 3.3 -> 1.8 V divider into B65_L12_P (J6-C30 / AW28, GC) as LVCMOS18"),
    "fan":   ("LMK1C1108", FP["TSSOP16"], "LMK1C1108PWR", "1:8 LVCMOS fanout; U302 root -> U304..U311 leaves -> 64 FF clocks (bom 1.1)"),
    "rser":  ("33", FP["R0603"], "CRCW060333R0FKEA", "series termination at every clock driver pin (bom 1.1 R3xx)"),
    "rdivs": ("100", FP["R0603"], "CRCW0603100RFKEA", "mclk divider series (3.3 V x 120/220 = 1.8 V, ~55 R source)"),
    "rdivp": ("120", FP["R0603"], "CRCW0603120RFKEA", "mclk divider shunt"),
    "rpu":   ("10k", FP["R0603"], "CRCW060310K0FKEA", "logic pull-up / pull-down (1G, clk_sel default low = Y301 48k family)"),
    "cdec":  ("100n", FP["C0603"], "GRM188R71C104KA01D", "clock-buffer supply decoupling, one per VDD/Vcco pin"),
    "cbulk": ("10u", FP["C0805"], "GRM21BR61A106KE19L", "clock rail bulk, X5R 10 V"),
    "flash": ("MT25QU02G", FP["TPBGA24"], "MT25QU02GCBB8E12-0SIT", "2 Gb 1.8 V quad SPI NOR coefficient store; 4 on one bus / 4 CS = 8 Gb = 90 filters at 10M taps 18-bit mirrored (bom 18/18a); pin config 8 = dedicated RESET# (A4, internal pull-up) + HOLD# on DQ3; ball map + T-PBGA-24 footprint verified Rev C 2026-10-08"),
    "rpu18": ("10k", FP["R0603"], "CRCW060310K0FKEA", "flash S# / W# / HOLD# pull-up to V18 (deselected while the FPGA configures)"),
    "cdec18": ("100n", FP["C0603"], "GRM188R71C104KA01D", "flash VCC decoupling, one per device"),
    "axc8":   ("SN74AXC8T245", FP["TI_RGY24"], "SN74AXC8T245RHLR", "octal 1.8->3.3 V translator, DIR1/DIR2 = VCCA (A->B), /OE = GND, PAD to GND; 8 per channel, placed at the SoM connectors (FPGA side); A on V18 (SoM VCCIO), B on V33FF (bom 1.2 U440-U455, VQFN ruled 2026-10-10)"),
    "cxa":    ("100n", FP["C0603"], "GRM188R71C104KA01D", "AXC8T245 VCCA decoupling, one per device"),
    "cxb":    ("100n", FP["C0603"], "GRM188R71C104KA01D", "AXC8T245 VCCB decoupling, one per device (island side of the bead)"),
    "fbx":    ("120R@100MHz", FP["L0603"], "BLM18PG121SN1D", "per-octal V33FF island bead (bom 1.2 U440-U455 rule; value from the item-11 SSN deck, same part as the per-FF bead until then)"),
}
SOM_PARTS = {  # SoM carrier sheet 2026-10-07: remaining ACVU13P connectors, 12 V feed, JTAG, boot straps
    "j":      ("ADM6-60", "bfdac:Samtec_ADM6-60-01.5-L-4-2-A", "ADM6-60-01.5-L-4-2-A-TR", "Samtec AcceleRate HD 4x60 0.635 mm terminal, 1.5 mm lead style, alignment pins; mates ADF6-60-03.5 on the SoM (5 mm stack); footprint from the Samtec print Rev A (datasheets/samtec_adm6_footprint.pdf)"),
    "jpwr":   ("12V IN", FP["MINIFIT6"], "39-28-1063", "Molex Mini-Fit Jr 6-way vertical header: SoM +12 V feed from the 12 V switcher (3 x 12 V + 3 x GND, 9 A/contact class; SoM planning figure 15 A at 12 V, user 2026-10-10 - 2x2 was at its limit). V12SOM is SoM-only: nothing else on this board uses 12 V  ** VERIFY MPN / mating housing 39-01-2060 **"),
    "cpoly":  ("220u", FP["CPOLY8"], "25SVPF220M", "Panasonic OS-CON 220 uF 25 V polymer, SoM 12 V bulk at the connectors"),
    "c10u25": ("10u", FP["C1206"], "GRM31CR71E106KA12L", "SoM 12 V ceramic, X7R 25 V"),
    "jtag":   ("JTAG", FP["HDR2x7_2MM"], "87832-1420", "Molex Milli-Grid 2x7 2.00 mm shrouded header, Xilinx 14-pin JTAG cable pinout (1/3/5/7/9/11/13 GND, 2 VREF, 4 TMS, 6 TCK, 8 TDO, 10 TDI)  ** VERIFY MPN **"),
    "rstrap": ("4.7k", FP["R0603"], "CRCW06034K70FKEA", "BOOT_M[2:0] mode strap, DNP by default - the SoM straps its own boot mode; populate only if the ACVU13P manual says the carrier must  ** VERIFY **"),
}
CTRL_PARTS = {  # control-plane sheet 2026-10-07 (bom 20 / 21): AP isolation barrier, temp sensors, LEDs
    "isoC":   ("MAX22445C", FP["ADI_WSOIC16"], "MAX22445CAWE+", "3/1 digital isolator, default-HIGH outputs: U501 SPI (SCLK/CS_N/MOSI AP->FPGA, MISO back) - CS_N reads deselected while the AP side is unpowered. Side A = AP (VAP_IO), side B = FPGA (V18, 1.71 V capable) (bom 21, ruled 2026-10-09)"),
    "isoF":   ("MAX22445F", FP["ADI_WSOIC16"], "MAX22445FAWE+", "3/1 digital isolator, default-LOW outputs: U502 I2S, sides swapped for FPGA-as-master - side A = FPGA (V18): BCLK/LRCLK/FPGA_IRQ_N -> AP; side B = AP (VAP_IO): SDATA -> FPGA. SDATA = silence with the AP off (bom 21, ruled 2026-10-09)"),
    "iso1":   ("MAX22444C", FP["ADI_WSOIC16"], "MAX22444CAWE+", "4/0 digital isolator, default-HIGH: U503 AP_RST_N -> EXT_RST_N (released with an open header), IN2..IN4 spare (tied to GNDA), OUT2..OUT4 NC; pin 7 I.C. to GNDA (datasheet: open / GNDA / VDDA allowed) (bom 21, ruled 2026-10-09)"),
    "isoi2c": ("ISO1640", FP["SOIC8"], "ISO1640BDR", "bidirectional I2C isolator: TMP117 sensor bus (side 1, V33D, 3.0-5.5 V) <-> AP (side 2, VAP_IO, 2.25-5.5 V) (bom 20, ruled 2026-10-05; ISO1610 was a non-existent MPN, corrected 2026-10-08). VAP_IO MUST be >= 2.25 V - a 1.8 V AP needs a different isolator or a level shifter"),
    "tmp":    ("TMP117", FP["WSON6"], "TMP117AIDRVR", "+-0.1 C sensor; 4 on one bus via ADD0 (GND 0x48, V+ 0x49, SDA 0x4A, SCL 0x4B); placement per bom 20"),
    "jap":    ("AP DIG", FP["FX18"], "FX18-40S-0.8SV", "left-edge mezz DIGITAL connector (user 2026-10-13: ~30 mm board-to-board stack, split power/signal): Hirose FX18-40 socket (0.8 mm, mated heights 10-45 mm family - VERIFY exact SV/H variant pair for 30 mm mated; PCIe-4-class SI, 0.5 A/pin). Carries the AP-domain set - isolated SPI / I2S / IRQ / RST / I2C + SOM_PG, VAP_IO, with GND_AP beside every signal (absorbs old J501 2x10 header). 12 V SoM feed is on J507/J508 REDCUBE terminals  ** VERIFY MPN / footprint **"),
    "rc12v":  ("12V",    FP["REDCUBE"], "746xxxxx", "Wuerth REDCUBE WP-BUFU-class press-fit terminal, internal thread M4: SoM +12 V board-to-board feed (15 A planning figure - REDCUBE is 60-100 A+ class, doubles as the 30 mm board standoff; 12 V left Mini-Fit-class plugs because no blade mezz reaches 30 mm)  ** VERIFY MPN / hole spec **"),
    "rcgnd":  ("GND",    FP["REDCUBE"], "746xxxxx", "Wuerth REDCUBE WP-BUFU-class press-fit terminal, internal thread M4: 12 V return / board GND, conductive standoff to the AP/tube board  ** VERIFY MPN / hole spec **"),
    "npn":    ("MMBT3904", FP["SOT23"], "MMBT3904LT1G", "LED sink driver from a 1.8 V FPGA IO (LVCMOS18 cannot drive a 2 V LED directly)"),
    "led":    ("GREEN", FP["LED0603"], "APT1608SGC", "Kingbright 0603 green LED, ~2 mA"),
    "rled":   ("470", FP["R0603"], "CRCW0603470RFKEA", "LED current set from V33D (~2 mA)"),
    "rbase":  ("4.7k", FP["R0603"], "CRCW06034K70FKEA", "LED driver base resistor (1.8 V IO -> ~230 uA)"),
    "rpu2k2": ("2.2k", FP["R0603"], "CRCW06032K20FKEA", "I2C pull-up (both barrier sides)"),
    "rpu10k": ("10k", FP["R0603"], "CRCW060310K0FKEA", "AP_RST_N pull-up: open header = run"),
    "c100n":  ("100n", FP["C0603"], "GRM188R71C104KA01D", "isolator / sensor decoupling, one per supply pin"),
}
OUT_PARTS = {  # output-routing sheet 2026-10-07 (bom 7): K4 mute only - level is digital, K1/K2 struck
    "k4":    ("G6K-2F-Y DC3", FP["G6K2FY"], "G6K-2F-Y DC3", "K4 line mute, Omron G6K-2F-Y 2 Form C single-side stable, 3 V coil 91 R / 33.0 mA / ~100 mW held (en-g6k p.3, verified 2026-10-10; must operate 80 % max, release 10 % min, 150 % max) on the dedicated 3.3 V V33RLY rail (U603): 3.3 V - ULN V_sat ~0.3 V = 3.0 V = 100 % rated (DC12 on V12SOM struck 2026-10-10: 12 V is SoM-only), bifurcated crossbar Ag/Au-alloy contacts, P-level 10 uA @ 10 mV, SMD; pins (KiCad Relay:G6K-2 graphics = user's GN reading): coil 1(+)/8, COM 3/6, NC 2/7, NO 4/5; NC = XLR pin to GND, NO = I/V output, coil off = muted (bom 7, 2026-10-08). Ambient limit 70 C - rear-panel edge placement, verify with the TMP117 ambient sensor"),
    "uln":   ("ULN2003V12", FP["SOIC16"], "ULN2003V12DR", "7-ch low-side relay driver, 1.8 V-compatible inputs, integrated flyback to COM = V33RLY; ch 1/2 = K601/K602, unused inputs to GND; SOIC-16 D (ULN2003A pinout)"),
    "ldorly": ("TPS7A2033", FP["SOT23_5"], "TPS7A2033PDBVR", "dedicated relay-coil LDO: 3.3 V fixed, 300 mA, SOT-23-5, from the 4.3 V pre-reg V4P3 (1.0 V headroom; V_DO 140 mV max at 300 mA), load 2 x 33 mA coils + flyback. EN = UNMUTE_EN (V_EN(HI) 0.9 V max vs 1.65 V min from U602; 500k internal pull-down = rail absent until DONE AND PG_ALL AND GPIO - second hardware mute path independent of U601; t_start 0.75-1.15 ms). Keeps coil steps / flyback off V33D (TMP117, ISO1640). TI SBVS338H, datasheets/TI_TPS7A20.pdf, 2026-10-10"),
    "c1u":   ("1u", FP["C0603"], "GRM188R61E105KA12D", "U603 IN / OUT capacitors (TPS7A20 min 1 uF ceramic), X5R 25 V 0603"),
    "and3":  ("SN74LVC1G11", FP["SOT23_6"], "SN74LVC1G11DBVR", "unmute gate at V18: RLY_LINE_MUTE (FPGA GPIO) AND FPGA_DONE (J2 A1, config complete) AND PG_ALL (wired-AND rail power-good, POWER sheet) -> UNMUTE_EN (bom 7, 17(m))"),
    "rbo":   ("10", FP["R0603"], "TNPW060310R0BEEA", "output build-out outside the TIA loop (cable C / short isolation), Vishay TNPW0603 0.1 % 25 ppm (Susumu 0.1 % below 47 R is 50 ppm only); -0.14 dB into 600 R, matched per leg (bom 7)"),
    "rpu":   ("10k", FP["R0603"], "CRCW060310K0FKEA", "spare 10k pull-up (was the PG_A15 placeholder; the real PG_ALL pull-up R1701 lives on the POWER sheet)"),
    "c100n": ("100n", FP["C0603"], "GRM188R71C104KA01D", "gate decoupling"),
    "xlr":   ("NC3MD-H-B", "bfdac:Neutrik_NC3MD-H", "NC3MD-H-B", "Neutrik NC3MD-H-B 3-pole male XLR receptacle, D-size zinc die-cast shell, BLACK (KTL), gold contacts, horizontal PCB mount, latch lock - LOCKED 2026-10-10 (user: no plastic, black; board perpendicular to the rear panel = horizontal). 1 shield, 2 hot, 3 cold, G shell. Footprint from Neutrik drawing S1-NC3MD-H (datasheets/NC3MD-H-B)"),
}
IV_PARTS = {  # IV sheet pass 2026-09-28 (bom 4)
    "opamp": ("OPA1612", FP["OPA_DRG8"], "OPA1612AIDRGR", "TIA front amp; DRG WSON-8 with thermal pad tied to V-; dual footprint reserved for NPAR=2 fallback, unit B idle as follower to GND (bom 4)"),
    "buf":   ("BUF634A", FP["BUF_DDA8"], "BUF634AIDDAR", "output buffer inside the TIA loop; DDA HSOIC-8 PowerPAD and 13-via array tied to V-; BW pin to V- (max bandwidth) (bom 4)"),
    "rf":    ("270", FP["R1206"], "RG3216N-2700-W-T1", "R_f, Susumu RG3216N 0.05 % 10 ppm 1206 1/4 W (RG3216 codes are always 4-digit: 2700, was 271); ~5 Vrms across -> ~95 mW (bom 4)"),
    "cf":    ("1.3n", FP["C0603"], "GRM1885C1H132JA01D", "C_f on the buffer output, C0G 50 V (bom 4)"),
    "roff_p": ("536", FP["R0603"], "RA73F1J536RBTD", "R_off p = 4 x 536 (E96) in parallel = 134.0 (+0.75 %, DC trim); ~83 mA from +15F -> 21 mA / 0.23 W each = 46 % of the TE RA73 0603 AlN-substrate 0.5 W @70C rating (datasheet 1773270-3, user 2026-10-09); 0.1 % 25 ppm thin film. LAYOUT: enlarged copper per the RA73 mounting note; heat zone per bom items 13/14. Fallback 8 x 1.07k = 133.75 at 23 %"),
    "roff_m": ("464", FP["R0603"], "RA73F1J464RBTD", "R_off m = 4 x 464 (E96) in parallel = 116.0; ~95 mA from +15F -> 24 mA / 0.26 W each = 52 % of the TE RA73 0603 AlN 0.5 W rating; 0.1 % 25 ppm thin film (user-verified at DigiKey 2026-10-09). LAYOUT: enlarged copper per the RA73 mounting note. Fallback 8 x 931 = 116.4 at 26 %"),
    "ccol":  ("12n", FP["C0805"], "GRM2165C1H123JA01D", "summing-node RTZ slam absorber, C0G 50 V 0805 (bom 3 C_col)"),
    "cdec":  ("100n", FP["C0603"], "GRM188R71H104KA93D", "op-amp / buffer supply decoupling, X7R 50 V (kicad-only)"),
    # --- V_ROFF POL LDO on this sheet (dual-mono 2026-10-12, bom 17(l)/(m3): LDO sits with its R_off load)
    "ldo":   ("LT3045", FP["MSOP12EP"], "LT3045EMSE#PBF", "V_ROFF +15F LDO (180 mA into R_off): SET = 100 uA x 150k = 15.0 V, EN/UV->IN, ILIM->GND, PGFB 442k/10k + 1 nF (+0.30 V trip = -10 %), PG open-collector -> PG_ALL"),
    "rp01":  ("", FP["R0603"], "TNPW0603%sFEEA", "TNPW 1 % 25 ppm (Value = resistance, MPN = 4-char code)"),
    "c1n":   ("1n", FP["C0603"], "GRM1885C1H102JA01D", "PGFB node HF cap, C0G 50 V"),
    "c4u7":  ("4.7u", FP["C0805"], "GRM21BR71E475KA73L", "LT3045 C_SET, X7R 25 V"),
    "cldo":  ("10u", FP["C1206"], "GRM31CR71E106KA12L", "LT3045 IN/OUT ceramic, X7R 25 V"),
    "c100u": ("100u", FP["CP63"], "UKL1C101MED", "V_ROFF rail bulk, Nichicon UKL low-leakage 16 V"),
    "fbv":   ("600R@100MHz", FP["L0603"], "BLM18PG601SN1D", "V_ROFF output ferrite (the R_off injection filter's HF leg, bom 17(l) FB9)"),
    "tp1k":  ("1.00k", FP["R0603"], "TNPW06031K00FEEA", "1k probe-isolation stub: reduces loading, does not eliminate it; 10 pF gives an approximately 16 MHz pole. Use a low-capacitance active probe for settling tests; never terminate in 50 ohms"),
}

REFS_PARTS = {  # refs sheet pass 2026-10-06 (bom 9): REF7050 -> RC -> FET buffer -> dividers -> OPA1612 buffers / servos
    "ref":    ("REF7050", FP["LCC8"], "REF7050QFKHT", "TI REF7050 5.000 V, 2 ppm/C, 0.23 ppm p-p; LCCC-8 hermetic (LT-drift spec'd), ONE PER BOARD (R channel REF5 from this part); U-slot tongue, see bom 9"),
    "rin":    ("10", FP["R0603"], "TNPW060310R0FEEA", "REF7050 VIN feed from P15A (with C 10u = 1.6 kHz)"),
    "crefin": ("10u", FP["C1206"], "GRM31CR71E106KA12L", "REF7050 VIN bulk, X7R 25 V"),
    "c100n":  ("100n", FP["C0603"], "GRM188R71H104KA93D", "decoupling, X7R 50 V"),
    "crefo":  ("10u", FP["C1206"], "GRM31CR71E106KA12L", "REF7050 OUTF cap (1-100 uF per datasheet), X7R 25 V"),
    "rrc":    ("4.99k", FP["R0603"], "RG1608N-4991-W-T1", "reference RC filter R, Susumu RG1608N 0.05 % 10 ppm (was 0.1 %); (4.99k + 10u film = 3.2 Hz; FET buffer follows so leakage/I_b errors stay < 0.01 %)"),
    "crc":    ("10u", FP["FILM5"], "MKS2B051001N00KSSD", "reference RC filter C, WIMA MKS2 10 uF 50 V film (no electrolytic leakage drift, no class-II piezo)  ** VERIFY MPN **"),
    "fetamp": ("OPA1656", FP["SOIC8"], "OPA1656ID", "FET-input dual: A = REF5F buffer (I_b 10 pA vs 4.99k), B = CASB2 servo (bom 9 ruling 2026-10-01, gate 2026-10-02)"),
    "fetamp2": ("OPA1656", FP["SOIC8"], "OPA1656ID", "FET-input dual: PADB current servo (A = Rpad drop diff-amp, B = integrator) - bom 9 derived req. 4"),
    "opamp":  ("OPA1612", FP["OPA_DRG8"], "OPA1612AIDRGR", "1.1 nV/rtHz dual: reference buffers / servo error amps; DRG WSON-8 thermal pad tied to V- (bom 9)"),
    "ldo":    ("LT3045", FP["MSOP12EP"], "LT3045EMSE#PBF", "500 mA ultra-low-noise LDO; SET = 100 uA x R_SET or driven (VE1); EN/UV->IN, ILIM->GND, PGFB divider MANDATORY (below +0.30 V the SET current jumps to 2 mA - PGFB->GND pegs the output at the rail!), PG open-collector -> PG_ALL"),
    "ldo_n":  ("LT3094", FP["MSOP12EP"], "LT3094EMSE#PBF", "-500 mA negative ultralow-noise LDO; SET = 100 uA x R_SET to GND gives -Vout; PGFB trips at -0.30 V so the SAME OUT->PGFB->GND divider as the positive parts works (442k/10k = -13.6 V trip on -15 V); EN/UV->IN, ILIM->GND, VIOC->GND (unused), PG -> PG_ALL"),
    "rp01":   ("", FP["R0603"], "%s", "precision 0603, MPN chosen per value by precision_r() (Susumu RG1608N 0.05 % / Vishay TNPW 0.1 % / Susumu RG1608P 0.1 %)"),
    "acas":   ("", FP["RARR0612"], "ACASA%s%sP1AT", "Vishay ACAS 0612 AT matched array (2 x R1 + 2 x R2; abs 0.1 %, ratio 0.05 %, tracking 5 ppm/K): divider pair used, other two elements NC  ** VERIFY MPN coding / specs **"),
    "rser":   ("10", FP["R0603"], "TNPW060310R0FEEA", "buffer output series R (cap-load isolation)"),
    "cout":   ("47u", FP["CP5"], "UKL1E470MDD", "reference node bulk, Nichicon UKL low-leakage 25 V 5x11 (with 1u C0G)"),
    "c1u":    ("1u", FP["C1206"], "GRM31C5C1E105JA01L", "reference node HF, C0G 25 V 1206"),
    "c100u":  ("100u", FP["CP63"], "UKL1C101MED", "node bulk, Nichicon UKL low-leakage 16 V 6.3x11"),
    "cfilm1u": ("1u", FP["FILM5S"], "MKS2C041001F00KSSD", "servo integrator C, WIMA MKS2 1 uF 63 V film  ** VERIFY MPN **"),
    "c1n":    ("1n", FP["C0603"], "GRM1885C1H102JA01D", "CASB2 sense mid-node C, C0G 50 V"),
    "c4u7":   ("4.7u", FP["C0805"], "GRM21BR71E475KA73L", "LT3045 SET cap (+3V3A rail only), X7R 25 V"),
    "cldo":   ("10u", FP["C1206"], "GRM31CR71E106KA12L", "LT3045 IN/OUT ceramic, X7R 25 V"),
    "npn223": ("BCP56-16", FP["SOT223"], "BCP56-16,115", "NPN 80 V 1 A SOT-223: VFR sink pass (1.4 V x 150 mA = 0.21 W - the one real power node on this sheet)"),
    "npn23":  ("BC817-40", FP["SOT23_5"].replace("SOT-23-5", "SOT-23"), "BC817-40,215", "NPN 45 V 500 mA SOT-23: VCM upper follower (3.3 V rail, I_q ~41 mA -> 0.08 W)"),
    "pnp23":  ("BC807-40", FP["SOT23_5"].replace("SOT-23-5", "SOT-23"), "BC807-40,215", "PNP 45 V 500 mA SOT-23: VCM lower follower (I_q + 24 mA load -> 0.08 W)"),
    "bc847":  ("BC847B", FP["SOT23_5"].replace("SOT-23-5", "SOT-23"), "BC847B,215", "V_be multiplier for the VCM class-A pair (thermally coupled to Q903/Q904)"),
    "bat54":  ("BAT54", FP["SOT23_5"].replace("SOT-23-5", "SOT-23"), "BAT54,215", "VFR error-amp output clamp: Q901 base >= -0.4 V (V_EBO 5 V) and PI anti-windup during start-up (refs_loop vfr tran2)"),
    "qcomp":  ("2SA1036K", FP["SC59"], "2SA1036KT146Q", "QR1 V_eb compensator, diode-connected, same type/lot as Q7/Q8, placed touching them (bom 17(k)(d))"),
    "z6v2":   ("BZT52C6V2", FP["SOD123"], "BZT52C6V2-7-F", "CASB2 servo output clamp (start-up gate protection)"),
    "z2v7":   ("BZT52C2V7", FP["SOD123"], "BZT52C2V7-7-F", "PADB servo output clamp: I_pad(max) = (2.7 - Vgs + 15)/286 ~ 57 mA"),
    "r1pct":  ("", FP["R0603"], "TNPW0603%sFEEA", "Vishay TNPW e3 thin film 1 % 25 ppm (value in Value field; 4-char Vishay code in the MPN)"),
}
PWR_PARTS = {  # POWER sheet pass 2026-10-12 (bom 17(l)-17(m3)): dual-mono POL regulators + PG_ALL wired-AND
    "lt3045":  ("LT3045", FP["MSOP12EP"], "LT3045EMSE#PBF", "500 mA ultralow-noise LDO; SET = 100 uA x R_SET to GND (150k = 15.0 V, 33.2k = 3.32 V; RG1608N 0.05 %) or driven by VE1_SET (REFS sheet). EN/UV->IN, ILIM->GND, PGFB divider per rail + 1 nF (bom 17(m): 887k/20k for +15 V, 412k/20k VE1, 180k/20k for 3.3 V class), PG open-collector -> PG_ALL, OUTS Kelvin to the output cap"),
    "lt3094":  ("LT3094", FP["MSOP12EP"], "LT3094EMSE#PBF", "-500 mA negative ultralow-noise LDO: SET = 100 uA x R_SET to GND gives -Vout (150k = -15 V); EN/UV->IN, ILIM->GND, VIOC->GND (unused), PGFB divider OUT->PGFB->GND + 1 nF (** VERIFY negative-rail PGFB polarity/threshold vs SLVSxxx **), PG -> PG_ALL"),
    "adp7158": ("ADP7158-3.3", FP["ADI_LFCSP10"], "ADP7158ACPZ-3.3-R7", "2 A 1.7 nV/rtHz LDO for V33FF (CP-10-9 LFCSP): VREG + EN -> VIN (autostart), REF_SENSE->REF, BYP/REF/VREG 1 uF, VIN 10 uF, VOUT 10 uF ceramic, EP->GND. Pin map verified Rev C 2026-10-12"),
    "tps3890": ("TPS389001", FP["TI_DSE6"], "TPS389001DSET", "V33FF supervisor, adjustable VITN = 1.15 V: 162k/100k divider = ~3.01 V trip; VDD = V4P3 (stays alive when V33FF collapses), MR->VDD, CT open (assert immediate, deassert ~25 us), RESET open-drain -> PG_ALL. Pin map verified SBVS227 2026-10-12"),
    "ldo33d":  ("TPS7A2033", FP["SOT23_5"], "TPS7A2033PDBVR", "board digital 3.3 V rail V33D from V4P3 (~120 mA: 4x TMP117 + ISO1640 side 1 + 2x UCD90120A @ 50 mA + LEDs); EN->IN always-on"),
    "ucd":     ("UCD90120A", FP["TI_RGC64"], "UCD90120ARGCR", "13-input PMBus rail monitor, VQFN-64 RGC; TELEMETRY ONLY - not in the mute path (17(m2)/(m3)); AP pushes config over the sensor I2C bus at boot; 2 on the board (UCD_L / UCD_R). Pin map verified SLVSAN9C 2026-10-12 ** VERIFY: footprint EP, BPCAP value, V33FB/CNTRL/TRCK strapping **"),
    "pwrc":    ("PRE-REG", FP["PHDR2x4"], "TW-04-xxx-L-D", "power-tube board-to-board feed, one per board edge (option B 2026-10-12: shared pre-reg rails, per-channel POL LDOs - the tube Y-fans-out each rail so each channel's POL cluster draws from its own edge entry; 2026-10-13: ~30 mm stack -> 0.100-inch stacker header, Samtec TW/ESQT class, ~3 A/pin vs <= 0.5 A/rail): P16A / N16A / V8P3 / V4P3 each beside its own GND return  ** VERIFY stacker MPN + 30 mm pin length **"),
    "hdr4":    ("PMBUS", FP["HDR1x4"], "TSW-104-07-G-S", "UCD PMBus service header (USB-TO-GPIO2 4-wire subset: SDA/SCL/GND/3V3), on the SENS bus - DNP, bring-up/debug only"),
    "rcset":   ("4.7u", FP["C0805"], "GRM21BR71E475KA73L", "LT3045/LT3094 C_SET, X7R 25 V 0805"),
    "cldo10":  ("10u", FP["C1206"], "GRM31CR71E106KA12L", "LDO IN/OUT ceramic, X7R 25 V 1206"),
    "cpgfb":   ("1n", FP["C0603"], "GRM1885C1H102JA01D", "PGFB / MON node HF cap, C0G 50 V"),
    "c1u":     ("1u", FP["C0603"], "GRM188R61E105KA12D", "ADP7158 BYP/REF/VREG caps (min 1 uF), X5R 25 V 0603"),
    "cbpcap":  ("100n", FP["C0603"], "GRM188R71C104KA01D", "UCD BPCAP internal-1.8 V bypass + VDD/sense HF, X7R 25 V ** VERIFY BPCAP value **"),
    "rmon":    ("", FP["R0603"], "TNPW0603%sFEEA", "UCD MON divider, TNPW 1 % 25 ppm (Value = resistance, MPN = 4-char code)"),
    "raddr":   ("", FP["R0603"], "TNPW0603%sFEEA", "UCD PMBUS_ADDR0/1 analog strap resistor to GND - value per SLVSAN9C PMBus Address Detection table  ** VERIFY **"),
    "rrst":    ("10k", FP["R0603"], "CRCW060310K0FKEA", "UCD RESET pull-up (+ 1 nF to GND) / TRST / TDI / TMS / PMBALERT straps per SLVSAN9C"),
    "bat54":   ("BAT54", FP["SOT23_5"].replace("SOT-23-5", "SOT-23"), "BAT54,215", "MON negative-sense clamp: K to MON node, A to GND - protects the UCD MON pin if the negative rail is up while V33D is down  ** VERIFY needed vs ESD path **"),
    "tp1k":    ("1.00k", FP["R0603"], "TNPW06031K00FEEA", "1k probe-isolation stub: reduces loading, does not eliminate it; 10 pF gives an approximately 16 MHz pole. Use a low-capacitance active probe for settling tests; never terminate in 50 ohms"),
}

# Test-point strategy (progress.md TP mandate + user ruling): (a) analog/high-speed nodes = small SMD pad on the
# shortest stub, never a TH pin in the signal path; (b) clock / cell-drive nodes tapped through a 1k series R;
# (c) rails / references / control = THT hook pads freely; (d) a GND pad sits next to every TP bank.
TP_FPS = {"pad": "TestPoint:TestPoint_Pad_1.0x1.0mm",
          "tht": "TestPoint:TestPoint_THTPad_2.0x2.0mm_Drill1.0mm"}
TP_DESCR = {"pad": "test point, 1.0 mm SMD pad - short-stub probe point (TP rule a/b)",
            "tht": "test point, 2.0 mm THT hook pad - low-Z / DC / control / GND (TP rule c/d)"}

def tp(sh, ref, x, y, dest, kind="tht", value="TP"):
    """One Connector:TestPoint (single pin '1'); place() emits the stub + label / power flag."""
    sh.place("Connector:TestPoint", ref, value, x, y, {"1": dest},
             footprint=TP_FPS[kind], descr=TP_DESCR[kind])

def tp_stub(sh, ref, rref, x, y, dest, tpnet, ip_):
    """Rule (b) probe: signal net -> 1k series R -> 1.0 mm pad on a local TP_ net (pad is never on the signal path)."""
    k, v = ip_("tp1k")
    sh.place("Device:R", rref, v, x, y, {"1": dest, "2": ("L", tpnet)}, **k)
    tp(sh, ref, x + 22, y, ("L", tpnet), kind="pad")

def build_channel(ch, cell, core, iv, refs, d):
    """One analog channel (ch = "L" / "R"): CELL template, CORE, IV, REFS sheets.  Channel-local global nets get
    a _L/_R suffix (Sheet.chan); SHARED_NETS (rails, REF5/REF5F) do not.  The rails PWR_FLAG table and the REF7050
    chain are one-per-board and drawn on the L sheet only."""
    P = d["params"]
    ncell = d["n_cells"]
    G = lambda n: ("G", n.upper())
    GND = ("GND", "GND")
    H = lambda n: ("H", n)

    # ---------------- cell sheet (deck template, hardware only)
    def cref(prefix, k):
        return ["%s%d" % (prefix, 1000 + 10 * (n + 1) + k) for n in range(ncell)]
    cell.text("One of 64 identical current cells (bom 1.2 + 2). Analog values from bfdac_cosim112.cir; base-drive network re-sized 2026-09-26"
              " for the locked-deck levels 1.10/1.70 V (rs 1.35k, rp 301 to VCM 1.345 V). D arrives at 3.3 V from the XLAT sheet (SN74AXC8T245 octal, 8/channel; the per-cell AXC1T45 was removed 2026-10-10).", 20, 17)
    cell.text("DMMT5551 = one dual package per cell (units A/B); the tail NPN is 1/4 of a THAT300 (Q301..Q316, unit = cell mod 4, substrate pins on CORE)."
              " Footprints/MPNs: parts pass 2026-09-28 (MPN field).", 20, 21)
    def cp(key):
        v, fp, mpn, ds = CELL_PARTS[key]
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    # --- digital drive: 3.3 V D (XLAT sheet) -> LVC1G74 -> rs/rp network (not in the deck: B sources there)
    k, v = cp("ff")
    cell.place("74xGxx:74AUC1G74", cref("U", 1), v, 90, 150,
               {"D": H("D"), "C": H("CLK"), "Q": ("L", "Q"), "~{Q}": ("L", "QB"), "~{PRE}": ("L", "VCC_FF"),
                "~{CLR}": ("L", "VCC_FF"), "VCC": ("L", "VCC_FF"), "GND": GND}, **k)
    k, v = cp("fb")
    cell.place("Device:FerriteBead", cref("FB", 1), v, 130, 140, {"1": G("v33ff"), "2": ("L", "VCC_FF")}, **k)
    k, v = cp("cff")
    cell.place("Device:C", cref("C", 1), v, 145, 150, {"1": ("L", "VCC_FF"), "2": GND}, **k)
    fx, fy = snap(160), snap(140)
    cell.power("power:PWR_FLAG", "PWR_FLAG", fx, fy, "#FLG")
    cell.wire(fx, fy, fx, fy + 2.54)
    cell.label("VCC_FF", fx, fy + 2.54, 0, "L")
    k, v = cp("rs")
    cell.place("Device:R", cref("R", 6), v, 25, 35, {"1": ("L", "Q"), "2": ("L", "BS1D")}, **k)
    cell.place("Device:R", cref("R", 7), v, 105, 35, {"1": ("L", "QB"), "2": ("L", "BS2D")}, **k)
    k, v = cp("rp")
    cell.place("Device:R", cref("R", 8), v, 10, 55, {"1": ("L", "BS1D"), "2": G("vcm")}, **k)
    cell.place("Device:R", cref("R", 9), v, 120, 55, {"1": ("L", "BS2D"), "2": G("vcm")}, **k)
    # tail: Q4 = one unit of a THAT300 quad (package per 4 cells) + Rt 750 to GND, base on q4_base
    k, v = cp("tail")
    tail_refs = ["Q3%02d" % (n // 4 + 1) for n in range(ncell)]
    tail_units = [n % 4 + 1 for n in range(ncell)]
    cell.place("%s:THAT300" % LOCALLIB, tail_refs, v, 60, 80,
               {"C1": ("L", "CS"), "B1": G("q4_base"), "E1": ("L", "CE")}, unit=tail_units, deckname="Q4N",
               pinmap=[dict(zip("CBE", THAT300_PINS[u])) for u in tail_units], **k)
    k, v = cp("rt")
    cell.place("Device:R", cref("R", 3), v, 60, 100, {"1": ("L", "CE"), "2": GND}, deckname="RtN", **k)
    # steering pair: one DMMT5551 (SOT-363), units A/B of the same package
    k, v = cp("pair")
    cell.place("Transistor_BJT:MMDT5551", cref("Q", 2), v, 40, 55,
               {"C1": G("bus_plus"), "B1": ("L", "BS1"), "E1": ("L", "CS")}, unit=1, deckname="QSNa",
               pinmap={"C": "6", "B": "2", "E": "1"}, **k)
    cell.place("Transistor_BJT:MMDT5551", cref("Q", 2), v, 85, 55,
               {"C2": G("bus_minus"), "B2": ("L", "BS2"), "E2": ("L", "CS")}, unit=2, deckname="QSNb",
               pinmap={"C": "3", "B": "5", "E": "4"}, **k)
    k, v = cp("rstop")
    cell.place("Device:R", cref("R", 1), v, 25, 55, {"1": ("L", "BS1D"), "2": ("L", "BS1")}, deckname="RNa", **k)
    cell.place("Device:R", cref("R", 2), v, 105, 55, {"1": ("L", "BS2D"), "2": ("L", "BS2")}, deckname="RNb", **k)
    # replica-ff sum resistors
    k, v = cp("rsum")
    assert val(P["rsum"], P) == v, P["rsum"]
    cell.place("Device:R", cref("R", 4), v, 140, 55, {"1": ("L", "QB"), "2": G("ns1p")}, deckname="Rr1pN", **k)
    cell.place("Device:R", cref("R", 5), v, 160, 55, {"1": ("L", "Q"), "2": G("ns1m")}, deckname="Rr1mN", **k)

    # ---------------- core sheet
    B = d["blocks"]
    core.text("Si1555DL is a COMPLEMENTARY N+P pair (Vishay 71079): only the N half (unit A, pins S1/G1/D1 = 1/2/6) is used;"
              " the P half (unit B, pins 3/4/5) is tied to GND in the strip at right - one package per MOSFET, 8 per channel.", 20, 17)
    core.text("Values = bfdac_cosim112.cir (bom 3). Re 35.3 -> 35.7 E96 (TNPW0603 0.1 %, Susumu 0.05 % starts at 47 R), Rsh 156.25 -> 156 E96 (RG1608N 0.05 %); Rpad = 2 x 574 in parallel (287)."
              " Footprints/MPNs: parts pass 2026-09-28 (MPN field).", 20, 21)
    def kp(key):
        v, fp, mpn, ds = CORE_PARTS[key]
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    NPM = dict(pinmap=SI1555_N)
    PPM = dict(pinmap={"C": SA1036_PINS["C"], "B": SA1036_PINS["B"], "E": SA1036_PINS["E"]})
    SI = "%s:Si1555DL" % LOCALLIB
    k, v = kp("nmos")
    core.place(SI, "Q1", v, 60, 60, {"D": G("col_p"), "G": ("L", "M6G_P"), "S": G("mid_p")}, deckname="M6p", **NPM, **k)
    core.place(SI, "Q2", v, 60, 90, {"D": G("mid_p"), "G": ("L", "M5G_P"), "S": G("bus_plus")}, deckname="M5p", **NPM, **k)
    core.place(SI, "Q3", v, 140, 60, {"D": G("col_m"), "G": ("L", "M6G_M"), "S": ("L", "MID_M")}, deckname="M6m", **NPM, **k)
    core.place(SI, "Q4", v, 140, 90, {"D": ("L", "MID_M"), "G": ("L", "M5G_M"), "S": G("bus_minus")}, deckname="M5m", **NPM, **k)
    k, v = kp("rg")
    core.place("Device:R", "R1", v, 40, 60, {"1": G("casb2_p"), "2": ("L", "M6G_P")}, deckname="Rg6_p", **k)
    core.place("Device:R", "R2", v, 40, 90, {"1": G("casb_p"), "2": ("L", "M5G_P")}, deckname="Rg5_p", **k)
    core.place("Device:R", "R3", v, 120, 60, {"1": G("casb2_m"), "2": ("L", "M6G_M")}, deckname="Rg6_m", **k)
    core.place("Device:R", "R4", v, 120, 90, {"1": G("casb_m"), "2": ("L", "M5G_M")}, deckname="Rg5_m", **k)
    # replica-ff / cascode-bias generator
    k, v = kp("nmos")
    core.place(SI, "Q5", v, 60, 130, {"D": G("casb_p"), "G": G("casb_p"), "S": G("vfr")}, deckname="MR_p", **NPM, **k)
    core.place(SI, "Q6", v, 140, 130, {"D": G("casb_m"), "G": G("casb_m"), "S": G("vfr")}, deckname="MR_m", **NPM, **k)
    k, v = kp("qr")
    core.place("%s:2SA1036K" % LOCALLIB, "Q7", v, 90, 130, {"C": G("casb_p"), "B": G("ns1p"), "E": ("L", "E1P")}, deckname="QR1p", **PPM, **k)
    core.place("%s:2SA1036K" % LOCALLIB, "Q8", v, 170, 130, {"C": G("casb_m"), "B": G("ns1m"), "E": ("L", "E1M")}, deckname="QR1m", **PPM, **k)
    k, v = kp("re")
    core.place("Device:R", "R5", v, 90, 150, {"1": ("L", "E1P"), "2": G("ve1")}, deckname="Re1p", **k)
    core.place("Device:R", "R6", v, 170, 150, {"1": ("L", "E1M"), "2": G("ve1")}, deckname="Re1m", **k)
    k, v = kp("rsh")
    core.place("Device:R", "R7", v, 210, 60, {"1": G("ns1p"), "2": G("vb1")}, deckname="Rsh1p", **k)
    core.place("Device:R", "R8", v, 210, 90, {"1": G("ns1m"), "2": G("vb1")}, deckname="Rsh1m", **k)
    k, v = kp("csh")
    assert val(P["csum"], P) == v, P["csum"]
    core.place("Device:C", "C1", v, 225, 60, {"1": G("ns1p"), "2": GND}, deckname="Csh1p", **k)
    core.place("Device:C", "C2", v, 225, 90, {"1": G("ns1m"), "2": GND}, deckname="Csh1m", **k)
    # padding mirrors
    k, v = kp("nmos")
    core.place(SI, "Q9", v, 60, 190, {"D": G("bus_plus"), "G": G("padb_base"), "S": G("padb_ep")}, deckname="Mpad_p", **NPM, **k)
    core.place(SI, "Q10", v, 140, 190, {"D": G("bus_minus"), "G": G("padb_base"), "S": ("L", "PADB_EM")}, deckname="Mpad_m", **NPM, **k)
    k, v = kp("rpad")
    core.place("Device:R", "R9", v, 45, 210, {"1": G("padb_ep"), "2": G("vee15")}, deckname="Rpad_p", **k)
    core.place("Device:R", "R14", v, 55, 210, {"1": G("padb_ep"), "2": G("vee15")}, **k)
    core.place("Device:R", "R16", v, 65, 210, {"1": G("padb_ep"), "2": G("vee15")}, **k)
    core.place("Device:R", "R17", v, 75, 210, {"1": G("padb_ep"), "2": G("vee15")}, **k)
    core.place("Device:R", "R10", v, 125, 210, {"1": ("L", "PADB_EM"), "2": G("vee15")}, deckname="Rpad_m", **k)
    core.place("Device:R", "R15", v, 135, 210, {"1": ("L", "PADB_EM"), "2": G("vee15")}, **k)
    core.place("Device:R", "R18", v, 145, 210, {"1": ("L", "PADB_EM"), "2": G("vee15")}, **k)
    core.place("Device:R", "R19", v, 155, 210, {"1": ("L", "PADB_EM"), "2": G("vee15")}, **k)
    k, v = kp("cpadb")
    core.place("Device:C_Polarized", "C3", v, 100, 200, {"1": G("padb_base"), "2": GND}, deckname="Cpadb", **k)
    # unused P halves of the eight Si1555DL packages
    k, v = kp("nmos")
    core.text("Si1555DL P halves (unit B), not used: D2/G2/S2 (pins 3/4/5) tied to GND (separate die from the N half).", 300, 50)
    PGND = {"D": GND, "G": GND, "S": GND}
    for i, r in enumerate(("Q1", "Q2", "Q3", "Q4", "Q5", "Q6", "Q9", "Q10")):
        core.place(SI, r, v, 310 + 25 * (i % 4), 70 + 30 * (i // 4), PGND, unit=2, **k)
    # bus
    k, v = kp("cbus")
    assert val(P["cbus"], P) == v, P["cbus"]
    core.place("Device:C", "C4", v, 265, 130, {"1": G("bus_plus"), "2": GND}, deckname="C_bus_p", **k)
    core.place("Device:C", "C5", v, 265, 160, {"1": G("bus_minus"), "2": GND}, deckname="C_bus_m", **k)
    k, v = kp("rbleed")
    core.place("Device:R", "R11", v, 250, 130, {"1": G("bus_plus"), "2": GND}, deckname="R_bleed_plus", **k)
    core.place("Device:R", "R12", v, 250, 160, {"1": G("bus_minus"), "2": GND}, deckname="R_bleed_minus", **k)
    # tail reference
    k, v = kp("rbias")
    core.place("Device:R", "R13", v, 250, 200, {"1": G("vref"), "2": G("q4_base")}, deckname="R_bias", **k)
    k, v = kp("cq4")
    core.place("Device:C_Polarized", "C6", v, 265, 200, {"1": G("q4_base"), "2": GND}, deckname="C_q4", **k)
    # THAT300 substrate pins (unit 5 of the 16 tail-quad packages drawn on CELL) -> analog ground
    core.text("THAT300 tail quads Q301..Q316 (units 1-4 on the CELL sheets): substrate pins 4/11 ac-grounded here.", 20, 240)
    k, v = cp("tail")
    for i in range(ncell // 4):
        core.place("%s:THAT300" % LOCALLIB, "Q3%02d" % (i + 1), v, 30 + 20 * (i % 8), 255 + 20 * (i // 8),
                   {"SUB": GND}, unit=5, **k)

    # ---------------- I/V sheet
    iv.text("P5 TIA (bom 4): OPA1612 front amp, BUF634A in the loop, C_f on the buffer output. R_off 133/116 (MIDCODE 32.5) realised as"
            " 4 x 536 / 4 x 464 in parallel (TE RA73 0603 AlN 0.5 W, 0.1 % 25 ppm thin film, enlarged copper): ~11 V x 83/95 mA = 0.9/1.0 W per rail, 46/52 % per leg - bom items 13/14 ruled (heat managed by placement).", 20, 17)
    iv.text("R_f RG3216N 0.05 %; C_f/C_col C0G. 100n decoupling per supply pin is kicad-only (not in the deck). Footprints/MPNs: parts pass 2026-09-28.", 20, 21)
    def ip(key, value=None, code=None):
        v, fp, mpn, ds = IV_PARTS[key]
        if "%s" in mpn and (code or value):
            mpn = mpn % (code or value)
        if value is not None:
            v = value
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    for side, y, n in (("p", 60, 1), ("m", 130, 2)):
        S = side.upper()
        k, v = ip("ccol")
        iv.place("Device:C", "C%d" % (n + 20), v, 40, y, {"1": G("col_" + side), "2": GND}, deckname="C_col_" + side, **k)
        k, v = ip("roff_" + side)
        iv.place("Device:R", "R%d" % (n + 20), v, 55, y, {"1": G("v_roff"), "2": G("col_" + side)}, deckname="R_off_" + side, **k)
        iv.place("Device:R", "R%d" % (n + 24), v, 65, y, {"1": G("v_roff"), "2": G("col_" + side)}, **k)
        iv.place("Device:R", "R%d" % (n + 26), v, 75, y, {"1": G("v_roff"), "2": G("col_" + side)}, **k)
        iv.place("Device:R", "R%d" % (n + 28), v, 85, y, {"1": G("v_roff"), "2": G("col_" + side)}, **k)
        k, v = ip("rf")
        iv.place("Device:R", "R%d" % (n + 22), v, 120, y - 10, {"1": G("out_" + side), "2": G("col_" + side)}, deckname="R_f_" + side, **k)
        k, v = ip("cf")
        iv.place("Device:C", "C%d" % (n + 22), v, 140, y - 10, {"1": G("out_" + side), "2": G("col_" + side)}, deckname="C_f_" + side, **k)
        k, v = ip("opamp")
        iv.place("Amplifier_Operational:OPA1612AxD", "U%d" % n, v, 100, y + 10,
                 {"-": G("col_" + side), "+": G("v_vg"), "1": ("L", "OA_" + S)}, unit=1, **k)
        iv.place("Amplifier_Operational:OPA1612AxD", "U%d" % n, v, 100, y + 35,
                 {"V+": G("p15a"), "V-": G("n15a")}, unit=3, **k)
        iv.place("Amplifier_Operational:OPA1612AxD", "U%d" % n, v, 60, y + 35,
                 {"-": ("L", "SPARE_" + S), "+": GND, "7": ("L", "SPARE_" + S)}, unit=2, **k)
        k, v = ip("buf")
        iv.place("Amplifier_Buffer:BUF634AxD", "U%d" % (n + 2), v, 160, y + 10,
                 {"V_{IN}": ("L", "OA_" + S), "6": G("out_" + side), "V+": G("p15a"), "V-": G("n15a"), "BW": G("n15a"),
                  "NC": ("NC", "")}, **k)
        k, v = ip("cdec")
        for j, (rail, x) in enumerate((("p15a", 190), ("n15a", 205), ("p15a", 220), ("n15a", 235))):
            iv.place("Device:C", "C%d" % (n * 10 + 30 + j), v, x, y + 30, {"1": G(rail), "2": GND}, **k)
        iv.text("U%d / U%d decoupling" % (n, n + 2), 190, y + 20)

    # --- V_ROFF POL LDO (dual-mono 2026-10-12, bom 17(l)/(m3)): lives next to its R_off load.  LT3045,
    # SET = 100 uA x 150k = +15.0 V; PGFB 442k/10k + 1 nF (mandatory - below 0.30 V PGFB the SET current
    # jumps 100 uA -> 2 mA and the output pegs); PG open-collector -> PG_ALL.  Output = V_ROFF_RAW through
    # FB1 600R + bulk = the filtered +15F node the four R_off strings draw ~180 mA from.
    iv.text("V_ROFF LDO (U685): LT3045 from P16A, +15.0 V / 180 mA into the R_off strings; BLM18PG601 + bulk"
            " = R9a/FB9/C9 filter (17(l)). PG -> PG_ALL (wired-AND); PGFB 442k/10k trips at -10 %.", 20, 225)
    k, v = ip("ldo")
    iv.place("Regulator_Linear:LT3045xMSE", "U685", v, 90, 245,
             {"IN": G("p16a"), "EN/UV": G("p16a"), "PG": G("pg_all"), "PGFB": ("L", "PGF_U685"),
              "SET": ("L", "SET_U685"), "ILIM": GND, "GND": GND, "OUTS": ("L", "VROFF_RAW"), "OUT": ("L", "VROFF_RAW")}, **k)
    k, v = ip("cldo")
    iv.place("Device:C", "C685", v, 60, 235, {"1": G("p16a"), "2": GND}, **k)
    iv.place("Device:C", "C686", v, 118, 233, {"1": ("L", "VROFF_RAW"), "2": GND}, **k)
    k, v = ip("rp01", "150k", "1503"); iv.place("Device:R", "R685", v, 60, 254, {"1": ("L", "SET_U685"), "2": GND}, **k)
    k, v = ip("c4u7");               iv.place("Device:C", "C687", v, 60, 272, {"1": ("L", "SET_U685"), "2": GND}, **k)
    k, v = ip("rp01", "442k", "4423"); iv.place("Device:R", "R686", v, 118, 250, {"1": ("L", "VROFF_RAW"), "2": ("L", "PGF_U685")}, **k)
    k, v = ip("rp01", "10k", "1002");  iv.place("Device:R", "R687", v, 118, 260, {"1": ("L", "PGF_U685"), "2": GND}, **k)
    k, v = ip("c1n");                iv.place("Device:C", "C688", v, 130, 255, {"1": ("L", "PGF_U685"), "2": GND}, **k)
    k, v = ip("fbv");                iv.place("Device:FerriteBead", "FB685", v, 145, 240, {"1": ("L", "VROFF_RAW"), "2": G("v_roff")}, **k)
    k, v = ip("cldo");               iv.place("Device:C", "C689", v, 160, 235, {"1": G("v_roff"), "2": GND}, **k)
    k, v = ip("c100u");              iv.place("Device:C_Polarized", "C690", v, 170, 235, {"1": G("v_roff"), "2": GND}, **k)

    # --- I/V test points (progress.md TP mandate): rails/references on THT hook pads, OUT_P/M on 1.0 mm SMD pads,
    # summing nodes COL_P/COL_M through 1k isolation stubs (rule b).  GND pads beside the bank.
    iv.text("PER-CELL TEST: COL_P/COL_M taps on EACH channel are through 1k (reduced, not zero loading). Use low-C active probes;"
            " no 50-ohm termination. Measure cell weight from baseline/test delta at OUT_P/M pre-relay; summing taps check compliance/settling."
            " Place each tap's GND pad beside its probe pad on PCB; keep node-side stubs short.", 250, 24)
    for i, (net, kind) in enumerate((("v_roff", "tht"), ("p16a", "tht"), ("n15a", "tht"), ("p15a", "tht"),
                                    ("v_vg", "tht"), ("out_p", "pad"), ("out_m", "pad"))):
        tp(iv, "TP98%d" % i, 300, 40 + 26 * i, G(net), kind=kind)
    tp_stub(iv, "TP987", "R688", 270, 40 + 26 * 7, G("col_p"), "TP_COLP", ip)
    tp_stub(iv, "TP988", "R689", 270, 40 + 26 * 8, G("col_m"), "TP_COLM", ip)
    tp(iv, "TP992", 335, 40 + 26 * 7, GND, kind="pad", value="COLP_GND")
    tp(iv, "TP993", 335, 40 + 26 * 8, GND, kind="pad", value="COLM_GND")
    tp(iv, "TP990", 300, 40 + 26 * 9, GND)
    tp(iv, "TP991", 340, 40 + 26 * 9, GND)

    # ---------------- refs sheet: rail inputs (PWR_FLAG table) + realised references / biases (bom 9, 2026-10-06)
    refs.text("RAILS: DUAL-MONO POL (user rulings 2026-10-12, bom 17(m3)) - every POL LDO sits on the sheet it powers; only the pre-reg entry is on"
              " the POWER sheet. This sheet carries the %s-channel analog housekeeping LDOs: P15A_%s (U909), N15A_%s (U910), VEE15_%s (U911), VE1_%s (U906),"
              " P5A_%s (U908) - all PG -> PG_ALL. V_ROFF_%s LDO is on IV; V33CLK on CLKR; V33FF on XLAT; V33D on CTRL; V33RLY on OUT."
              % (ch, ch, ch, ch, ch, ch, ch), 20, 17)
    refs.text("REFERENCE CHAIN (derived req. 6: one filtered node per channel): U901 REF7050 (ONE PER BOARD) -> R902/C904 4.99k + 10u film (3.2 Hz) -> U902A OPA1656 FET buffer = REF5F"
              " -> dividers (Susumu RG1608N 0.05 % 10 ppm discretes for V_VG/CASB2/PADB, best-tolerance ruling 2026-10-08; ACAS 0612 matched arrays for VFR/VCM/VREF/VE1) -> OPA1612 unity buffers (10 R + 47u UKL + 1u C0G at the node).", 20, 21)
    refs.text("SINKS/SOURCES: VFR = U904A + Q901 servoed NPN sink (150 mA); VCM = U904B + Q903/Q904 class-A pair on +3V3A/GND (I_q ~40 mA > 24 mA peak, Q905 V_be multiplier); VE1 = U906 LT3045 (bottom strip)"
              " (SET driven by U905A x1.44 via VE1_SET_%s, from V8P3); VB1 = VE1 - [Q902 2SA1036K diode + 59.0 R] at 10 mA via R929 590 -> U905B buffer (V_eb compensator, 17(k)(d)). CASB2 = U902B servo on mean(mid_p) vs 3.0 V tap (2 x 499k + 1n, C_i 1u, 100 R / 100u, 6.2 V clamp)." % ch, 20, 25)
    refs.text("PADB = U907 current servo: A = diff-amp 0.25 x (padb_ep - VEE15) [40.2k/10.0k], B = integrator vs 3.568 V tap -> 1k -> PADB_BASE (Cpadb 100u on CORE), 2.7 V clamp -> I_pad 50 mA independent of VEE15 and Si1555 V_th."
              " Divider set-point errors (E96) are static and inside the 17(i) accuracy columns: V_VG +0.08 %, VREF -0.15 %, VFR -0.14 %, VCM -0.10 %, VE1 +0.14 %, CASB2 tap +0.07 %, PADB -0.2 %. Loops simulated 2026-10-06 (utils/refs_loop.py): VFR f_c 530 Hz / PM 96; VCM f_c 374 kHz / PM 159, -0.33 mV on 23 mA RTZ pulses; PADB f_c 0.38 Hz / PM 103, 55.6 mA start-up peak; VB1 compensator 11x.", 20, 29)
    # PWR_FLAG table (L sheet only, shared nets): flags for rails driven by connectors/LDOs elsewhere so
    # ERC sees an intentional source.  Per-channel POL nets (P15A_L etc.) are LDO-driven -> no flag needed.
    rails = [] if ch != "L" else [("P16A", "+16.2 V pre-reg from the power tube -> +15 V-class LT3045/LT3094 POLs; in at J603/J604 stackers"),
             ("N16A", "-16.2 V pre-reg -> -15 V-class LT3094 POLs (N15A, VEE15); in at J603/J604 stackers"),
             ("V8P3", "+8.3 V pre-reg -> VE1 LT3045s (per channel); in at J603/J604 stackers"),
             ("V4P3", "+4.3 V pre-reg -> 3.3 V-class POLs (V33CLK/V33FF/P5A per channel), V33D (U512), V33RLY (U603, OUT); in at J603/J604 stackers"),
             ("GND", "analog ground reference"),
             ("V18", "1.8 V translator A-side + PG_ALL pull-up, supplied by the SoM (VCCIO_65_EX) - not generated on this board"),
             # V33D/V33CLK/V33FF/V33RLY have on-board LDO drivers now (U512/U340/U460/U603): a PWR_FLAG on
             # those nets is an ERC pin_to_pin error (power_out vs power_out) - they must NOT be flagged.
             ("V12SOM", "+12 V SoM feed, SoM-only (switcher, 15 A planning figure) - enters at J507 REDCUBE terminal (CTRL sheet, left edge)"),
             ("VAP_IO", "AP-side isolator supply, in at J506 FX18-40 pin 25 (AP domain)"),
             ("GND_AP", "AP-side ground (isolated domain)")]
    for i, (nm_, desc) in enumerate(rails):
        x, y = (snap(30), snap(45 + 10 * i)) if i < 7 else (snap(330), snap(45 + 10 * (i - 7)))
        refs.power("power:PWR_FLAG", "PWR_FLAG", x, y, "#FLG")
        refs.wire(x, y, x, y + 2.54)
        refs.label(nm_, x, y + 2.54, 0, "G")
        refs.text(desc, x + 15, y + 3)

    def rp(key, value=None, code=None):
        v, fp, mpn, ds = REFS_PARTS[key]
        if key == "rp01":
            mpn, grade = precision_r(value, code)
            ds = "%s - %s" % (ds, grade)
        elif code is not None:
            mpn = mpn % code if isinstance(code, str) else mpn % tuple(code)
        return dict(footprint=fp, mpn=mpn, descr=ds), (value if value is not None else v)
    def dual(ref, x, y, key, a, b, rails=("p15a", "n15a")):
        """Place a dual op-amp: a/b = (-, +, out) nets for units 1/2, unit 3 = supplies + 100n each."""
        k, v = rp(key)
        refs.place("Amplifier_Operational:%s" % ("OPA1656ID" if key.startswith("fet") else "OPA1612AxD"), ref, v, x, y,
                   {"-": a[0], "+": a[1], "1": a[2]}, unit=1, **k)
        refs.place("Amplifier_Operational:%s" % ("OPA1656ID" if key.startswith("fet") else "OPA1612AxD"), ref, v, x, y + 25,
                   {"-": b[0], "+": b[1], "7": b[2]}, unit=2, **k)
        refs.place("Amplifier_Operational:%s" % ("OPA1656ID" if key.startswith("fet") else "OPA1612AxD"), ref, v, x + 25, y + 12,
                   {"V+": G(rails[0]), "V-": G(rails[1])}, unit=3, **k)
        k, v = rp("c100n")
        n = int(ref[1:])
        refs.place("Device:C", "C%d" % (n * 10 + 1), v, x + 40, y + 5, {"1": G(rails[0]), "2": GND}, **k)
        refs.place("Device:C", "C%d" % (n * 10 + 2), v, x + 40, y + 20, {"1": G(rails[1]), "2": GND}, **k)
    def divider(refno, x, y, top, bot, node, arr=None):
        """REF5F -> top -> node -> bot -> GND.  arr = (R1code, R2code) -> one ACAS array (R1/R2 used, R3/R4 NC)."""
        if arr:
            k, v = rp("acas", "%s/%s" % (top, bot), arr)
            refs.place("Device:R_Pack04", "RN%d" % refno, v, x, y,
                       {"R1.1": G("ref5f"), "R1.2": ("L", node), "R2.1": ("L", node), "R2.2": GND,
                        "R3.1": ("NC", ""), "R3.2": ("NC", ""), "R4.1": ("NC", ""), "R4.2": ("NC", "")}, **k)
        else:
            k, v = rp("rp01", top, RG(top))
            refs.place("Device:R", "R%d" % refno, v, x, y, {"1": G("ref5f"), "2": ("L", node)}, **k)
            k, v = rp("rp01", bot, RG(bot))
            refs.place("Device:R", "R%d" % (refno + 1), v, x, y + 12, {"1": ("L", node), "2": GND}, **k)
    def outnet(refno, x, y, src, dest):
        """buffer output -> 10 R -> dest (global) with 47u UKL + 1u C0G."""
        k, v = rp("rser")
        refs.place("Device:R", "R%d" % refno, v, x, y, {"1": ("L", src), "2": G(dest)}, **k)
        k, v = rp("cout")
        refs.place("Device:C_Polarized", "C%d" % refno, v, x + 12, y + 8, {"1": G(dest), "2": GND}, **k)
        k, v = rp("c1u")
        refs.place("Device:C", "C%d" % (refno + 1), v, x + 22, y + 8, {"1": G(dest), "2": GND}, **k)

    # --- U901 REF7050 + filter + FET buffer (REF5 -> REF5RC -> REF5F): ONE PER BOARD, drawn on the L sheet (derived req. 6)
    if ch == "L":
        k, v = rp("ref")
        refs.place("%s:REF7050" % LOCALLIB, "U901", v, 60, 150,
                   {"VIN": ("L", "REF_VIN"), "EN": ("L", "REF_VIN"), "GND": GND, "OUTF": G("ref5"), "OUTS": G("ref5")}, **k)
        k, v = rp("rin");    refs.place("Device:R", "R901", v, 30, 140, {"1": G("p15a"), "2": ("L", "REF_VIN")}, **k)
        fx, fy = snap(80), snap(130)
        refs.power("power:PWR_FLAG", "PWR_FLAG", fx, fy, "#FLG"); refs.wire(fx, fy, fx, fy + 2.54); refs.label("REF_VIN", fx, fy + 2.54, 0, "L")
        k, v = rp("crefin"); refs.place("Device:C", "C901", v, 40, 165, {"1": ("L", "REF_VIN"), "2": GND}, **k)
        k, v = rp("c100n");  refs.place("Device:C", "C902", v, 50, 165, {"1": ("L", "REF_VIN"), "2": GND}, **k)
        k, v = rp("crefo");  refs.place("Device:C", "C903", v, 90, 165, {"1": G("ref5"), "2": GND}, **k)
        k, v = rp("rrc");    refs.place("Device:R", "R902", v, 105, 150, {"1": G("ref5"), "2": ("L", "REF5RC")}, **k)
        k, v = rp("crc");    refs.place("Device:C", "C904", v, 115, 165, {"1": ("L", "REF5RC"), "2": GND}, **k)
        # U902: A = REF5F buffer, B = CASB2 servo (inverting integrator on mean(mid_p) vs the 3.0 V tap)
        dual("U902", 140, 150, "fetamp", (G("ref5f"), ("L", "REF5RC"), G("ref5f")),
             (("L", "CB2_SENSE"), ("L", "REF3V0"), ("L", "CB2_OUT")))
    else:
        refs.text("R channel: REF5F comes from the L REFS sheet (U901 REF7050 + U902A buffer, one per board - derived req. 6); rails PWR_FLAG table is there too."
                  " U702A is the unused half of the CASB2 servo package, wired as a follower to GND.", 20, 140)
        dual("U902", 140, 150, "fetamp", (("L", "SPARE_A"), GND, ("L", "SPARE_A")),
             (("L", "CB2_SENSE"), ("L", "REF3V0"), ("L", "CB2_OUT")))
    RG = lambda s: {"10": "10R0", "57.6": "57R6", "590": "5900", "1k": "1001", "2.49k": "2491", "2.87k": "2871", "4.02k": "4021",
                    "6.04k": "6041", "7.15k": "7151", "10.0k": "1002", "33.2k": "3322", "40.2k": "4022", "100k": "1003", "499k": "4993"}[s]
    divider(903, 190, 150, "4.02k", "6.04k", "REF3V0")                  # 3.002 V casb2 set point
    k, v = rp("rp01", "499k", RG("499k"))
    refs.place("Device:R", "R905", v, 190, 185, {"1": G("mid_p"), "2": ("L", "CB2_MID")}, **k)
    refs.place("Device:R", "R906", v, 205, 185, {"1": ("L", "CB2_MID"), "2": ("L", "CB2_SENSE")}, **k)
    k, v = rp("c1n");     refs.place("Device:C", "C905", v, 198, 197, {"1": ("L", "CB2_MID"), "2": GND}, **k)
    k, v = rp("cfilm1u"); refs.place("Device:C", "C906", v, 215, 170, {"1": ("L", "CB2_SENSE"), "2": ("L", "CB2_OUT")}, **k)
    k, v = rp("z6v2");    refs.place("Device:D_Zener", "D901", v, 225, 185, {"K": ("L", "CB2_OUT"), "A": GND}, **k)
    k, v = rp("rp01", "100", "1000")
    refs.place("Device:R", "R907", v, 235, 175, {"1": ("L", "CB2_OUT"), "2": G("casb2_p")}, **k)
    k, v = rp("c100u");   refs.place("Device:C_Polarized", "C907", v, 250, 185, {"1": G("casb2_p"), "2": GND}, **k)
    refs.text("CASB2_P and CASB2_M are ONE node here (servo output after R907); the 100 R gate stoppers Rg6_p/m on CORE separate the two gates (ruling 2026-10-01).", 190, 205)
    xx, yy = snap(262), snap(175)
    refs.wire(xx, yy, xx + 5.08, yy); refs.label("CASB2_P", xx, yy, 180, "G"); refs.label("CASB2_M", xx + 5.08, yy, 0, "G")

    # --- U903: A = V_VG 4.000 V buffer, B = VREF 1.250 V buffer
    divider(908, 60, 230, "2.49k", "10.0k", "VVG_SET")                  # 4.003 V, RG1608P discretes (<= 10 nV node)
    divider(910, 60, 265, "15.0k", "4.99k", "VREF_SET", arr=("1502", "4991"))   # 1.248 V, ACAS array
    dual("U903", 90, 230, "opamp", (("L", "VVG_BUF"), ("L", "VVG_SET"), ("L", "VVG_BUF")),
         (("L", "VREF_BUF"), ("L", "VREF_SET"), ("L", "VREF_BUF")))
    outnet(912, 140, 230, "VVG_BUF", "v_vg")
    outnet(914, 140, 255, "VREF_BUF", "vref")

    # --- U904: A = VFR 1.75 V servoed NPN sink (150 mA inbound), B = VCM 1.345 V class-A bidirectional buffer
    divider(916, 60, 300, "1.18k", "634", "VFR_SET", arr=("1181", "6340"))     # 1.7475 V, low-Z (412 R) for the <= 20 nV sink node
    divider(917, 60, 335, "7.32k", "2.69k", "VCM_SET", arr=("7321", "2691"))    # 1.3437 V
    # VFR sink is an NPN pulling the node DOWN: vfr on the + input, reference on the - input through R_ref with a PI
    # network (R_pi + C_pi) from the output - refs_loop.py 2026-10-06: f_c 530 Hz, PM 96 deg, 5.5 nV @ 10 Hz
    dual("U904", 90, 300, "opamp", (("L", "VFR_N"), G("vfr"), ("L", "VFR_DRV")),
         (G("vcm"), ("L", "VCM_SET"), ("L", "VCM_DRV")))
    k, v = rp("rp01", "1k", RG("1k"));  refs.place("Device:R", "R942", v, 75, 318, {"1": ("L", "VFR_SET"), "2": ("L", "VFR_N")}, **k)
    k, v = rp("r1pct", "100", "100R"); refs.place("Device:R", "R943", v, 125, 290, {"1": ("L", "VFR_DRV"), "2": ("L", "VFR_PI")}, **k)
    k, v = rp("cfilm1u"); refs.place("Device:C", "C916", v, 112, 290, {"1": ("L", "VFR_PI"), "2": ("L", "VFR_N")}, **k)   # PI integrator
    k, v = rp("rp01", "100", "1000"); refs.place("Device:R", "R918", v, 140, 300, {"1": ("L", "VFR_DRV"), "2": ("L", "VFR_B")}, **k)
    k, v = rp("npn223"); refs.place("Transistor_BJT:BCP56", "Q901", v, 155, 300, {"B": ("L", "VFR_B"), "C": G("vfr"), "E": ("L", "VFR_E")}, **k)
    k, v = rp("r1pct", "2.2", "2R20"); refs.place("Device:R", "R919", v, 155, 315, {"1": ("L", "VFR_E"), "2": GND}, **k)
    k, v = rp("bat54"); refs.place("Device:D_Schottky", "D903", v, 125, 312, {"K": ("L", "VFR_DRV"), "A": GND}, **k)   # output clamp / anti-windup
    k, v = rp("c100u");  refs.place("Device:C_Polarized", "C917", v, 170, 310, {"1": G("vfr"), "2": GND}, **k)
    k, v = rp("c1u");    refs.place("Device:C", "C918", v, 180, 310, {"1": G("vfr"), "2": GND}, **k)
    # VCM output stage on +3V3A / GND: R920 pull-up, Q905 V_be multiplier (R921/R922), Q903 NPN up / Q904 PNP down, 2.2 R emitters, 2.2 R / 10u + 100u bank
    k, v = rp("r1pct", "47", "47R0"); refs.place("Device:R", "R923", v, 140, 335, {"1": ("L", "VCM_DRV"), "2": ("L", "VCM_BP")}, **k)
    k, v = rp("r1pct", "470", "470R"); refs.place("Device:R", "R920", v, 145, 322, {"1": G("p5a"), "2": ("L", "VCM_BN")}, **k)
    k, v = rp("bc847"); refs.place("Transistor_BJT:BC847", "Q905", v, 170, 335, {"B": ("L", "VCM_MB"), "C": ("L", "VCM_BN"), "E": ("L", "VCM_BP")}, **k)
    k, v = rp("r1pct", "1.43k", "1K43"); refs.place("Device:R", "R921", v, 185, 330, {"1": ("L", "VCM_BN"), "2": ("L", "VCM_MB")}, **k)
    k, v = rp("r1pct", "1k", "1K00");    refs.place("Device:R", "R922", v, 185, 342, {"1": ("L", "VCM_MB"), "2": ("L", "VCM_BP")}, **k)
    k, v = rp("npn23"); refs.place("Transistor_BJT:BC817", "Q903", v, 205, 325, {"B": ("L", "VCM_BN"), "C": G("p5a"), "E": ("L", "VCM_EN")}, **k)
    k, v = rp("pnp23"); refs.place("Transistor_BJT:BC807", "Q904", v, 205, 350, {"B": ("L", "VCM_BP"), "C": GND, "E": ("L", "VCM_EP")}, **k)
    k, v = rp("r1pct", "2.2", "2R20")
    refs.place("Device:R", "R924", v, 220, 330, {"1": ("L", "VCM_EN"), "2": ("L", "VCM_O")}, **k)
    refs.place("Device:R", "R925", v, 220, 345, {"1": ("L", "VCM_EP"), "2": ("L", "VCM_O")}, **k)
    refs.place("Device:R", "R926", v, 235, 337, {"1": ("L", "VCM_O"), "2": G("vcm")}, **k)
    k, v = rp("cldo");  refs.place("Device:C", "C919", v, 250, 345, {"1": G("vcm"), "2": GND}, **k)
    k, v = rp("c100u"); refs.place("Device:C_Polarized", "C920", v, 260, 345, {"1": G("vcm"), "2": GND}, **k)
    k, v = rp("c100n"); refs.place("Device:C", "C921", v, 130, 350, {"1": G("p5a"), "2": GND}, **k)
    refs.text("VCM: feedback from the VCM node (after 2.2 R) - the pair sources/sinks the +-24 mA RTZ-edge current at I_q ~41 mA (Nexperia models, refs_loop vcm: P(Q903) 0.08 W, P(Q904) 0.08 W, PM 160 deg, -0.33 mV on 23 mA pulses). Q905 thermally coupled to Q903/Q904.", 140, 365)

    # --- U905: A = VE1 set (x1.44 = 7.21 V) -> drives the VE1 LT3045 (U906, bottom strip) via VE1_SET_<ch>;
    # B = VB1 buffer from the compensator chain
    dual("U905", 320, 150, "opamp", (("L", "VE1_FB"), G("ref5f"), G("ve1_set")),
         (("L", "VB1_BUF"), ("L", "VB1_RAW"), ("L", "VB1_BUF")))
    k, v = rp("acas", "4.42k/10.0k", ("4421", "1002"))
    refs.place("Device:R_Pack04", "RN927", v, 300, 140, {"R1.1": G("ve1_set"), "R1.2": ("L", "VE1_FB"), "R2.1": ("L", "VE1_FB"), "R2.2": GND,
                                                       "R3.1": ("NC", ""), "R3.2": ("NC", ""), "R4.1": ("NC", ""), "R4.2": ("NC", "")}, **k)
    refs.text("VE1 = U906 LT3045 (bottom strip) from V8P3: SET = VE1_SET_%s (this op-amp, stiff source - the LT3045 reference-noise term is removed)."
              " (8.3 - 7.2) V x 150 mA = 0.17 W per channel (17(l) headroom table)." % ch, 300, 190)
    # VB1 chain: VE1 -> R928 57.6 -> Q902 (E) ; Q902 B=C -> VB1_RAW ; R929 590 -> GND  (I ~ 10 mA, VB1 = VE1 - V_eb - 0.58 V = 5.93 V)
    k, v = rp("rp01", "59.0", "59R0"); refs.place("Device:R", "R928", v, 300, 215, {"1": G("ve1"), "2": ("L", "VB1_E")}, **k)   # 57.6 -> 59.0: VB1 5.947 V at 25 C (refs_loop vb1)
    k, v = rp("qcomp"); refs.place("%s:2SA1036K" % LOCALLIB, "Q902", v, 315, 225, {"E": ("L", "VB1_E"), "B": ("L", "VB1_RAW"), "C": ("L", "VB1_RAW")}, **k)
    k, v = rp("rp01", "590", RG("590"));   refs.place("Device:R", "R929", v, 330, 240, {"1": ("L", "VB1_RAW"), "2": GND}, **k)
    outnet(932, 360, 215, "VB1_BUF", "vb1")
    refs.text("VB1 = VE1 - V_eb(Q902) - I x R928: dVB1/dV_eb = -R929/(R928+R929) = -0.91 -> QR1 current tempco +0.039 %/K vs +0.435 %/K fixed (11x, refs_loop vb1); static V_eb spread absorbed by the ID campaign.", 300, 260)

    # --- U907 OPA1656: PADB current servo (A diff-amp on the Rpad_p drop, B integrator) and U908 LT3045 +5A
    dual("U907", 320, 300, "fetamp2", (("L", "PD_N"), ("L", "PD_P"), ("L", "PD_OUT")),
         (("L", "PI_N"), ("L", "REF3V57"), ("L", "PI_OUT")))
    k, v = rp("rp01", "40.2k", RG("40.2k"))
    # PD_OUT = +0.25 x (padb_ep - VEE15): padb_ep on the + side (refs_loop.py 2026-10-06 caught the mirrored first draft)
    refs.place("Device:R", "R933", v, 290, 290, {"1": G("padb_ep"), "2": ("L", "PD_P")}, **k)
    refs.place("Device:R", "R934", v, 290, 308, {"1": G("vee15"), "2": ("L", "PD_N")}, **k)
    k, v = rp("rp01", "10.0k", RG("10.0k"))
    refs.place("Device:R", "R935", v, 305, 280, {"1": ("L", "PD_N"), "2": ("L", "PD_OUT")}, **k)
    refs.place("Device:R", "R936", v, 305, 314, {"1": ("L", "PD_P"), "2": GND}, **k)
    divider(937, 290, 335, "2.87k", "7.15k", "REF3V57")                  # 3.568 V = 49.9 mA x 286 / 4
    k, v = rp("rp01", "100k", RG("100k")); refs.place("Device:R", "R939", v, 305, 350, {"1": ("L", "PD_OUT"), "2": ("L", "PI_N")}, **k)
    k, v = rp("cfilm1u"); refs.place("Device:C", "C938", v, 345, 345, {"1": ("L", "PI_N"), "2": ("L", "PI_OUT")}, **k)
    k, v = rp("z2v7");    refs.place("Device:D_Zener", "D902", v, 360, 355, {"K": ("L", "PI_OUT"), "A": GND}, **k)
    k, v = rp("rp01", "1k", RG("1k"));    refs.place("Device:R", "R940", v, 375, 345, {"1": ("L", "PI_OUT"), "2": G("padb_base")}, **k)
    refs.text("PADB: 0.25 x (padb_ep - VEE15) = 3.575 V at 50 mA; diff-amp inputs sit at ~ -0.14 V (inside the OPA1656 CM range). Integrator polarity: I high -> PD_OUT high -> gate falls."
              " Cpadb 100u (CORE C3) + R940 1k = 1.6 Hz gate filter; D902 bounds start-up current to ~57 mA. p/m share the gate: I_m = I_p +- Mpad V_th mismatch (static, calibrated).", 290, 372)
    # ---------------- per-channel POL regulators (dual-mono pass 2026-10-12, bom 17(l)/17(m3); user ruling:
    # every LDO lives on the sheet it powers - REFS hosts the channel housekeeping rails).
    # PGFB divider is MANDATORY on the LT30xx: below ~0.3 V PGFB the part runs the 2 mA fast-startup SET
    # current and the output pegs at the rail - the old PGFB->GND strapping was broken.  LT3045 trips PGFB at
    # +0.30 V vs GND, LT3094 at -0.30 V vs GND, so the SAME OUT->PGFB->GND divider works for both polarities:
    # 442k/10k -> +-13.6 V trip on the +-15 V rails, 205k/10k -> -90 % of +7.2 V, 90.9k/10k -> 92 % of +3.3 V.
    # PG is open-collector: all PG pins wire-AND onto the shared PG_ALL global (pull-up on the POWER sheet).
    pols = [("U906", "ldo",   "v8p3", "ve1",   None,   None,   "205k", "2053", "VE1 = +7.2 V, 150 mA - SET driven by U905A (VE1_SET_%s)"),
            ("U908", "ldo",   "v4p3", "p5a",   "33.2k","3322", "90.9k","9092", "+3V3A VCM-stage rail, ~50 mA"),
            ("U909", "ldo",   "p16a", "p15a",  "150k", "1503", "442k", "4423", "P15A = +15 V op-amp rail, ~60 mA"),
            ("U910", "ldo_n", "n16a", "n15a",  "150k", "1503", "442k", "4423", "N15A = -15 V op-amp rail, ~90 mA"),
            ("U911", "ldo_n", "n16a", "vee15", "150k", "1503", "442k", "4423", "VEE15 = -15 V cell/Rpad sink, ~160 mA")]
    refs.text("PER-CHANNEL POL LDOs (dual-mono 17(m3)): LT3045 positive / LT3094 negative. EN/UV->IN (autostart), ILIM->GND (max limit),"
              " VIOC->GND (LT3094, upstream tracking unused). PGFB: OUT->Rtop->PGFB->10k->GND + 1 nF (+-0.30 V trip = ~90 % of rail). PG open-collector"
              " -> PG_ALL. SET: 100 uA x R_SET (+4.7 uF); VE1 SET is driven by U905A instead (stiff 7.21 V) with 100 nF.", 20, 385)
    for i, (ref, pk, inn, outn, rset, rscode, rpgt, rpgtc, desc) in enumerate(pols):
        x, y, neg = 60 + 105 * i, 400, pk == "ldo_n"
        nb = 940 + 10 * i                        # numeric refdes base: C940.., R950..
        pgf, setn = ("L", "PGF_" + ref), (G("ve1_set") if ref == "U906" else ("L", "SET_" + ref))
        k, v = rp(pk)
        nets = {"IN": G(inn), "EN/UV": G(inn), "PG": G("pg_all"), "PGFB": pgf, "SET": setn,
                "ILIM": GND, "GND": GND, "OUTS": G(outn), "OUT": G(outn)}
        if neg:
            nets["VIOC"] = GND
        refs.place("Regulator_Linear:LT3045xMSE" if not neg else "Regulator_Linear:LT3094xMSE", ref, v, x, y, nets, **k)
        k, v = rp("cldo")
        refs.place("Device:C", "C%d" % nb, v, x - 30, y - 10, {"1": G(inn), "2": GND}, **k)          # C_IN 10u
        refs.place("Device:C", "C%d" % (nb + 1), v, x + 28, y - 12, {"1": G(outn), "2": GND}, **k)   # C_OUT 10u
        # 100u electrolytic on the output; on the NEGATIVE rails the + terminal goes to GND
        k, v = rp("c100u")
        refs.place("Device:C_Polarized", "C%d" % (nb + 2), v, x + 38, y - 12,
                   {"1": GND, "2": G(outn)} if neg else {"1": G(outn), "2": GND}, **k)
        if rset:                                                                                    # SET: 100 uA x R_SET + 4.7u
            k, v = rp("rp01", rset, rscode); refs.place("Device:R", "R%d" % (950 + 10 * i), v, x - 30, y + 4, {"1": setn, "2": GND}, **k)
            k, v = rp("c4u7");           refs.place("Device:C", "C%d" % (nb + 3), v, x - 30, y + 22, {"1": setn, "2": GND}, **k)
        else:                                                                                       # VE1: SET driven by U905A, 100n HF only
            k, v = rp("c100n");          refs.place("Device:C", "C%d" % (nb + 3), v, x - 30, y + 22, {"1": setn, "2": GND}, **k)
        k, v = rp("rp01", rpgt, rpgtc);  refs.place("Device:R", "R%d" % (951 + 10 * i), v, x + 28, y + 6, {"1": G(outn), "2": pgf}, **k)
        k, v = rp("rp01", "10k", "1002"); refs.place("Device:R", "R%d" % (952 + 10 * i), v, x + 28, y + 16, {"1": pgf, "2": GND}, **k)
        k, v = rp("c1n");                refs.place("Device:C", "C%d" % (nb + 4), v, x + 40, y + 10, {"1": pgf, "2": GND}, **k)
        refs.text("%s %s" % (ref, desc % ch if "%s" in desc else desc), x - 30, y + 30)

    # --- REFS test points (progress.md TP mandate): every rail + every reference/bias node on THT hook pads
    # (low-Z DC - rule c), GND pads beside the bank (rule d).  REF5/REF5F exist once per board - L sheet only.
    refs.text("TEST POINTS (TP rules c/d): every POL rail and every reference/bias node on hook pads; GND pads at"
              " the end of each row.  Precision nodes (VREF/VFR/VCM/VB1/V_VG) are buffered/stiff - a 10 Meg probe is safe.", 20, 448)
    rp_nets = ["p15a", "n15a", "vee15", "ve1", "p5a", "v8p3", "v4p3",
               "vb1", "vcm", "vfr", "vref", "v_vg", "casb2_p", "padb_base", "padb_ep", "ve1_set", "mid_p"]
    for i, net in enumerate(rp_nets):
        tp(refs, "TP%d" % (950 + i), 40 + 30 * (i % 9), 470 + 30 * (i // 9), G(net))
    tp(refs, "TP967", 310, 500, GND)
    tp(refs, "TP968", 340, 500, GND)
    if ch == "L":
        tp(refs, "TP970", 40, 530, G("ref5"))
        tp(refs, "TP971", 70, 530, G("ref5f"))
        tp(refs, "TP972", 100, 530, GND)


def main():
    d = json.load(open(REF))
    P = d["params"]
    os.makedirs(OUT, exist_ok=True)
    write_local_lib()
    write_local_footprints()
    write_som_seed_board()
    root = Sheet("%s.kicad_sch" % PROJECT, "BFDAC analog board - root (L + R channels)", "A1")
    root.inst_path = "/" + root.uuid
    root.inst_paths = [root.inst_path]
    ncell = d["n_cells"]
    # two identical analog channels: L keeps the original sheet files / designators, R gets _r files, offset designators
    chan = {}
    for ch in ("L", "R"):
        sfx = "" if ch == "L" else "_r"
        cell_uuids = [U() for _ in range(ncell)]
        cell = Sheet("cell%s.kicad_sch" % sfx, "Current cell (x64) - %s channel" % ch, "A4")
        cell.inst_paths = ["%s/%s" % (root.inst_path, u) for u in cell_uuids]
        cell.inst_path = None
        core = Sheet("core%s.kicad_sch" % sfx, "Core %s: cascode / replica-ff / padding / bus / tail reference" % ch, "A3")
        iv = Sheet("iv%s.kicad_sch" % sfx, "I/V %s - P5 TIA (both rails)" % ch, "A3")
        refs = Sheet("refs%s.kicad_sch" % sfx, "Rails and references - %s channel" % ch + ("" if ch == "L" else " (REF5F / rails from the L sheet)"), "A1")
        for s, nm in ((cell, "CELL"), (core, "CORE"), (iv, "IV"), (refs, "REFS")):
            s.chan = ch
            s.name = "%s_%s" % (nm, ch)
        chan[ch] = dict(cell=cell, core=core, iv=iv, refs=refs, cell_uuids=cell_uuids)
    fpga = Sheet("fpga.kicad_sch", "FPGA interface and clock tree", "A1")
    clkr = Sheet("clkr.kicad_sch", "R-channel clock tree: U303 root + 8 leaves -> MCLKR01..64", "A1")
    som = Sheet("som.kicad_sch", "SoM carrier: J2-J5 / J7 / J8, 12 V feed, JTAG, boot straps", "A1")
    ctrl = Sheet("ctrl.kicad_sch", "Control plane: AP isolation barrier, temperature sensors, LEDs, rail telemetry", "A1")
    out = Sheet("out.kicad_sch", "Output routing: K4 mute relays, unmute gate, XLR (both channels)", "A3")
    xlat = Sheet("xlat.kicad_sch", "Level translators: 16 x SN74AXC8T245, DATnn_1V8 / DATRnn_1V8 -> DATnn / DATRnn (3.3 V)", "A2")
    xlat.name = "XLAT"
    power = Sheet("power.kicad_sch", "Power entry: pre-reg harness J603, V33FF supervisor, PG_ALL wired-AND", "A3")
    power.name = "POWER"
    bringup = Sheet("bringup.kicad_sch", "Bring-up: manual tests and supply presence indicators", "A2")
    bringup.name = "BRINGUP"
    subsheets = [chan["L"]["core"], chan["L"]["iv"], chan["L"]["refs"], chan["R"]["core"], chan["R"]["iv"], chan["R"]["refs"],
                 fpga, clkr, som, ctrl, out, xlat, power, bringup]
    sub_uuid = {}
    for s in subsheets:
        sub_uuid[s.fname] = U()
        s.inst_path = "%s/%s" % (root.inst_path, sub_uuid[s.fname])
        s.inst_paths = [s.inst_path]
    for ch in ("L", "R"):
        c = chan[ch]
        build_channel(ch, c["cell"], c["core"], c["iv"], c["refs"], d)

    G = lambda n: ("G", n.upper())
    GND = ("GND", "GND")
    H = lambda n: ("H", n)

    # ---------------- FPGA interface + clock tree sheet
    def fp_(key):
        v, fp, mpn, ds = FPGA_PARTS[key]
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    def pw_(key, value=None, code=None):
        """PWR_PARTS access for the board-level LDOs/supervisors placed on the sheets they serve
        (dual-mono ruling 2026-10-12: POL regulators live with their loads, not on the power sheet)."""
        v, fp, mpn, ds = PWR_PARTS[key]
        if "%s" in mpn:
            mpn = mpn % (code or value)
        if value:
            v = value
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    LIB = lambda n: "%s:%s" % (LOCALLIB, n)
    fpga.text("FPGA interface (bom 1.3): Alinx ACVU13P module, carrier connector J6 (cascode_l[63:0] -> DAT01..64, banks 64/65, LVCMOS18;"
              " mclk B65_L12_P GC LVCMOS18 single-ended + clk_sel B65_L16_P - moved off J1 2026-10-08 so the clock block lives on the analog edge). Pin map = Alinx/ACVU13P-Pin-Assignment-20260703.csv + cascode_pins_gen.txt."
              " Unused connector pins are no-connect type; all GND pins tied. V18 (translator A-side reference) is SUPPLIED BY THE SoM via VCCIO_65_EX / VCCIO_69/70/71 - no carrier 1.8 V regulator.", 20, 17)
    fpga.text("Clock tree (bom 1.1, item 15 option 2): no mux chip. Y301 (49.152) / Y302 (45.1584) CCHD-957 enabled one at a time via E/D (clk_sel -> Y302, !clk_sel -> Y301 through U301 LVC1G04;"
              " clk_sel pulled low = 48k family default), outputs joined through 33 R each on the XOCLK net -> root U302 (this channel; R channel root U303 on the R sheet, same net) -> 8 leaves"
              " U304..U311 -> 64 FF clocks MCLK01..64, 33 R at every driver pin. FPGA mclk = U312 LVC1G125 copy of XOCLK -> 100/120 divider -> J6 C30 (B65_L12_P / AW28, GC) as LVCMOS18 single-ended"
              " (FPGA XDC: IBUF, not IBUFDS - TODO). CCHD-957 verified (Rev N, 2026-10-08): E/D <= 0.3 Vcc -> output High Z (tri-state/standby, 200 ns disable, 1.5 mA), open/>= 0.7 Vcc -> active; pinout 1 E/D 2 GND 3 OUT 4 Vcc; footprint bfdac:Crystek_CCHD-957.", 20, 22)
    # --- connectors (J6 = cascode_l data + cascode_r[48..63] + mclk/clk_sel + JTAG; J1 = flash + control plane only)
    k, v = fp_("j")
    J, used = alinx_used()
    for u in range(4):
        fpga.place(LIB("ACVU13P_J6"), "J6", v, 60 + 90 * u, 100, conn_nets(J, used, "J6", G, GND), unit=u + 1, **k)
        fpga.place(LIB("ACVU13P_J1"), "J1", v, 440 + 90 * u, 100, conn_nets(J, used, "J1", G, GND), unit=u + 1, **k)
    fpga.text("J1 control-plane pins (bank 71, xdc s4-7/10/5b) -> CTRL sheet: SPI_SCLK/CS_N/MOSI/MISO, FPGA_IRQ_N, EXT_RST_N (R27, new 2026-10-07), I2S_BCLK/LRCLK/DATA,"
              " RLY_LINE_MUTE (-> OUT sheet unmute gate), LED_DBG0..3. relay_hp_mute (T28) / relay_hp_rails (N26) struck with bom 8, relay_level[1:0] (P26/N29) struck 2026-10-07"
              " (level is digital, bom 7) - all left no-connect; RTL ports still exist. DATR01..64 = cascode_r (bank 67 on J5 + bank 66 on J6; moved off J1 bank 69 2026-10-08 so both channels' drive leaves the SoM on the analog edge) -> the 64 R-channel CELL sheets (root). JTAG_* and SOM_PG from J6 -> SOM sheet.", 20, 27)
    # --- oscillators, enable mux, FPGA copy
    kr_, vr_ = fp_("rser")
    kc_, vc_ = fp_("cdec")
    for key, ref, y, cin, en in (("xo", "Y301", 330, "0", "CLK_SEL_N"), ("xo2", "Y302", 365, "1", "CLK_SEL")):
        k, v = fp_(key)
        fpga.place(LIB("CCHD-957"), ref, v, 60, y, {"E/D": G(en), "GND": GND, "OUT": ("L", "XO%s" % cin), "Vcc": G("v33clk")}, **k)
        fpga.place("Device:R", "R30%s" % (int(cin) + 1), vr_, 85, y, {"1": ("L", "XO%s" % cin), "2": G("xoclk")}, **kr_)
        fpga.place("Device:C", "C30%s" % (int(cin) + 1), vc_, 25, y, {"1": G("v33clk"), "2": GND}, **kc_)
    k, v = fp_("inv")
    fpga.place("74xGxx:74LVC1G04", "U301", v, 60, 300, {"2": G("clk_sel"), "4": G("clk_sel_n"), "GND": GND, "VCC": G("v33clk")}, **k)
    k, v = fp_("rpu")
    fpga.place("Device:R", "R303", v, 25, 300, {"1": G("clk_sel"), "2": GND}, **k)
    fpga.place("Device:C", "C303", vc_, 85, 300, {"1": G("v33clk"), "2": GND}, **kc_)
    k, v = fp_("buf")
    fpga.place("74xGxx:74LVC1G125", "U312", v, 130, 300, {"1": GND, "2": G("xoclk"), "4": ("L", "FPGACLK_3V3"), "GND": GND, "VCC": G("v33clk")}, **k)
    k, v = fp_("rdivs")
    fpga.place("Device:R", "R304", v, 155, 300, {"1": ("L", "FPGACLK_3V3"), "2": G("mclk_fpga")}, **k)
    k, v = fp_("rdivp")
    fpga.place("Device:R", "R305", v, 170, 310, {"1": G("mclk_fpga"), "2": GND}, **k)
    fpga.place("Device:C", "C304", vc_, 130, 320, {"1": G("v33clk"), "2": GND}, **kc_)
    k, v = fp_("cbulk")
    fpga.place("Device:C", "C320", v, 200, 420, {"1": G("v33clk"), "2": GND}, **k)
    # --- fanout tree: one root + 8 leaves per channel.  L: U302 / U304..U311 on this sheet; R: U303 / U330..U337 on CLKR.
    kf, vf = fp_("fan")
    kr, vr = fp_("rser")
    kp, vp = fp_("rpu")
    kc, vc = fp_("cdec")
    fanpins = lambda cin, outs: dict([("CLKIN", cin), ("1G", ("L", "OE")), ("VDD", G("v33clk")), ("GND", GND)] +
                                     [("Y%d" % i, o) for i, o in enumerate(outs)])
    def fanout(sh, root_ref, r_in, r_oe, leaf_refs, leaf_rs, ser0, cap0, mclk, x=0, y=0):
        """XOCLK -> r_in 33 R -> root -> 8 x (33 R -> leaf -> 8 x 33 R -> mclk%02d).  Refs: root_ref, leaf_refs[8],
        r_in/r_oe, leaf_rs[8] (leaf input series), ser0.. (64 output series), cap0.. (3 per device)."""
        sh.place("Device:R", r_in, vr, x + 215, y + 350, {"1": G("xoclk"), "2": ("L", "ROOT_IN")}, **kr)
        sh.place("Device:R", r_oe, vp, x + 235, y + 300, {"1": G("v33clk"), "2": ("L", "OE")}, **kp)
        sh.place(LIB("LMK1C1108"), root_ref, vf, x + 260, y + 350, fanpins(("L", "ROOT_IN"), [("L", "LEAF%d" % i) for i in range(8)]), **kf)
        for i in range(3):
            sh.place("Device:C", "C%d" % (cap0 + i), vc, x + 250 + 12 * i, y + 390, {"1": G("v33clk"), "2": GND}, **kc)
        for lf in range(8):
            x0, y0 = x + 380 + (lf % 4) * 108, y + 330 + (lf // 4) * 90
            sh.place("Device:R", leaf_rs[lf], vr, x0 - 30, y0, {"1": ("L", "LEAF%d" % lf), "2": ("L", "LEAF%dR" % lf)}, **kr)
            sh.place(LIB("LMK1C1108"), leaf_refs[lf], vf, x0, y0,
                     fanpins(("L", "LEAF%dR" % lf), [("L", "L%dY%d" % (lf, i)) for i in range(8)]), **kf)
            for i in range(8):
                n = lf * 8 + i
                sh.place("Device:R", "R%d" % (ser0 + n), vr, x0 + 32 + 7.62 * i, y0,
                         {"1": ("L", "L%dY%d" % (lf, i)), "2": G("%s%02d" % (mclk, n + 1))}, **kr)
            for i in range(3):
                sh.place("Device:C", "C%d" % (cap0 + 3 + 3 * lf + i), vc, x0 - 30 + 12 * i, y0 + 35, {"1": G("v33clk"), "2": GND}, **kc)
    fanout(fpga, "U302", "R306", "R307", ["U3%02d" % (lf + 4) for lf in range(8)], ["R31%d" % lf for lf in range(8)], 400, 321, "MCLK")
    fpga.text("R channel: XOCLK -> R350 33 R -> U303 root -> U330..U337 -> MCLKR01..64 on the CLKR sheet (same tree, same V33CLK).", 200, 320)
    clkr.text("R-channel clock tree (bom 1.1): identical to the L tree on the FPGA sheet. XOCLK (global, from Y301/Y302 via 33 R each) -> R350 33 R -> U303 LMK1C1108 root"
              " -> 8 x 33 R -> U330..U337 leaves -> 64 x 33 R -> MCLKR01..64 (R CELL sheets). OE pull-up R351; 100n per VDD pin; V33CLK rail.", 20, 17)
    fanout(clkr, "U303", "R350", "R351", ["U3%02d" % (30 + lf) for lf in range(8)], ["R36%d" % lf for lf in range(8)], 600, 370, "MCLKR", x=-150, y=-250)
    # --- V33CLK POL LDO on the CLKR sheet (dual-mono 17(m3): the LDO lives with the clock tree it feeds;
    # the tree is physically one fanout set, so V33CLK is a single board rail).  LT3045 from V4P3:
    # SET = 100 uA x 33.2k = +3.32 V; PGFB 90.9k/10k + 1 nF (mandatory - below 0.30 V PGFB the SET current
    # jumps 100 uA -> 2 mA); PG open-collector -> PG_ALL; EN/UV->IN, ILIM->GND.
    clkr.text("V33CLK LDO (U340): LT3045 from V4P3, ~500 mA stereo clock tree + XOs; PG -> PG_ALL (wired-AND on the POWER sheet).", 20, 555)
    k, v = pw_("lt3045")
    clkr.place("Regulator_Linear:LT3045xMSE", "U340", v, 90, 480,
               {"IN": G("v4p3"), "EN/UV": G("v4p3"), "PG": G("pg_all"), "PGFB": ("L", "PGF_U340"),
                "SET": ("L", "SET_U340"), "ILIM": GND, "GND": GND, "OUTS": G("v33clk"), "OUT": G("v33clk")}, **k)
    k, v = pw_("cldo10")
    clkr.place("Device:C", "C840", v, 60, 470, {"1": G("v4p3"), "2": GND}, **k)
    clkr.place("Device:C", "C841", v, 118, 468, {"1": G("v33clk"), "2": GND}, **k)
    clkr.place("Device:C", "C842", v, 130, 468, {"1": G("v33clk"), "2": GND}, **k)
    k, v = pw_("rmon", "33.2k", "3322"); clkr.place("Device:R", "R840", v, 60, 484, {"1": ("L", "SET_U340"), "2": GND}, **k)
    k, v = pw_("rcset");               clkr.place("Device:C", "C843", v, 60, 502, {"1": ("L", "SET_U340"), "2": GND}, **k)
    k, v = pw_("rmon", "90.9k", "9092"); clkr.place("Device:R", "R841", v, 118, 486, {"1": G("v33clk"), "2": ("L", "PGF_U340")}, **k)
    k, v = pw_("rmon", "10k", "1002");   clkr.place("Device:R", "R842", v, 118, 496, {"1": ("L", "PGF_U340"), "2": GND}, **k)
    k, v = pw_("cpgfb");               clkr.place("Device:C", "C844", v, 130, 490, {"1": ("L", "PGF_U340"), "2": GND}, **k)

    # --- CLKR test points: V33CLK/V4P3 on hook pads; XOCLK + representative MCLKR leaf outputs through 1k
    # isolation stubs (rule b - fanout matching is in the 33 R series + trace length, the probe must not add a leg).
    clkr.text("TEST POINTS (rule b): XOCLK / MCLKR leaves tapped through 1k -> 1.0 mm pad; rails on hook pads; GND beside.", 200, 555)
    tp(clkr, "TP340", 60, 575, G("v33clk"))
    tp(clkr, "TP341", 90, 575, G("v4p3"))
    tp_stub(clkr, "TP342", "R845", 130, 575, G("xoclk"), "TP_XOCLK", pw_)
    tp_stub(clkr, "TP343", "R846", 180, 575, G("mclkr01"), "TP_MCLKR01", pw_)
    tp_stub(clkr, "TP344", "R847", 230, 575, G("mclkr64"), "TP_MCLKR64", pw_)
    tp(clkr, "TP345", 280, 575, GND)
    tp(clkr, "TP346", 310, 575, GND)

    # --- coefficient flash: MT25QU02G sites on one bus (bom item 18 / 18a), bank 70
    fpga.text("Coefficient flash (bom 18/18a, RULED 2026-10-05): %d x MT25QU02G 2 Gb 1.8 V SPI NOR populated (U320-U323 = 8 Gb = 90 filters at 10M taps, "
              "18-bit mirrored; need 60+ = 30 designs x {44.1k, 48k}) on ONE bus: CF_CLK, CF_DQ0..3 shared, chip selects CF_CS0..3 (FPGA addr[29:28]). "
              "J1 bank 70 (V18): CLK J35, CS0 J36, DQ0 H36, DQ1 G36, DQ2 H34, DQ3 G34, CS1 H37, CS2 H38, CS3 G37 - matches vu13p_dac_top.xdc s11b. "
              "x1 at 25 MHz first pass, forwarded SCK on user IO (not STARTUPE3). 10k pull-ups on each S#, DQ2 (W#) and DQ3 (HOLD#); RESET# strapped to V18. "
              "Layout: place next to J1 A19-A26/B19-B29 on the carrier top side (NOT under the SoM); all CF_* <= 75 mm pad-to-ball, "
              "CLK/DQ daisy-chained U320->U323 with <= 10 mm stubs, 33R series on CF_CLK at the connector. Ball map / 5x5 BGA footprint TO VERIFY." % CFLASH_POPULATED, 20, 470)
    kq, vq = fp_("flash")
    kp18, vp18 = fp_("rpu18")
    kc18, vc18 = fp_("cdec18")
    kr33, vr33 = fp_("rser")
    for i in range(4):
        x0 = 80 + 90 * i
        dnp = i >= CFLASH_POPULATED
        fpga.place(LIB("MT25QU02G"), "U32%d" % i, vq, x0, 510,
                   {"S#": ("L", "CF_CS%d" % i), "C": ("L", "CF_CLK"), "RESET#": G("v18"), "VCC": G("v18"), "VSS": GND,
                    "DQ0": ("L", "CF_DQ0"), "DQ1": ("L", "CF_DQ1"), "DQ2": ("L", "CF_DQ2"), "DQ3": ("L", "CF_DQ3")}, dnp=dnp, **kq)
        fpga.place("Device:R", "R32%d" % i, vp18, x0 - 30, 495, {"1": G("v18"), "2": ("L", "CF_CS%d" % i)}, **kp18)
        fpga.place("Device:C", "C36%d" % i, vc18, x0 + 30, 530, {"1": G("v18"), "2": GND}, dnp=dnp, **kc18)
    # shared-bus pull-ups (W#/HOLD# lines) and the CLK series resistor at the connector exit
    fpga.place("Device:R", "R324", vp18, 50, 530, {"1": G("v18"), "2": ("L", "CF_DQ2")}, **kp18)
    fpga.place("Device:R", "R325", vp18, 50, 545, {"1": G("v18"), "2": ("L", "CF_DQ3")}, **kp18)
    fpga.place("Device:R", "R326", vr33, 50, 560, {"1": ("L", "CF_CLK_J1"), "2": ("L", "CF_CLK")}, **kr33)

    # --- FPGA test points: MCLK_FPGA + representative L-tree MCLK leaves through 1k stubs (rule b);
    # CLK_SEL + GND on hook pads.  Column sits in the free x>795 strip at the right edge.
    fpga.text("TEST POINTS (rule b): MCLK_FPGA / MCLK leaves through 1k -> 1.0 mm pad; CLK_SEL + GND on hook pads.", 620, 580)
    tp_stub(fpga, "TP300", "R327", 790, 60, G("mclk_fpga"), "TP_MCLK_FPGA", pw_)
    tp_stub(fpga, "TP301", "R328", 790, 90, G("mclk01"), "TP_MCLK01", pw_)
    tp_stub(fpga, "TP302", "R329", 790, 120, G("mclk64"), "TP_MCLK64", pw_)
    tp(fpga, "TP303", 812, 150, G("clk_sel"))
    tp(fpga, "TP304", 812, 180, GND)

    # ---------------- SoM carrier sheet: remaining connectors, 12 V feed, JTAG, boot straps
    def sp_(key):
        v, fp, mpn, ds = SOM_PARTS[key]
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    som.text("Alinx ACVU13P SoM carrier (bom item 16): eight Samtec ADM6-60-01.5-L-4-2-A-TR (240-pin, 4 x 60, 0.635 mm) - J1/J6 on the FPGA sheet, the other six here."
             " J3/J4/J7/J8 carry only MGT quads (unused - every signal pin no-connect, all GND pins tied). J2 = +12 V module feed (52 pins) + SelectMAP (unused) + BOOT_M straps."
             " J5 = bank 67 (cascode_r[0..31] -> DATRnn), VCCIO_66/67/68 (tied to V18 like every VCCIO: an unpowered bank is not allowed), SYSMON VP/VN to GND."
             " Connector X/Y positions and the Samtec footprint are the layout blocker (Alinx drawing requested).", 20, 17)
    k, v = sp_("j")
    for n, (c, x0, y0) in enumerate((("J2", 60, 110), ("J5", 440, 110), ("J3", 60, 230), ("J4", 440, 230), ("J7", 60, 350), ("J8", 440, 350))):
        for u in range(4):
            som.place(LIB("ACVU13P_%s" % c), c, v, x0 + 90 * u, y0, conn_nets(J, used, c, G, GND), unit=u + 1, **k)
    # +12 V feed: arrives on J506 (CTRL sheet, left-edge mezz - absorbed J801 2026-10-12); bulk + ceramic at J2
    som.text("+12 V SoM feed (bom 17(d): 12 V switcher + heavy filter -> SoM only; planning figure 15 A / 180 W, user 2026-10-10). Board-to-board entry = J507/J508 REDCUBE"
             " press-fit terminals on the CTRL sheet (left edge, ~30 mm stack - conductive standoffs; the J801 Mini-Fit was absorbed). 2 x 220 uF polymer + 4 x 10 uF X7R kept here at J2"
             " (the SoM connector end of the feed).", 20, 455)
    k, v = sp_("cpoly")
    for i in range(2):
        som.place("Device:C_Polarized", "C80%d" % (1 + i), v, 90 + 12 * i, 480, {"1": G("v12som"), "2": GND}, **k)
    k, v = sp_("c10u25")
    for i in range(4):
        som.place("Device:C", "C80%d" % (3 + i), v, 120 + 12 * i, 480, {"1": G("v12som"), "2": GND}, **k)
    # JTAG header (Xilinx 14-pin 2 mm): odd pins GND, 2 VREF (bank-0 VCCO = 1.8 V on the SoM), 4 TMS 6 TCK 8 TDO 10 TDI, 12/14 NC
    som.text("JTAG: FPGA_TCK/TMS/TDI/TDO from J6 D17-D20 to a Xilinx 14-pin 2 mm header. VREF = V18 (UltraScale+ bank 0 is 1.8 V)."
             " VERIFY: the SoM may already carry its own JTAG header (Alinx JTAG.csv) - keep both, cable goes to one.", 200, 455)
    k, v = sp_("jtag")
    som.place("Connector_Generic:Conn_02x07_Odd_Even", "J802", v, 230, 485,
              {"Pin_1": GND, "Pin_3": GND, "Pin_5": GND, "Pin_7": GND, "Pin_9": GND, "Pin_11": GND, "Pin_13": GND,
               "Pin_2": G("v18"), "Pin_4": G("JTAG_TMS"), "Pin_6": G("JTAG_TCK"), "Pin_8": G("JTAG_TDO"), "Pin_10": G("JTAG_TDI"),
               "Pin_12": ("NC", ""), "Pin_14": ("NC", "")}, **k)
    # BOOT_M[2:0] straps, DNP: master SPI = 001 (M0 high, M1/M2 low)
    som.text("BOOT_M[2:0] (J2 B1/B2/B4): DNP 4.7k straps for master-SPI 001 (M0 -> V18, M1/M2 -> GND). The SoM boots its own QSPI; populate only if the manual requires carrier straps  ** VERIFY **", 330, 455)
    k, v = sp_("rstrap")
    som.place("Device:R", "R801", v, 350, 480, {"1": G("BOOT_M0"), "2": G("v18")}, dnp=True, **k)
    som.place("Device:R", "R802", v, 365, 480, {"1": G("BOOT_M1"), "2": GND}, dnp=True, **k)
    som.place("Device:R", "R803", v, 380, 480, {"1": G("BOOT_M2"), "2": GND}, dnp=True, **k)
    som.text("SOM_PG (J6 D34, VCCAUX_PG): module power-good -> CTRL sheet LED / AP status. All PWR_FLAGs live in the rails table on the REFS sheet (V18, V12SOM, V33D, ...).", 330, 500)

    # --- SoM test points (rule c): rails / DONE / JTAG / boot straps on hook pads, GND beside.  JTAG also has
    # J802, but pads let a scope hit the lines without a cable.
    som.text("TEST POINTS (rule c): V12SOM / V18 / FPGA_DONE / JTAG / BOOT_M on hook pads; GND at the end.", 40, 520)
    for i, net in enumerate(["v12som", "v18", "fpga_done", "jtag_tck", "jtag_tms", "jtag_tdi", "jtag_tdo",
                             "boot_m0", "boot_m1", "boot_m2"]):
        tp(som, "TP%d" % (801 + i), 40 + 32 * i, 540, G(net))
    tp(som, "TP811", 40 + 32 * 10, 540, GND)
    tp(som, "TP812", 40 + 32 * 11, 540, GND)

    # ---------------- control-plane sheet: AP isolation barrier (bom 21), temperature sensors (bom 20), LEDs
    def cp_(key):
        v, fp, mpn, ds = CTRL_PARTS[key]
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    ctrl.text("Isolation barrier (user rulings 2026-10-05 / 2026-10-07): the application processor (AP) is its own ground domain (GND_AP, VAP_IO). Everything that crosses to the"
              " FPGA/analog side goes through isolators: U501 MAX22445C = control SPI (SCLK/CS_N/MOSI AP->FPGA, MISO back), U502 MAX22445F = I2S with the FPGA as master (BCLK/LRCLK FPGA->AP + FPGA_IRQ_N, SDATA AP->FPGA; sides swapped),"
              " U503 MAX22444C = AP reset -> EXT_RST_N (+3 spare fwd), U504 ISO1640 = I2C to the four TMP117 (sensor bus on the FPGA/analog side, V33D = ISO1640 side 1; AP = side 2, VAP_IO >= 2.25 V). FPGA side of the MAX2244x = V18 (1.71 V capable; ISO77xx were not - 2026-10-09)."
              " AP not chosen yet (today-list 2026-10-07) -> J506 FX18-40 left-edge mezz carries the AP side (~30 mm stack, 2026-10-13); the +12 V SoM feed is on J507/J508 REDCUBE terminals (was J501 + J801). SPI: 10 MHz standard-timed guaranteed, 50 MHz with AP RX sample delay (bom 21).", 20, 17)
    ctrl.text("TMP117 placement (bom 20, 4 so far): U505 L cascode/replica array, U506 R cascode/replica array, U507 R_off/Rpad heat zone, U508 clock XO area. V33D = digital 3.3 V (power sheet, PWR_FLAG here)."
              " ALERT pins unused. Pull-ups 2.2k each side of the ISO1640.", 20, 24)
    # left-edge mezz, ~30 mm board-to-board stack (user 2026-10-13, split power/signal):
    # J506 = Hirose FX18-40 digital connector - every AP signal sits beside a GND_AP return on the
    # 0.8 mm field (SOM_PG added so the host can read module power-good). 12 V does NOT ride this
    # connector - no blade mezz reaches 30 mm - it enters on J507/J508 REDCUBE press-fit terminals
    # which double as the conductive standoffs to the AP/tube board.  Absorbs J501 + J801.
    k, v = cp_("jap")
    ctrl.place("Connector_Generic:Conn_02x20_Odd_Even", "J506", v, 40, 70,
               {"Pin_1": G("AP_SPI_SCLK"),  "Pin_2": G("GND_AP"),  "Pin_3": G("AP_SPI_CS_N"),  "Pin_4": G("GND_AP"),
                "Pin_5": G("AP_SPI_MOSI"),  "Pin_6": G("GND_AP"),  "Pin_7": G("AP_SPI_MISO"),  "Pin_8": G("GND_AP"),
                "Pin_9": G("AP_I2S_BCLK"),  "Pin_10": G("GND_AP"), "Pin_11": G("AP_I2S_LRCLK"), "Pin_12": G("GND_AP"),
                "Pin_13": G("AP_I2S_DATA"), "Pin_14": G("GND_AP"), "Pin_15": G("AP_IRQ_N"),    "Pin_16": G("GND_AP"),
                "Pin_17": G("AP_RST_N"),    "Pin_18": G("GND_AP"), "Pin_19": G("AP_SDA"),      "Pin_20": G("GND_AP"),
                "Pin_21": G("AP_SCL"),      "Pin_22": G("GND_AP"), "Pin_23": G("SOM_PG"),      "Pin_24": G("GND_AP"),
                "Pin_25": G("VAP_IO"),      "Pin_26": G("GND_AP"), "Pin_27": G("GND_AP"),      "Pin_28": G("GND_AP"),
                "Pin_29": G("GND_AP"),      "Pin_30": G("GND_AP"), "Pin_31": G("GND_AP"),      "Pin_32": G("GND_AP"),
                "Pin_33": G("GND_AP"),      "Pin_34": G("GND_AP"), "Pin_35": G("GND_AP"),      "Pin_36": G("GND_AP"),
                "Pin_37": G("GND_AP"),      "Pin_38": G("GND_AP"), "Pin_39": G("GND_AP"),      "Pin_40": G("GND_AP")}, **k)
    # 12 V SoM feed: REDCUBE press-fit terminals (conductive standoffs at the 30 mm stack)
    k, v = cp_("rc12v"); ctrl.place("Connector_Generic:Conn_01x01", "J507", v, 40, 125, {"1": G("V12SOM")}, **k)
    k, v = cp_("rcgnd"); ctrl.place("Connector_Generic:Conn_01x01", "J508", v, 55, 125, {"1": GND}, **k)
    k, v = cp_("rpu10k"); ctrl.place("Device:R", "R501", v, 75, 130, {"1": G("VAP_IO"), "2": G("AP_RST_N")}, **k)
    # isolators: side 1 (AP) on the left, side 2 (FPGA) on the right
    k, v = cp_("isoC")
    ctrl.place(LIB("MAX22445"), "U501", v, 130, 70,
               {"VDDA": G("VAP_IO"), "GNDA": G("GND_AP"), "GNDAB": G("GND_AP"), "ENA": G("VAP_IO"),
                "IN1": G("AP_SPI_SCLK"), "IN2": G("AP_SPI_CS_N"), "IN3": G("AP_SPI_MOSI"), "OUT4": G("AP_SPI_MISO"),
                "VDDB": G("v18"), "GNDB": GND, "GNDBB": GND, "ENB": G("v18"),
                "OUT1": G("SPI_SCLK"), "OUT2": G("SPI_CS_N"), "OUT3": G("SPI_MOSI"), "IN4": G("SPI_MISO")}, **k)
    # U502: side A (left, pins 1-8) is the FPGA side here - the three forward channels carry the I2S clocks + IRQ to the AP
    k, v = cp_("isoF")
    ctrl.place(LIB("MAX22445"), "U502", v, 130, 110,
               {"VDDA": G("v18"), "GNDA": GND, "GNDAB": GND, "ENA": G("v18"),
                "IN1": G("I2S_BCLK"), "IN2": G("I2S_LRCLK"), "IN3": G("FPGA_IRQ_N"), "OUT4": G("I2S_DATA"),
                "VDDB": G("VAP_IO"), "GNDB": G("GND_AP"), "GNDBB": G("GND_AP"), "ENB": G("VAP_IO"),
                "OUT1": G("AP_I2S_BCLK"), "OUT2": G("AP_I2S_LRCLK"), "OUT3": G("AP_IRQ_N"), "IN4": G("AP_I2S_DATA")}, **k)
    k, v = cp_("iso1")
    ctrl.place(LIB("MAX22444"), "U503", v, 130, 145,
               {"VDDA": G("VAP_IO"), "GNDA": G("GND_AP"), "GNDAB": G("GND_AP"), "IC": G("GND_AP"),
                "IN1": G("AP_RST_N"), "IN2": G("GND_AP"), "IN3": G("GND_AP"), "IN4": G("GND_AP"),
                "VDDB": G("v18"), "GNDB": GND, "GNDBB": GND, "ENB": G("v18"),
                "OUT1": G("EXT_RST_N"), "OUT2": ("NC", ""), "OUT3": ("NC", ""), "OUT4": ("NC", "")}, **k)
    k, v = cp_("isoi2c")
    ctrl.place(LIB("ISO1640"), "U504", v, 130, 175,
               {"VCC1": G("V33D"), "GND1": GND, "SDA1": G("SENS_SDA"), "SCL1": G("SENS_SCL"),
                "VCC2": G("VAP_IO"), "GND2": G("GND_AP"), "SDA2": G("AP_SDA"), "SCL2": G("AP_SCL")}, **k)
    k, v = cp_("rpu2k2")
    ctrl.place("Device:R", "R502", v, 95, 200, {"1": G("VAP_IO"), "2": G("AP_SDA")}, **k)
    ctrl.place("Device:R", "R503", v, 110, 200, {"1": G("VAP_IO"), "2": G("AP_SCL")}, **k)
    ctrl.place("Device:R", "R504", v, 150, 200, {"1": G("V33D"), "2": G("SENS_SDA")}, **k)
    ctrl.place("Device:R", "R505", v, 165, 200, {"1": G("V33D"), "2": G("SENS_SCL")}, **k)
    # decoupling: one 100n per isolator supply pin (side 1 to GND_AP, side 2 to GND)
    k, v = cp_("c100n")
    for i, y in enumerate((70, 110, 145, 175)):
        ctrl.place("Device:C", "C50%d" % (1 + 2 * i), v, 75, y, {"1": G("VAP_IO"), "2": G("GND_AP")}, **k)
        ctrl.place("Device:C", "C50%d" % (2 + 2 * i), v, 190, y, {"1": G("V33D" if y == 175 else "v18"), "2": GND}, **k)
    # temperature sensors on the isolated bus: ADD0 strap = address
    k, v = cp_("tmp")
    kc, vc = cp_("c100n")
    for i, add in enumerate((GND, G("V33D"), G("SENS_SDA"), G("SENS_SCL"))):
        x0 = 230 + 45 * i
        ctrl.place(LIB("TMP117"), "U50%d" % (5 + i), v, x0, 175,
                   {"V+": G("V33D"), "GND": GND, "SCL": G("SENS_SCL"), "SDA": G("SENS_SDA"), "ADD0": add, "ALERT": ("NC", "")}, **k)
        ctrl.place("Device:C", "C5%02d" % (9 + i), vc, x0 - 15, 190, {"1": G("V33D"), "2": GND}, **kc)
    # LEDs: 1.8 V IO -> 4.7k -> MMBT3904 -> LED -> 470 -> V33D; LED_DBG[3:0] = clk_locked / ddr4_calib / i2s_err / force_zero, plus SOM_PG
    ctrl.text("LEDs: led_debug[3:0] (xdc s10: 3 clk_locked, 2 ddr4_calib, 1 i2s_err, 0 force_zero) + SOM_PG; MMBT3904 sink from the 1.8 V IO. led_status (BC33) is on the module.", 230, 60)
    kq, vq = cp_("npn"); kd, vd = cp_("led"); kr, vr = cp_("rled"); kb, vb = cp_("rbase")
    for i, src in enumerate(("LED_DBG0", "LED_DBG1", "LED_DBG2", "LED_DBG3", "SOM_PG")):
        x0 = 240 + 30 * i
        ctrl.place("Device:R", "R51%d" % i, vb, x0 - 12, 95, {"1": G(src), "2": ("L", "QB%d" % i)}, **kb)
        ctrl.place("Transistor_BJT:MMBT3904", "Q50%d" % (1 + i), vq, x0, 95, {"B": ("L", "QB%d" % i), "E": GND, "C": ("L", "LK%d" % i)}, **kq)
        ctrl.place("Device:LED", "D50%d" % (1 + i), vd, x0, 80, {"K": ("L", "LK%d" % i), "A": ("L", "LA%d" % i)}, **kd)
        ctrl.place("Device:R", "R52%d" % i, vr, x0, 68, {"1": G("V33D"), "2": ("L", "LA%d" % i)}, **kr)
    ctrl.text("RLY_LINE_MUTE (J1 R28) terminates on the OUT sheet (bom 7): U602 AND gate with FPGA_DONE and PG_ALL -> UNMUTE_EN -> U601 ULN2003V12 inputs AND U603 TPS7A2033 EN (V33RLY coil rail). relay_level[1:0] struck (digital level).", 230, 130)

    # ---------------- V33D board rail + dual UCD90120A rail telemetry (bom 17(m2)/(m3); two devices with
    # distinct resistor-strapped PMBus addresses, user ruling 2026-10-12).  TELEMETRY ONLY: the UCDs are not
    # in the mute path - PG_ALL (POWER sheet) is the hardware rail-good.  The AP pushes each device's rail
    # table over this same sensor bus at boot (Fusion export -> PMBus write list -> STORE_DEFAULT_ALL).
    ctrl.text("V33D = U512 TPS7A2033 from V4P3 (always on): TMP117 x4 + ISO1640 side 1 + UCD90120A x2 + LEDs, ~120 mA.", 20, 235)
    k, v = pw_("ldo33d")
    ctrl.place("Regulator_Linear:TPS7A20xxxDBV", "U512", v, 60, 250,
               {"IN": G("v4p3"), "GND": GND, "EN": G("v4p3"), "NC": ("NC", ""), "OUT": G("v33d")}, **k)
    k, v = pw_("c1u")
    ctrl.place("Device:C", "C518", v, 38, 262, {"1": G("v4p3"), "2": GND}, **k)
    ctrl.place("Device:C", "C519", v, 82, 262, {"1": G("v33d"), "2": GND}, **k)
    ctrl.text("RAIL TELEMETRY (bom 17(m2)/(m3)): U510 (UCD_L) watches the L-channel POL rails + V33CLK/V33FF/V33RLY + the four pre-regs;"
              " U511 (UCD_R) watches the R-channel rails + V33D/V18/V12SOM + the same four pre-regs (cross-check). 26 of 26 MON inputs used -"
              " every rail on the board. MON window 0-2.5 V: positive rails divided to GND (100k/10k for 12-16.5 V, 49.9k/10k for 7-9 V, 20k/20k for"
              " 3.3-4.3 V and V18); NEGATIVE rails (N15A/VEE15/N16A) via 100k to rail + 10k pull-UP to V33D -> Vmon = 1.50-1.64 V at the -15/-16.2 V"
              " setpoints, monotone to 0 V, with a BAT54 clamp so a live negative rail cannot drag MON below ~-0.35 V while V33D is down."
              " Bus = SENS_SDA/SENS_SCL behind U504 ISO1640 with the TMP117s (400 kHz, 2.2 k pull-ups unchanged). Alerts = AP polling"
              " (SMBALERT# not routed; PMBALERT pulled up and left unread).  PMBUS_CNTRL -> GND.", 20, 275)
    ctrl.text("ADDRESSES (resistor straps on PMBUS_ADDR0/1, analog pins per SLVSAN9C): UCD_L 10k/10k to GND, UCD_R 10k/20k - DISTINCT, and both"
              " strapped away from the 126/JTAG default.  ** VERIFY chosen values against the TI address-detection table and record the resulting"
              " PMBus addresses here **.  Straps: RESET = 10k pull-up + 1 nF; TRST 10k to GND; TDI/TMS/TRCK/PMBALERT 10k straps; BPCAP 100 nF."
              " V33FB -> V33D (3.3 V feedback sense) ** VERIFY V33FB/CNTRL/TRCK strapping **. J505 = DNP bring-up header (3V3/SCL/SDA/GND).", 20, 290)
    MONC = {"100k": "1003", "10k": "1002", "49.9k": "4992", "20k": "2002"}
    ucd_mons = {
        "U510": [("v_roff_l", "100k", "10k", 0), ("p15a_l", "100k", "10k", 0), ("ve1_l", "49.9k", "10k", 0),
                  ("p5a_l", "20k", "20k", 0), ("v33clk", "20k", "20k", 0), ("v33ff", "20k", "20k", 0),
                  ("n15a_l", "100k", "10k", 1), ("vee15_l", "100k", "10k", 1), ("v33rly", "20k", "20k", 0),
                  ("p16a", "100k", "10k", 0), ("n16a", "100k", "10k", 1), ("v8p3", "49.9k", "10k", 0),
                  ("v4p3", "20k", "20k", 0)],
        "U511": [("v_roff_r", "100k", "10k", 0), ("p15a_r", "100k", "10k", 0), ("ve1_r", "49.9k", "10k", 0),
                  ("p5a_r", "20k", "20k", 0), ("v33d", "20k", "20k", 0), ("v18", "20k", "20k", 0),
                  ("n15a_r", "100k", "10k", 1), ("vee15_r", "100k", "10k", 1), ("v12som", "100k", "10k", 0),
                  ("p16a", "100k", "10k", 0), ("n16a", "100k", "10k", 1), ("v8p3", "49.9k", "10k", 0),
                  ("v4p3", "20k", "20k", 0)]}
    for ui, uref in enumerate(("U510", "U511")):
        sfx = "LR"[ui]
        ux, uy = (300, 330) if ui == 0 else (620, 330)
        rb, cb, db = 526 + 34 * ui, 520 + 100 * ui, 510 + 100 * ui
        nets = {"PMBUS_CLK": G("sens_scl"), "PMBUS_DATA": G("sens_sda"), "PMBALERT": ("L", "ALRT_%s" % sfx),
                "PMBUS_CNTRL": GND, "PMBUS_ADDR0": ("L", "ADR0_%s" % sfx), "PMBUS_ADDR1": ("L", "ADR1_%s" % sfx),
                "V33DIO1": G("v33d"), "V33DIO2": G("v33d"), "V33D": G("v33d"), "V33A": G("v33d"),
                "V33FB": G("v33d"), "BPCAP": ("L", "BPC_%s" % sfx), "RESET": ("L", "URST_%s" % sfx),
                "TRCK": ("L", "TRCK_%s" % sfx), "TRST": ("L", "TRST_%s" % sfx),
                "TDI": ("L", "JTDI_%s" % sfx), "TMS": ("L", "JTMS_%s" % sfx),
                "AVSS1": GND, "AVSS2": GND, "AVSS3": GND, "DVSS1": GND, "DVSS2": GND, "DVSS3": GND, "EP": GND}
        for i in range(13):
            nets["MON%d" % (i + 1)] = ("L", "MON_%s%d" % (sfx, i + 1))
        k, v = pw_("ucd")
        ctrl.place(LIB("UCD90120A"), uref, v, ux, uy, nets, **k)
        ctrl.place(LIB("UCD90120A"), uref, v, ux + 95, uy, {}, unit=2, **k)   # unit 2: unused GPIO/PWM/NC bank (all no_connect)
        # supply decoupling + BPCAP + straps (>= 15 mm vertical pitch everywhere on this column:
        # a vertical passive's stubs reach 6.35 mm past its pins, so tighter stacking shorts adjacent nodes)
        k, v = pw_("cbpcap")
        for j in range(4):
            ctrl.place("Device:C", "C%d" % (cb + 40 + j), v, ux + 52, 250 + 15 * j, {"1": G("v33d"), "2": GND}, **k)
        ctrl.place("Device:C", "C%d" % (cb + 44), v, ux + 52, 315, {"1": ("L", "BPC_%s" % sfx), "2": GND}, **k)
        k10, v10 = pw_("rrst")
        ctrl.place("Device:R", "R%d" % (rb + 26), v10, ux + 40, 290, {"1": G("v33d"), "2": ("L", "URST_%s" % sfx)}, **k10)   # RESET pull-up
        k, v = pw_("cpgfb")
        ctrl.place("Device:C", "C%d" % (cb + 45), v, ux + 67, 290, {"1": ("L", "URST_%s" % sfx), "2": GND}, **k)             # RESET 1 nF
        ctrl.place("Device:R", "R%d" % (rb + 27), v10, ux + 40, 305, {"1": ("L", "TRST_%s" % sfx), "2": GND}, **k10)         # TRST pull-down
        ctrl.place("Device:R", "R%d" % (rb + 28), v10, ux + 40, 320, {"1": ("L", "TRCK_%s" % sfx), "2": GND}, **k10)         # TRCK pull-down
        ctrl.place("Device:R", "R%d" % (rb + 29), v10, ux + 40, 335, {"1": G("v33d"), "2": ("L", "JTDI_%s" % sfx)}, **k10)   # TDI pull-up
        ctrl.place("Device:R", "R%d" % (rb + 30), v10, ux + 40, 350, {"1": G("v33d"), "2": ("L", "JTMS_%s" % sfx)}, **k10)   # TMS pull-up
        ctrl.place("Device:R", "R%d" % (rb + 31), v10, ux + 40, 365, {"1": G("v33d"), "2": ("L", "ALRT_%s" % sfx)}, **k10)   # PMBALERT pull-up (unread)
        # address straps: resistor to GND per pin (analog detection); L = 10k/10k, R = 10k/20k -> distinct addresses
        a0v, a1v = ("10k", "10k") if ui == 0 else ("10k", "20k")
        k, v = pw_("raddr", a0v, MONC[a0v]); ctrl.place("Device:R", "R%d" % (rb + 32), v, ux + 40, 380, {"1": ("L", "ADR0_%s" % sfx), "2": GND}, **k)
        k, v = pw_("raddr", a1v, MONC[a1v]); ctrl.place("Device:R", "R%d" % (rb + 33), v, ux + 52, 380, {"1": ("L", "ADR1_%s" % sfx), "2": GND}, **k)
        # MON divider networks: pos = rail-Ra-node-Rb-GND; neg = rail-Ra-node + node-Rb-V33D + BAT54 clamp
        for mi, (rail, ra, rbl, neg) in enumerate(ucd_mons[uref]):
            node = ("L", "MON_%s%d" % (sfx, mi + 1))
            y = 390 + 14 * mi
            xa = ux - 90
            k, v = pw_("rmon", ra, MONC[ra])
            ctrl.place("Device:R", "R%d" % (rb + 2 * mi), v, xa, y, {"1": G(rail), "2": node}, **k)
            k, v = pw_("rmon", rbl, MONC[rbl])
            ctrl.place("Device:R", "R%d" % (rb + 2 * mi + 1), v, xa + 14, y, {"1": node, "2": G("v33d") if neg else GND}, **k)
            k, v = pw_("cpgfb")
            ctrl.place("Device:C", "C%d" % (cb + mi), v, xa + 28, y, {"1": node, "2": GND}, **k)
            if neg:
                k, v = pw_("bat54")
                ctrl.place("Device:D_Schottky", "D%d" % (db + mi), v, xa + 40, y, {"K": node, "A": GND}, **k)
            ctrl.text("MON%d <- %s" % (mi + 1, rail.upper()), xa - 30, y + 2, 1.0)
    # DNP PMBus service header on the sensor bus (USB-TO-GPIO2 4-wire subset; bring-up / Fusion tuning only)
    k, v = pw_("hdr4")
    ctrl.place("Connector_Generic:Conn_01x04", "J505", v, 60, 300,
               {"Pin_1": G("v33d"), "Pin_2": G("sens_scl"), "Pin_3": G("sens_sda"), "Pin_4": GND}, dnp=True, **k)

    # --- CTRL test points (rule c): control-plane handshakes on hook pads in the free x>730 strip - SPI / sensor
    # I2C / reset / IRQ / debug LEDs / I2S clocks, plus V33D / V12SOM.  GND pads at the bottom (rule d).
    ctrl.text("TEST POINTS (rule c): SPI / SENS / RST / IRQ / LED / I2S handshakes on hook pads; GND at the bottom.", 700, 24)
    for i, net in enumerate(["v33d", "v12som", "sens_scl", "sens_sda", "spi_sclk", "spi_cs_n", "spi_mosi",
                             "spi_miso", "ext_rst_n", "fpga_irq_n", "led_dbg0", "i2s_bclk", "i2s_data"]):
        tp(ctrl, "TP%d" % (510 + i), 770, 40 + 26 * i, G(net))
    tp(ctrl, "TP523", 770, 40 + 26 * 13, GND)
    tp(ctrl, "TP524", 770, 40 + 26 * 14, GND)

    # ---------------- output-routing sheet (bom 7, RULED 2026-10-07): K4 mute only; level select is digital (K1/K2 struck)
    def op_(key):
        v, fp, mpn, ds = OUT_PARTS[key]
        return dict(footprint=fp, mpn=mpn, descr=ds), v
    out.text("OUTPUT ROUTING (bom 7, user rulings 2026-10-07): electromechanical relays, no MEMS (ADGM3144 rejected: +-10 V stand-off vs 48 V phantom, 150 V HBM at the XLR, open-only = cannot ground the muted output)."
             " Level select 2/4/6 Vrms is DIGITAL (LEVEL register caps VOLUME; SNR 132.8 / 129.3 / 123.3 dB0 sim) - K1/K2 and the R0 tap string are struck: with the V-stage gone (ruling 2) an analog"
             " tap would be a load-dependent divider (-1.7 dB at 600 R) or a switched R_f that moves the 0 V output DC and adds up to +3.1 W held. Build-out 10 R per leg outside the loop (default, revisit).", 20, 17)
    out.text("K4 = Omron G6K-2F-Y DC3 (2 Form C, single-side stable, 3 V / 33 mA / 100 mW held per channel; DC12 -> DC3 2026-10-10, 12 V is SoM-only): COM = XLR pin, NO = I/V output via 10 R, NC = GND. Coil OFF = XLR grounded and amp disconnected -"
             " muted with no power, no FPGA, no pulse; the I/V output sits at 0 V DC (R_off null) so unmute is thump-free. Unmute requires RLY_LINE_MUTE (GPIO) AND FPGA_DONE (J2 A1 VUP_SELECTMAP_DONE,"
             " 1.8 V bank 0) AND PG_ALL (wired-AND power-good: every LDO PG + TPS3890, pull-up to V18 on the POWER sheet - bom 17(m)). U602 SN74LVC1G11 at V18 (1.65-5.5 V part)"
             " -> U601 ULN2003V12 (1.8 V inputs, flyback COM = V33RLY; one package serves both channels, inputs 3-7 grounded). Coils on V33RLY = U603 TPS7A2033 from the 4.3 V pre-reg, EN = UNMUTE_EN:"
             " the coil rail does not exist until DONE AND PG_ALL AND GPIO (second mute path, survives a shorted U601 output) and its 33 mA steps / flyback never touch V33D (bom 7, 17(e)).", 20, 24)
    out.text("XLR J601/J602 = Neutrik NC3MD-H-B (LOCKED 2026-10-10: D-size black metal shell, gold, horizontal PCB; footprint bfdac:Neutrik_NC3MD-H from the Neutrik drawing - flange reaches 3 mm below the board, board edge >= 20.2 mm in front of the pin row)"
             " Pin 1 = shield, G = shell (both GND here; chassis-vs-signal ground split is a layout/grounding-plan decision - the metal shell bonds to the chassis through the panel screws), 2 = hot (OUT_P), 3 = cold (OUT_M)."
             " G6K-2 pin roles (coil 1(+)/8, COM 3/6, NC 2/7, NO 4/5) read from the KiCad Relay:G6K-2 symbol graphics and matched by the user's GN-relay reading; footprint Relay_SMD:Relay_DPDT_Omron_G6K-2F-Y. 70 C ambient limit: place at the rear-panel edge, away from the I/V heat zone.", 20, 31)
    kk, vk = op_("k4"); kr, vr = op_("rbo"); kx, vx = op_("xlr")
    for i, ch in enumerate(("L", "R")):
        y = 70 + 70 * i
        out.text("%s channel" % ch, 30, y - 12)
        out.place("Device:R", "R%d" % (670 + 2 * i), vr, 50, y - 5, {"1": G("OUT_P_%s" % ch), "2": ("L", "OBP_%s" % ch)}, **kr)
        out.place("Device:R", "R%d" % (671 + 2 * i), vr, 50, y + 10, {"1": G("OUT_M_%s" % ch), "2": ("L", "OBM_%s" % ch)}, **kr)
        out.place("Relay:G6K-2", "K60%d" % (1 + i), vk, 100, y,
                  {"1": G("v33rly"), "8": ("L", "KC_%s" % ch),
                   "3": ("L", "XLR_HOT_%s" % ch), "4": ("L", "OBP_%s" % ch), "2": GND,
                   "6": ("L", "XLR_COLD_%s" % ch), "5": ("L", "OBM_%s" % ch), "7": GND}, **kk)
        out.place("Connector_Audio:XLR3_Ground", "J60%d" % (1 + i), vx, 160, y,
                  {"1": GND, "2": ("L", "XLR_HOT_%s" % ch), "3": ("L", "XLR_COLD_%s" % ch), "G": GND}, **kx)
    # unmute gate + coil driver (shared by both channels)
    k, v = op_("and3")
    out.place("74xGxx:74LVC1G11", "U602", v, 60, 230, {"1": G("RLY_LINE_MUTE"), "3": G("FPGA_DONE"), "6": G("PG_ALL"), "4": ("L", "UNMUTE_EN"), "VCC": G("v18"), "GND": GND}, **k)
    k, v = op_("c100n"); out.place("Device:C", "C601", v, 85, 245, {"1": G("v18"), "2": GND}, **k)
    k, v = op_("uln")
    out.place("Transistor_Array:ULN2003A", "U601", v, 130, 230,
              {"I1": ("L", "UNMUTE_EN"), "I2": ("L", "UNMUTE_EN"), "I3": GND, "I4": GND, "I5": GND, "I6": GND, "I7": GND,
               "GND": GND, "COM": G("v33rly"), "O1": ("L", "KC_L"), "O2": ("L", "KC_R"),
               "O3": ("NC", ""), "O4": ("NC", ""), "O5": ("NC", ""), "O6": ("NC", ""), "O7": ("NC", "")}, **k)
    # dedicated relay-coil LDO: V4P3 -> 3.3 V V33RLY, enabled by the same UNMUTE_EN that drives U601
    k, v = op_("ldorly")
    out.place("Regulator_Linear:TPS7A20xxxDBV", "U603", v, 200, 230,
              {"IN": G("v4p3"), "GND": GND, "EN": ("L", "UNMUTE_EN"), "NC": ("NC", ""), "OUT": G("v33rly")}, **k)
    k, v = op_("c1u")
    out.place("Device:C", "C602", v, 180, 245, {"1": G("v4p3"), "2": GND}, **k)
    out.place("Device:C", "C603", v, 220, 245, {"1": G("v33rly"), "2": GND}, **k)
    out.text("PG_ALL: open-drain wired-AND rail power-good (13 x LDO PG + TPS3890 on V33FF, 10k pull-up to V18 on the POWER sheet) - high = every rail in"
             " regulation. Hardware path, firmware-independent: the UCD90120A telemetry parts are NOT in this chain (bom 17(m)/(m2)).", 20, 265)

    # --- OUT test points: unmute-chain handshakes on hook pads; OUT_P/M (the analog output at the relay
    # contact) on 1.0 mm SMD pads (rule a - low-Z driven node, shortest stub); GND pads below.
    out.text("TEST POINTS (rules a/c/d): unmute chain on hook pads, OUT_P/M analog outputs on 1.0 mm pads, GND below.", 250, 24)
    for i, (net, kind) in enumerate((("v33rly", "tht"), ("v4p3", "tht"), ("rly_line_mute", "tht"),
                                     ("fpga_done", "tht"), ("pg_all", "tht"),
                                     ("out_p_l", "pad"), ("out_m_l", "pad"), ("out_p_r", "pad"), ("out_m_r", "pad"))):
        tp(out, "TP60%d" % i, 275, 40 + 24 * i, G(net), kind=kind)
    tp(out, "TP609", 275, 40 + 24 * 9, ("L", "UNMUTE_EN"))
    tp(out, "TP610", 275, 40 + 24 * 10, GND)
    tp(out, "TP611", 315, 40 + 24 * 10, GND)

    # ---------------- level-translator sheet (bom 1.2 U440-U455): 8 octal AXC8T245 per channel, cells 8g+1..8g+8 on device g
    xlat.text("SN74AXC8T245 x16 (bom 1.2, VQFN RHL ruled 2026-10-10): FPGA LVCMOS18 data from J6 (DATnn_1V8 = cascode_l) and J5/J6 (DATRnn_1V8 = cascode_r) -> 3.3 V DATnn / DATRnn"
              " -> the 128 CELL sheets (LVC1G74 D). DIR1/DIR2 tied to VCCA (A->B), /OE to GND, PAD to GND. A side on V18 (SoM VCCIO, not generated here), B side on V33FF (ADP7158, power sheet)."
              " Layout (bom 1.2): place at the SoM connectors on the FPGA side; FPGA pin -> A input +-2.5 mm within a group and across all 16; B output -> LVC1G74 D per the cell-array rule.", 20, 17)
    kx, vx = fp_("axc8")
    kca, vca = fp_("cxa")
    kcb, vcb = fp_("cxb")
    kfb, vfb = fp_("fbx")
    for gi, (dat, u0) in enumerate((("DAT", 440), ("DATR", 448))):
        xlat.text("%s channel: %snn_1V8 -> %snn, U%d..U%d" % ("LR"[gi], dat, dat, u0, u0 + 7), 20 + gi * 290, 28)
        for g in range(8):
            x, y = 60 + gi * 290 + (g % 2) * 140, 60 + (g // 2) * 95
            vxb = "VXB%d" % (u0 + g)
            nets = {"VCCA": G("v18"), "DIR1": G("v18"), "DIR2": G("v18"), "VCCB": ("L", vxb), "~{OE}": GND, "GND": GND, "PAD": GND}
            for i in range(1, 9):
                nets["A%d" % i] = G("%s%02d_1V8" % (dat, 8 * g + i))
                nets["B%d" % i] = G("%s%02d" % (dat, 8 * g + i))
            xlat.place(LIB("SN74AXC8T245"), "U%d" % (u0 + g), vx, x, y, nets, **kx)
            xlat.place("Device:C", "C%d" % (u0 + g), vca, x - 40, y + 20, {"1": G("v18"), "2": GND}, **kca)
            xlat.place("Device:FerriteBead", "FB%d" % (u0 + g), vfb, x + 40, y - 20, {"1": G("v33ff"), "2": ("L", vxb)}, **kfb)
            xlat.place("Device:C", "C%d" % (u0 + g + 20), vcb, x + 40, y + 20, {"1": ("L", vxb), "2": GND}, **kcb)
            fx, fy = snap(x + 55), snap(y - 30)
            xlat.power("power:PWR_FLAG", "PWR_FLAG", fx, fy, "#FLG")
            xlat.wire(fx, fy, fx, fy + 2.54)
            xlat.label(vxb, fx, fy + 2.54, 0, "L")

    # --- V33FF POL LDO on the XLAT sheet (dual-mono 17(m3): the LDO lives with its heaviest load - the 16
    # translator B-sides + per-cell FF islands via FB).  ADP7158ACPZ-3.3 (2 A, 1.7 nV/rtHz) from V4P3;
    # fixed part: VREG+EN to IN (autostart), REF_SENSE->REF, BYP/REF/VREG 1 uF each, IN/OUT 10 uF, EP = GND.
    # No PG pin on the ADP7158 -> the rail is covered by TPS3890 U1701 on the POWER sheet (bom 17(m)).
    xlat.text("V33FF LDO (U460): ADP7158ACPZ-3.3 from V4P3, ~1 A worst case into the B-side islands + FF arrays (bom 1.2/17(l))."
              " REF_SENSE->REF (fixed-output config); BYP/REF/VREG 1 uF; EP->GND. Rail-good = TPS3890 on the POWER sheet.", 20, 395)
    k, v = pw_("adp7158")
    xlat.place(LIB("ADP7158"), "U460", v, 120, 425,
               {"VIN": G("v4p3"), "VREG": G("v4p3"), "EN": G("v4p3"), "BYP": ("L", "BYP_U460"),
                "REF": ("L", "REF_U460"), "REF_SENSE": ("L", "REF_U460"), "VOUT": G("v33ff"),
                "VOUT_SENSE": G("v33ff"), "EP": GND}, **k)
    k, v = pw_("c1u")
    xlat.place("Device:C", "C480", v, 95, 435, {"1": ("L", "BYP_U460"), "2": GND}, **k)
    xlat.place("Device:C", "C481", v, 95, 445, {"1": ("L", "REF_U460"), "2": GND}, **k)
    xlat.place("Device:C", "C482", v, 105, 445, {"1": G("v4p3"), "2": GND}, **k)   # VREG bypass
    k, v = pw_("cldo10")
    xlat.place("Device:C", "C483", v, 140, 435, {"1": G("v4p3"), "2": GND}, **k)   # VIN 10u
    xlat.place("Device:C", "C484", v, 155, 435, {"1": G("v33ff"), "2": GND}, **k)  # VOUT 10u

    # --- XLAT test points: representative cell-drive lines (3.3 V B-side, post-translator) through 1k
    # isolation stubs (rule b); rails on hook pads.  Column in the free x>550 strip.
    xlat.text("TEST POINTS (rule b): DAT/DATR cell-drive lines through 1k -> 1.0 mm pad; rails + GND on hook pads.", 545, 40)
    tp(xlat, "TP460", 575, 60, G("v33ff"))
    tp(xlat, "TP461", 575, 84, G("v18"))
    tp(xlat, "TP462", 575, 108, G("v4p3"))
    for i, (net, rref) in enumerate((("dat01", "R470"), ("dat32", "R471"), ("dat64", "R472"),
                                     ("datr01", "R473"), ("datr32", "R474"), ("datr64", "R475"))):
        tp_stub(xlat, "TP46%d" % (3 + i), rref, 560, 132 + 24 * i, G(net), "TP_" + net.upper(), pw_)
    tp(xlat, "TP469", 575, 132 + 24 * 6, GND)
    tp(xlat, "TP470", 575, 132 + 24 * 7, GND)

    # ---------------- POWER sheet (2026-10-12): pre-reg harness entry + rail supervisors + PG_ALL only.
    # User ruling: POL LDOs live on the sheets they feed - nothing here consumes a POL rail.
    power.text("PRE-REG ENTRY (bom 17(d)/(l), option B 2026-10-12: SHARED pre-reg rails + per-channel POL LDOs):"
               " four rails from the power tube enter on TWO edge connectors - J603 top edge feeds the L-channel POL cluster + clock LDOs,"
               " J604 bottom edge feeds the R-channel cluster + the shared digital LDOs. The tube Y-fans-out each rail so each channel's"
               " harness leg carries its own (channel-correlated) current; on-board the two entries are the same nets. P16A (+16.2 V -> +15 V-class POLs),"
               " N16A (-16.2 V -> N15A/VEE15), V8P3 (+8.3 V -> VE1), V4P3 (+4.3 V -> every 3.3 V-class POL: P5A/V33CLK/V33FF/V33D/V33RLY).", 20, 17)
    k, v = pw_("pwrc")
    power.place("Connector_Generic:Conn_02x04_Odd_Even", "J603", v, 60, 70,
                {"Pin_1": G("p16a"), "Pin_2": GND, "Pin_3": G("n16a"), "Pin_4": GND,
                 "Pin_5": G("v8p3"), "Pin_6": GND, "Pin_7": G("v4p3"), "Pin_8": GND}, **k)
    power.place("Connector_Generic:Conn_02x04_Odd_Even", "J604", v, 160, 70,
                {"Pin_1": G("p16a"), "Pin_2": GND, "Pin_3": G("n16a"), "Pin_4": GND,
                 "Pin_5": G("v8p3"), "Pin_6": GND, "Pin_7": G("v4p3"), "Pin_8": GND}, **k)
    power.text("J603 = top edge (L side), J604 = bottom edge (R side); 0.100-inch stacker headers (Samtec TW/ESQT class) for the ~30 mm"
               " board-to-board stack to the power-tube board - ~3 A/pin vs <= 0.5 A/rail. Each rail sits beside its own GND return; 10 uF"
               " local bulk per rail per connector - the heavy bulk/filtering lives in the tube. PWR_FLAGs are in the rails table on REFS_L.", 20, 118)
    k, v = pw_("cldo10")
    for i, rail in enumerate(("p16a", "n16a", "v8p3", "v4p3")):
        power.place("Device:C", "C17%d" % (0 + i), v, 100 + 12 * i, 95, {"1": G(rail), "2": GND}, **k)
        power.place("Device:C", "C172%d" % i, v, 200 + 12 * i, 95, {"1": G(rail), "2": GND}, **k)
    power.text("PG_ALL = wired-AND of every POL power-good, HARDWARE ONLY (bom 17(m)): 8 x LT3045 + 4 x LT3094 + V33CLK LT3045 PG pins"
               " (open-collector) + U1701 TPS3890 RESET; pull-up R1701 10k to V18 (SoM rail - sets the 1.8 V logic level for U602 and the FPGA IO)."
               " High = all analog + clock rails in regulation -> OUT sheet U602 unmute gate (with RLY_LINE_MUTE + FPGA_DONE) and FPGA J1-B7/N29 (PG_ALL)"
               " for the soak/unmute sequencer. The UCD90120A monitors on CTRL are TELEMETRY ONLY - a blank UCD cannot unmute or hold the output.", 20, 150)
    # no PWR_FLAG on PG_ALL: it is an open-collector wired-AND, not a power rail - a flag (power_out)
    # would be an ERC pin_to_pin error against the 14 LDO PG pins.  R1701 is the (passive) pull-up.
    k, v = pw_("rrst")
    power.place("Device:R", "R1701", v, 60, 190, {"1": G("v18"), "2": G("pg_all")}, **k)
    # TPS389001 supervisor on V33FF (the one POL rail with no PG pin - ADP7158).  Adjustable variant:
    # VITN 1.15 V on SENSE -> 162k/100k divider trips at ~3.01 V (~91 % of 3.3 V).  VDD = V4P3 pre-reg so the
    # supervisor stays alive through a V33FF collapse; MR->VDD (no manual reset), CT open (min ~25 us).
    k, v = pw_("tps3890")
    power.place(LIB("TPS3890"), "U1701", v, 160, 195,
                {"VDD": G("v4p3"), "GND": GND, "MR": G("v4p3"), "CT": ("NC", ""),
                 "SENSE": ("L", "SNS_V33FF"), "RESET": G("pg_all")}, **k)
    k, v = pw_("rmon", "162k", "1623")
    power.place("Device:R", "R1702", v, 135, 185, {"1": G("v33ff"), "2": ("L", "SNS_V33FF")}, **k)
    k, v = pw_("rmon", "100k", "1003")
    power.place("Device:R", "R1703", v, 135, 200, {"1": ("L", "SNS_V33FF"), "2": GND}, **k)
    k, v = pw_("cpgfb")
    power.place("Device:C", "C1710", v, 148, 195, {"1": ("L", "SNS_V33FF"), "2": GND}, **k)
    k, v = pw_("cbpcap")
    power.place("Device:C", "C1711", v, 190, 210, {"1": G("v4p3"), "2": GND}, **k)
    power.text("U1701 TPS389001: SENSE divider 162k/100k = 3.01 V trip on V33FF (VITN 1.15 V, SBVS227 - the 400 mV"
               " figure in the 17(m) notes was wrong). RESET joins the PG_ALL wired-AND.", 130, 215)

    # --- POWER test points (rule c/d): the four pre-reg rails + PG_ALL + the V33FF sense node + V18 on hook
    # pads; two GND pads for short-spring probe grounds.
    power.text("TEST POINTS (rules c/d): pre-reg rails / PG_ALL / SNS_V33FF on hook pads; GND at the end.", 40, 232)
    for i, net in enumerate(["p16a", "n16a", "v8p3", "v4p3", "v18", "pg_all"]):
        tp(power, "TP17%02d" % i, 40 + 32 * i, 255, G(net))
    tp(power, "TP1706", 40 + 32 * 6, 255, ("L", "SNS_V33FF"))
    tp(power, "TP1707", 40 + 32 * 7, 255, GND)
    tp(power, "TP1708", 40 + 32 * 8, 255, GND)

    bringup.text("MANUAL TESTS: SW9000 SELECT = 1/2/3 presses in a fixed 3-second window; SW9001 STEP holds each condition until pressed."
                 " D9023 flashes 1/2/3 Hz while CELL / DC / 1-20kHz is active. Extra STEP after final R condition completes; SELECT hold 2s cancels."
                 " XLR stays muted. GPIOs use SoM V18; indicator current comes only from V12SOM, not analog rails.", 20, 18)
    bringup.text("Rail LEDs: rough presence only, nominal ~500uA using Vf~1.8V. No precision references or bias nodes loaded."
                 " Mount each indicator near its named supply/entry; GND_AP stays isolated. Series current resistor can be removed for diagnostic comparison."
                 " V18 indication is buffered from V12SOM because 1.8V cannot guarantee red-LED headroom; brightness is not a voltage limit check.", 20, 115)
    rfoot = FP["R0603"]
    led_kw = dict(footprint=FP["LED0603"], mpn="APT1608LSECK/J3-PRV",
                  descr="Kingbright low-current red 0603; nominal 500uA bring-up indicator (locked). Datasheet light output specified at 2mA; verify visibility at 500uA on first article.")
    for i, net in enumerate(("TEST_SELECT_N", "TEST_STEP_N")):
        x = 55 + 100 * i
        raw = ("L", "BUTTON%d" % i)
        bringup.place("Switch:SW_Push", "SW%d" % (9000 + i), "SELECT" if i == 0 else "STEP", x, 65,
                      {"1": raw, "2": GND}, footprint="Button_Switch_SMD:SW_Push_1P1T_NO_Vertical_Wuerth_434133025816", mpn="434133025816")
        k, v = pw_("rmon", "10k", "1002")
        bringup.place("Device:R", "R%d" % (9100 + 2 * i), v, x - 20, 45, {"1": G("V18"), "2": raw}, **k)
        k, v = pw_("rmon", "1k", "1001")
        bringup.place("Device:R", "R%d" % (9101 + 2 * i), v, x + 25, 65, {"1": raw, "2": G(net)}, **k)
    led_rails = [("P16A", "28.7k", "2872", False), ("N16A", "28.7k", "2872", True),
                 ("V8P3", "13k", "1302", False), ("V4P3", "4.99k", "4991", False),
                 ("V12SOM", "20.5k", "2052", False), ("V33CLK", "3.01k", "3011", False),
                 ("V33FF", "3.01k", "3011", False), ("V33D", "3.01k", "3011", False),
                 ("V_ROFF_L", "26.7k", "2672", False), ("P15A_L", "26.7k", "2672", False),
                 ("N15A_L", "26.7k", "2672", True), ("VEE15_L", "26.7k", "2672", True),
                 ("VE1_L", "10.7k", "1072", False), ("P5A_L", "3.01k", "3011", False),
                 ("V33RLY", "3.01k", "3011", False), ("VAP_IO", "3.01k", "3011", False),
                 ("V_ROFF_R", "26.7k", "2672", False), ("P15A_R", "26.7k", "2672", False),
                 ("N15A_R", "26.7k", "2672", True), ("VEE15_R", "26.7k", "2672", True),
                 ("VE1_R", "10.7k", "1072", False), ("P5A_R", "3.01k", "3011", False)]
    for i, (rail, value, code, negative) in enumerate(led_rails):
        x, y = 45 + (i % 8) * 65, 155 + (i // 8) * 75
        ret = G("GND_AP") if rail == "VAP_IO" else GND
        led_node = ("L", "LED_%s" % rail)
        k, v = pw_("rmon", value, code)
        bringup.place("Device:R", "R%d" % (9000 + i), v, x, y, {"1": G(rail), "2": led_node}, **k)
        bringup.place("Device:LED", "D%d" % (9000 + i), rail, x, y + 23,
                      {"A": ret if negative else led_node, "K": led_node if negative else ret}, **led_kw)
    for i, (source, title, x, y) in enumerate((("V18", "V18_PRESENT", 450, 65), ("TEST_LED", "TEST_ACTIVE", 325, 65))):
        base, cathode, anode = (("L", "%s_%s" % (title, n)) for n in ("B", "K", "A"))
        k, v = pw_("rmon", "10k", "1002")
        bringup.place("Device:R", "R%d" % (9110 + 3 * i), v, x - 25, y, {"1": G(source), "2": base}, **k)
        k, v = pw_("rmon", "1M", "1004")
        bringup.place("Device:R", "R%d" % (9111 + 3 * i), v, x - 25, y + 22, {"1": base, "2": GND}, **k)
        k, v = cp_("npn")
        bringup.place("Transistor_BJT:MMBT3904", "Q%d" % (9000 + i), v, x, y, {"B": base, "E": GND, "C": cathode}, **k)
        k, v = pw_("rmon", "20k", "2002")
        bringup.place("Device:R", "R%d" % (9112 + 3 * i), v, x + 25, y - 22, {"1": G("V12SOM"), "2": anode}, **k)
        bringup.place("Device:LED", "D%d" % (9022 + i), title, x, y - 22, {"A": anode, "K": cathode}, **led_kw)

    # ---------------- root
    root.text("BFDAC analog board, locked plant (bfdac_cosim112.cir, 2026-09-24). Two identical channels: 64 current cells each (LVC1G74 + "
              "DMMT5551 steering) + CORE + P5 TIA + REFS. L: DATnn (J6 -> XLAT sheet AXC8T245) / MCLKnn (FPGA sheet, U302 tree). R: DATRnn (J5/J6 -> XLAT) / MCLKRnn (CLKR sheet, U303 tree)."
              " Channel-local nets carry _L/_R; rails, REF5/REF5F and GND are shared. R designators = L + offset (cells 2xxx, refs 7xx, tails Q4xx, core/IV +60).", 20, 20)
    page = 2
    for ch, xoff, dat, mclk in (("L", 20, "DAT", "MCLK"), ("R", 440, "DATR", "MCLKR")):
        c = chan[ch]
        root.text("%s CHANNEL cells 01..64 (%s%s / %s%s)" % (ch, dat, "nn", mclk, "nn"), xoff, 28)
        for n in range(ncell):
            col, row = n % 8, n // 8
            x, y = xoff + col * 50, 32 + row * 30
            root.subsheet("CELL%s%02d" % (ch, n + 1), c["cell"].fname, x, y, 30, 15,
                          [("D", "L", 0, "G", "%s%02d" % (dat, n + 1)), ("CLK", "L", 1, "G", "%s%02d" % (mclk, n + 1))],
                          c["cell_uuids"][n], str(page)); page += 1
    for i, s in enumerate(subsheets):
        root.subsheet(getattr(s, "name", None) or s.title.split(":")[0].split(" - ")[0].upper(), s.fname, 20 + (i % 6) * 90, 290 + (i // 6) * 40, 60, 20, [], sub_uuid[s.fname], str(page)); page += 1

    for s in [root] + [chan[ch][k] for ch in ("L", "R") for k in ("cell", "core", "iv", "refs")] + [fpga, clkr, som, ctrl, out, xlat, power, bringup]:
        s.write(root=(s is root))
    with open(os.path.join(OUT, "%s.kicad_pro" % PROJECT), "w") as f:
        json.dump({"meta": {"filename": "%s.kicad_pro" % PROJECT, "version": 1},
                   "schematic": {"drawing": {"default_font": "KiCad Font"}}, "sheets": [], "text_variables": {}}, f, indent=1)
    refmap = {"n_cells": ncell}
    for ch in ("L", "R"):
        sfx = "" if ch == "L" else "_r"
        refmap["cell" + sfx] = chan[ch]["cell"].refmap
        refmap["global" + sfx] = {}
        for k in ("core", "iv"):
            refmap["global" + sfx].update(chan[ch][k].refmap)
    json.dump(refmap, open(os.path.join(OUT, "refmap.json"), "w"), indent=1)
    print("wrote", OUT, "cells", ncell, "x2 channels; cell elems", len(refmap["cell"]), "global elems", len(refmap["global"]))

if __name__ == "__main__":
    main()
