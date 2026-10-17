# Step 1 of the schematic build-out (2026-09-26): extract the REFERENCE
# NETLIST of the locked analog channel from a ratified cosim deck.
# - every element is classified into a hardware block or marked SIM-ONLY
#   (PWL/behavioural sources, the behavioural op-amp, probes);
# - the 64 cells are collapsed to ONE template after verifying that all 64
#   are identical modulo the cell index (any deviation is reported);
# - output: hw/ref_netlist.json (machine-readable, consumed later by the
#   KiCad netlist cross-check) and hw/ref_netlist.md (human summary).
#   python ref_netlist.py [deck_tag=112]
import json
import os
import re
import sys
from collections import defaultdict

LT = r"C:\Users\ccros\Documents\LTspice"
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAG = sys.argv[1] if len(sys.argv) > 1 else "112"

# element-name regex -> (block, sim_only, hardware note)
RULES = [
    (r"^(Vsel|Rsel|B\d+[ab]|Vnsch|R_nsch|Vpwa|Vpwb|R_pwa|R_pwb)", ("cell_drive", True,
        "FF Q/Qb levels vlo/vhi + RTZ window: realised by SN74LVC1G74 + level network (bom 1.2)")),
    (r"^(Bq|Bqb)\d+$", ("replica_ff", True, "= the same LVC1G74 Q/Qb outputs (3.3 V logic)")),
    (r"^(B_diff|R_do)$", ("probe", True, "measurement only")),
    (r"^(G_a_|R_a_|C_a_|E_b_|R_ld_)", ("iv_amp", True,
        "behavioural OPA1612-class amp + buffer: hardware = OPA1612 + BUF634A per rail (bom 4)")),
    (r"^(V_p15r|V_n15r|V_p8|V_vg|V_roff|V_fr|V_fr2|Vb1|Ve1|Vcb2[pm]|Vpadb|V_ref)$", ("rails_refs", False,
        "DC sources = regulated rails / references (bom 9); values are the ratified operating points")),
    (r"^R\d+[ab]$", ("cell", False, "10R base stoppers")),
    (r"^(QS\d+[ab]|Q4\d+|Rt\d+)$", ("cell", False, None)),
    (r"^(Rr1[pm]\d+|Rsh1[pm]|Csh1[pm]|QR1[pm]|Re1[pm])$", ("replica_ff", False, None)),
    (r"^(M[56][pm]|Rg[56]_[pm]|MR_[pm])$", ("cascode", False, None)),
    (r"^(Mpad_[pm]|Rpad_[pm]|Cpadb)$", ("padding", False, None)),
    (r"^(R_bleed_|C_bus_)", ("bus", False, None)),
    (r"^(R_bias|C_q4)$", ("reference", False, None)),
    (r"^(R_off_|R_f_|C_f_|C_col_)", ("iv", False, None)),
]

def classify(name):
    for pat, meta in RULES:
        if re.match(pat, name):
            return meta
    return ("UNCLASSIFIED", False, None)

def parse(path):
    lines = open(path).read().splitlines()
    # join continuation lines
    out = []
    for ln in lines:
        if ln.startswith("+") and out:
            out[-1] += " " + ln[1:]
        else:
            out.append(ln)
    els, params, models, ctrl = [], {}, [], []
    for ln in out:
        s = ln.strip()
        if not s or s.startswith("*"):
            continue
        if s.startswith("."):
            low = s.lower()
            if low.startswith(".param"):
                for m in re.finditer(r"(\w+)=(\{[^}]*\}|\S+)", s[6:]):
                    params[m.group(1)] = m.group(2)
            elif low.startswith(".model") or low.startswith(".lib"):
                models.append(s)
            else:
                ctrl.append(s)
            continue
        toks = s.split()
        name = toks[0]
        t = name[0].upper()
        npins = {"R": 2, "C": 2, "L": 2, "V": 2, "I": 2, "B": 2, "E": 4, "G": 4, "Q": 3, "M": 4, "D": 2}.get(t, 2)
        # Q may have 3 or 4 nodes; 4th token is model if it has no digits-only form -> handle Q as 3
        nodes = toks[1:1 + npins]
        rest = " ".join(toks[1 + npins:])
        els.append({"name": name, "type": t, "nodes": nodes, "value": rest})
    return els, params, models, ctrl

NAME_RE = re.compile(r"^(Vsel|Rsel|Bqb|Bq|B|R|QS|Q4|Rt|Rr1[pm])(\d{1,2})([ab]?)$")

def cell_index(el):
    """Return the cell index for per-cell elements (by name), else None."""
    m = NAME_RE.match(el["name"])
    return int(m.group(2)) if m else None

def canon(el, k):
    """Replace the cell index k by N in name / nodes / value, structure-aware."""
    m = NAME_RE.match(el["name"])
    name = f"{m.group(1)}N{m.group(3)}"
    node_pats = [(rf"^sel{k}$", "selN"), (rf"^bs{k}([12]d?)$", r"bsN\1"), (rf"^c{k}_([se])$", r"cN_\1"),
                 (rf"^q{k}$", "qN"), (rf"^qb{k}$", "qbN")]
    def node(n):
        for p, r in node_pats:
            n2 = re.sub(p, r, n)
            if n2 != n:
                return n2
        return n
    val = re.sub(rf"V\(sel{k}\)", "V(selN)", el["value"])
    val = re.sub(rf"sel{k:02d}\.txt", "selNN.txt", val)
    return {"name": name, "type": el["type"], "nodes": [node(n) for n in el["nodes"]], "value": val}

def main():
    path = os.path.join(LT, f"bfdac_cosim{TAG}.cir")
    els, params, models, ctrl = parse(path)
    blocks = defaultdict(list)
    cells = defaultdict(list)
    for el in els:
        k = cell_index(el)
        if k is not None:
            cells[k].append(canon(el, k))
        else:
            blocks["_global"].append(el)
    # verify the 64 cells are identical
    idx = sorted(cells)
    ref = sorted(cells[idx[0]], key=lambda e: e["name"])
    deviations = []
    for k in idx[1:]:
        cur = sorted(cells[k], key=lambda e: e["name"])
        if cur != ref:
            names_ref = {e["name"]: e for e in ref}
            for e in cur:
                if e["name"] not in names_ref:
                    deviations.append((k, e["name"], "extra element"))
                elif names_ref[e["name"]] != e:
                    deviations.append((k, e["name"], f"{names_ref[e['name']]} != {e}"))
            for n in names_ref:
                if n not in {e["name"] for e in cur}:
                    deviations.append((k, n, "missing element"))
    # classify
    result = defaultdict(lambda: {"hardware": [], "sim_only": []})
    notes = {}
    for el in blocks["_global"]:
        blk, sim, note = classify(el["name"])
        result[blk]["sim_only" if sim else "hardware"].append(el)
        if note:
            notes[blk] = note
    cell_hw, cell_sim = [], []
    for el in ref:
        blk, sim, note = classify(el["name"].replace("N", "1"))
        (cell_sim if sim else cell_hw).append(dict(el, block=blk))
        if note:
            notes[blk] = note

    # dangling nets: nodes touched by exactly one hardware element (cells count once)
    touch = defaultdict(int)
    for v in result.values():
        for el in v["hardware"]:
            for n in set(el["nodes"]):
                touch[n] += 1
    for el in cell_hw:
        for n in set(el["nodes"]):
            touch[n] += 1 if n.startswith(("cN", "bsN", "qN", "qbN")) else len(idx)
    dangling = sorted(n for n, c in touch.items() if c == 1 and n != "0")
    sim_nodes = {n for v in result.values() for el in v["sim_only"] for n in el["nodes"]}
    sim_nodes |= {n for el in cell_sim for n in el["nodes"]}
    sim_nodes |= {m for v in result.values() for el in v["sim_only"]
                  for m in re.findall(r"V\((\w+)\)", " ".join(el["nodes"]) + " " + el["value"])}
    interface = [n for n in dangling if n in sim_nodes]
    dead = [n for n in dangling if n not in sim_nodes]

    os.makedirs(os.path.join(ROOT, "hw"), exist_ok=True)
    data = {
        "source_deck": path,
        "params": params,
        "models": models,
        "control": ctrl,
        "n_cells": len(idx),
        "cell_deviations": deviations,
        "cell_template": {"hardware": cell_hw, "sim_only": cell_sim, "multiplicity": len(idx)},
        "blocks": {b: v for b, v in result.items()},
        "notes": notes,
        "interface_nets": interface,
        "dead_nets": dead,
    }
    with open(os.path.join(ROOT, "hw", "ref_netlist.json"), "w") as f:
        json.dump(data, f, indent=1)

    # ---- markdown summary ----
    md = [f"# Reference netlist - locked analog channel (from `bfdac_cosim{TAG}.cir`)", "",
          f"Generated by `utils/ref_netlist.py`. {len(els)} elements; {len(idx)} cells "
          f"({'all identical modulo index' if not deviations else f'{len(deviations)} DEVIATIONS - see below'}).",
          "", "## Parameters", "", "| name | value |", "|---|---|"]
    md += [f"| `{k}` | `{v}` |" for k, v in params.items()]
    md += ["", f"## Unit cell (x{len(idx)}) - hardware", "", "| element | nodes | value / model |", "|---|---|---|"]
    md += [f"| `{e['name']}` | `{' '.join(e['nodes'])}` | `{e['value']}` |" for e in cell_hw]
    md += ["", f"## Unit cell (x{len(idx)}) - sim-only (drive & probes)", "", "| element | nodes | value |", "|---|---|---|"]
    md += [f"| `{e['name']}` | `{' '.join(e['nodes'])}` | `{e['value']}` |" for e in cell_sim]
    order = ["cascode", "replica_ff", "padding", "bus", "reference", "iv", "rails_refs", "iv_amp", "cell_drive", "probe", "UNCLASSIFIED"]
    for b in order:
        if b not in result:
            continue
        v = result[b]
        md += ["", f"## Block `{b}`" + (f" - {notes[b]}" if b in notes else ""), ""]
        for kind in ("hardware", "sim_only"):
            if not v[kind]:
                continue
            md += [f"**{kind}**", "", "| element | nodes | value / model |", "|---|---|---|"]
            md += [f"| `{e['name']}` | `{' '.join(e['nodes'])}` | `{e['value']}` |" for e in v[kind]]
            md.append("")
    if deviations:
        md += ["", "## CELL DEVIATIONS", ""] + [f"- cell {k}: `{n}` - {why}" for k, n, why in deviations]
    md += ["", "## Interface nets (hardware boundary: driven by sim-only elements = FF bank outputs / op-amp input)", ""]
    md += [f"- `{n}`" for n in interface] or ["- none"]
    md += ["", "## Dead nets (single element, unused in the deck - do not draw)", ""]
    md += [f"- `{n}`" for n in dead] or ["- none"]
    md += ["", "## Models", ""] + [f"- `{m[:120]}`" for m in models]
    md += ["", "## Control", ""] + [f"- `{c}`" for c in ctrl]
    with open(os.path.join(ROOT, "hw", "ref_netlist.md"), "w") as f:
        f.write("\n".join(md) + "\n")

    hw_count = sum(len(v["hardware"]) for v in result.values())
    print(f"{len(els)} elements -> {len(idx)} cells x {len(cell_hw)} hw + {len(cell_sim)} sim-only; "
          f"global: {hw_count} hw, {sum(len(v['sim_only']) for v in result.values())} sim-only; "
          f"deviations: {len(deviations)}; unclassified: {len(result.get('UNCLASSIFIED', {}).get('hardware', []))}")
    for b in order:
        if b in result:
            print(f"  {b:12s} hw {len(result[b]['hardware']):3d}  sim {len(result[b]['sim_only']):3d}")
    print(f"interface nets: {interface}\ndead nets: {dead}")

if __name__ == "__main__":
    main()
