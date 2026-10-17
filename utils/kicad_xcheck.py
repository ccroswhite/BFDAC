"""Cross-check the KiCad capture against hw/ref_netlist.json.

Runs kicad-cli netlist export, then compares connectivity as a partition of
(ref, pin) endpoints - net names are irrelevant, only which pins are tied
together.  Deck V-sources (rails/refs) are treated as the rail net itself;
sim-only elements are ignored; KiCad parts without a deck counterpart
(op-amp, buffer, PWR_FLAG) are reported but not compared.
"""
import json, os, subprocess, sys, collections
import xml.etree.ElementTree as ET

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
KI = os.path.join(ROOT, "hw", "kicad")
CLI = r"C:\Program Files\KiCad\10.0\bin\kicad-cli.exe"
SCH = os.path.join(KI, "bfdac_analog.kicad_sch")
XML = os.path.join(KI, "bfdac_analog.xml")

def kicad_partition():
    subprocess.run([CLI, "sch", "export", "netlist", "--format", "kicadxml", "-o", XML, SCH], check=True)
    t = ET.parse(XML).getroot()
    part = {}
    for net in t.find("nets").findall("net"):
        eps = frozenset((n.get("ref"), n.get("pin")) for n in net.findall("node"))
        for e in eps:
            part[e] = eps
    refs = {c.get("ref") for c in t.find("components").findall("comp")}
    return part, refs

def deck_partition(ref, refmap, sfx=""):
    """Return {(kicad_ref, pin): deck_net} for every mapped hardware pin of one channel instance
    (sfx "" = L, "_r" = R; both are checked against the same single-channel deck)."""
    P = ref["params"]
    endpoint_net = {}
    ncell = refmap["n_cells"]
    tmpl = {e["name"]: e for e in ref["cell_template"]["hardware"]}
    for name, m in refmap["cell" + sfx].items():
        e = tmpl[name]
        pmap = m.get("pinmap")
        for n in range(ncell):
            kref = m["refs"][n]
            pm = (pmap[n] if isinstance(pmap, list) else pmap) or {}
            nodes = [x.replace("N", str(n + 1), 1) if "N" in x and x != "0" else x for x in e["nodes"]]
            for i, pin in enumerate(pin_order(e["type"])):
                if pin in m["pins"]:
                    endpoint_net[(kref, pm.get(pin, pin))] = nodes[i]
    glob = {}
    for b in ref["blocks"].values():
        for e in b["hardware"]:
            glob[e["name"]] = e
    for name, m in refmap["global" + sfx].items():
        e = glob[name]
        pm = m.get("pinmap") or {}
        for i, pin in enumerate(pin_order(e["type"])):
            if pin in m["pins"]:
                endpoint_net[(m["refs"][0], pm.get(pin, pin))] = e["nodes"][i]
    return endpoint_net

# Deck nets realised as ONE hardware node (bom 9 ruling 2026-10-01: a single CASB2 servo output
# feeds both Rg6 gate stoppers; the deck keeps two V-sources only because they were swept separately).
MERGE = {"casb2_m": "casb2_p"}

def pin_order(t):
    return {"R": ["1", "2"], "C": ["1", "2"], "Q": ["C", "B", "E"], "M": ["D", "G", "S"]}[t]

def main():
    ref = json.load(open(os.path.join(ROOT, "hw", "ref_netlist.json")))
    refmap = json.load(open(os.path.join(KI, "refmap.json")))
    kpart, krefs = kicad_partition()
    errs = 0
    all_mapped = set()
    channels = [("L", "")] + ([("R", "_r")] if "cell_r" in refmap else [])
    for ch, sfx in channels:
        dnet = {ep: MERGE.get(net, net) for ep, net in deck_partition(ref, refmap, sfx).items()}
        # deck partition over mapped endpoints
        by_net = collections.defaultdict(set)
        for ep, net in dnet.items():
            by_net[net].add(ep)
        mapped = set(dnet)
        all_mapped |= mapped
        missing = [ep for ep in mapped if ep not in kpart]
        if missing:
            errs += len(missing)
            print("[%s] ENDPOINTS MISSING IN KICAD:" % ch, missing[:10], "..." if len(missing) > 10 else "")
        for net, eps in sorted(by_net.items()):
            kset = set()
            for ep in eps:
                if ep in kpart:
                    kset |= set(kpart[ep])
            kset_mapped = {e for e in kset if e in mapped}
            if kset_mapped != eps:
                errs += 1
                print("[%s] MISMATCH net %-12s deck=%d kicad=%d  deck-only=%s kicad-only=%s"
                      % (ch, net, len(eps), len(kset_mapped), sorted(eps - kset_mapped)[:5], sorted(kset_mapped - eps)[:5]))
        print("[%s] deck hardware endpoints checked: %d in %d nets" % (ch, len(mapped), len(by_net)))
    # the two channels must not touch each other except through the shared rails: every channel-local deck net of L
    # must have zero R endpoints in its KiCad net (and vice versa)
    if len(channels) == 2:
        dl = deck_partition(ref, refmap, ""); dr = deck_partition(ref, refmap, "_r")
        shared = {"GND", "0"} | {n for n in set(dl.values()) if n.lower() in
                                   ("p15a", "n15a", "vee15", "v_roff", "vp10", "v33ff", "v33clk", "v18")}
        for ep, net in dl.items():
            if net in shared or ep not in kpart:
                continue
            cross = [e for e in kpart[ep] if e in dr]
            if cross:
                errs += 1
                print("[L/R] CHANNEL SHORT on deck net %s: L %s tied to R %s" % (net, ep, cross[:3]))
    xml = ET.parse(XML).getroot()
    net_names = {(n.get("ref"), n.get("pin")): net.get("name")
                 for net in xml.find("nets") for n in net.findall("node")}
    values = {c.get("ref"): c.findtext("value") for c in xml.find("components")}
    for ch, offset in (("L", 0), ("R", -200)):
        for side, tp_num, r_num, gnd_num, out_num in (
                ("P", 987, 688, 992, 985), ("M", 988, 689, 993, 986)):
            tp_ref, gnd_ref, out_ref = ("TP%d" % (n + offset) for n in (tp_num, gnd_num, out_num))
            r_ref = "R%d" % (r_num + (100 if ch == "R" else 0))
            expected_stub = frozenset(((tp_ref, "1"), (r_ref, "2")))
            valid = (kpart.get((tp_ref, "1")) == expected_stub and
                     net_names.get((r_ref, "1")) == "COL_%s_%s" % (side, ch) and
                     net_names.get((gnd_ref, "1")) == "GND" and
                     net_names.get((out_ref, "1")) == "OUT_%s_%s" % (side, ch) and
                     values.get(r_ref) == "1.00k")
            if not valid:
                errs += 1
            print("[%s] COL_%s probe/1k/ground/output access: %s" % (ch, side, "PASS" if valid else "FAIL"))
    ui_pins = {("J1", "D20"): "TEST_SELECT_N", ("J1", "D19"): "TEST_STEP_N",
               ("J1", "D17"): "TEST_LED", ("J1", "B7"): "PG_ALL",
               ("R9100", "1"): "V18", ("R9102", "1"): "V18",
               ("R9101", "2"): "TEST_SELECT_N", ("R9103", "2"): "TEST_STEP_N",
               ("SW9000", "2"): "GND", ("SW9001", "2"): "GND",
               ("R9113", "1"): "TEST_LED", ("R9115", "1"): "V12SOM"}
    for ep, expected in ui_pins.items():
        if net_names.get(ep) != expected:
            errs += 1
            print("[BRINGUP] wrong GPIO/supply", ep, net_names.get(ep), "expected", expected)
    led_rails = ("P16A", "N16A", "V8P3", "V4P3", "V12SOM", "V33CLK", "V33FF", "V33D",
                 "V_ROFF_L", "P15A_L", "N15A_L", "VEE15_L", "VE1_L", "P5A_L", "V33RLY", "VAP_IO",
                 "V_ROFF_R", "P15A_R", "N15A_R", "VEE15_R", "VE1_R", "P5A_R")
    led_resistors = ("28.7k", "28.7k", "13k", "4.99k", "20.5k", "3.01k", "3.01k", "3.01k",
                     "26.7k", "26.7k", "26.7k", "26.7k", "10.7k", "3.01k", "3.01k", "3.01k",
                     "26.7k", "26.7k", "26.7k", "26.7k", "10.7k", "3.01k")
    for i, rail in enumerate(led_rails):
        resistor, led = "R%d" % (9000 + i), "D%d" % (9000 + i)
        negative = rail.startswith(("N", "VEE"))
        supply_pin, return_pin = ("1", "2") if negative else ("2", "1")
        valid = (values.get(resistor) == led_resistors[i] and
                 net_names.get((resistor, "1")) == rail and
                 (led, supply_pin) in kpart.get((resistor, "2"), ()) and
                 net_names.get((led, return_pin)) == ("GND_AP" if rail == "VAP_IO" else "GND"))
        if not valid:
            errs += 1
            print("[BRINGUP] wrong rail LED resistor/supply/polarity/return", rail)
    for ep, expected in {("R9110", "1"): "V18", ("R9112", "1"): "V12SOM",
                         ("Q9000", "2"): "GND", ("Q9001", "2"): "GND"}.items():
        if net_names.get(ep) != expected:
            errs += 1
            print("[BRINGUP] wrong buffered-indicator domain", ep, net_names.get(ep))
    for refdes, expected in {"R9110": "10k", "R9113": "10k", "R9112": "20k", "R9115": "20k"}.items():
        if values.get(refdes) != expected:
            errs += 1
            print("[BRINGUP] wrong 500uA LED driver resistor", refdes, values.get(refdes))
    print("[BRINGUP] checked 16 GPIO/supply endpoints, 22 direct rail indicators and 500uA resistor/driver values")
    unmapped_refs = sorted({r for r, _ in kpart if r not in {e[0] for e in all_mapped}})
    extra = [r for r in unmapped_refs if not r.startswith("#")]
    incell = [r for r in extra if len(r) > 4 and r[-4:].isdigit()]
    print("kicad-only parts (not compared): %d in cells (%d kinds/cell), global: %s"
          % (len(incell), len(incell) // (64 * len(channels)), ", ".join(r for r in extra if r not in incell)))
    print("RESULT:", "PASS" if errs == 0 else "FAIL (%d)" % errs)
    sys.exit(1 if errs else 0)

if __name__ == "__main__":
    main()
