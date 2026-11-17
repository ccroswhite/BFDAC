"""Validate the generated PCIe card-edge connector symbols, footprints, and connector nets."""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "utils"))
import gen_kicad as g


def children(node, tag):
    return [item for item in node if isinstance(item, list) and item and item[0] == tag]


def value(node, tag, index=1):
    found = children(node, tag)
    return found[0][index] if found else None


def property_value(node, name):
    for item in children(node, "property"):
        if item[1] == '"%s"' % name:
            return item[2].strip('"')
    return None


def read_sheet(name):
    text = (ROOT / "hw" / "kicad" / name).read_text(encoding="utf-8")
    return g.parse(g.tokenize(text))[0]


def component_instances(tree, ref):
    return [item for item in children(tree, "symbol")
            if property_value(item, "Reference") == ref]


def global_labels(tree):
    result = {}
    for item in children(tree, "global_label"):
        at = children(item, "at")[0]
        result[(round(float(at[1]), 3), round(float(at[2]), 3))] = item[1].strip('"')
    return result


def pin_endpoint(instance, pin):
    at = children(instance, "at")[0]
    ox, oy = float(at[1]), float(at[2])
    px, py = ox + pin["x"], oy - pin["y"]
    dx, dy = {
        0: (-1, 0), 90: (0, 1), 180: (1, 0), 270: (0, -1)
    }[int(pin["ang"]) % 360]
    return round(px + dx * g.STUB, 3), round(py + dy * g.STUB, 3)


def check_symbol(size, npins, nunits):
    _, pins = g.get_symbol("bfdac:PCIe_%s" % size)
    assert len(pins) == 2 * npins, (size, len(pins))
    per_unit = {}
    for p in pins:
        per_unit[p["unit"]] = per_unit.get(p["unit"], 0) + 1
    expected_units = {1: 32, 2: 32} if size == "x4" else {1: 42, 2: 40, 3: 42, 4: 40}
    assert per_unit == expected_units, (size, per_unit)
    names = {p["num"] for p in pins}
    expected = {"A%d" % i for i in range(1, npins + 1)} | {"B%d" % i for i in range(1, npins + 1)}
    assert names == expected, (size, len(names ^ expected))

    # Amphenol 10165968 Gen6 vertical SMT land (PCI-SIG CEM pad geometry):
    # 0.53 x 2.0 mm pads @ 1.0 mm pitch, A/B rows at Y = -/+3.6 mm, 3.0 mm key
    # gap between positions 11 and 12, SH1/SH2 solder-retention pads at the ends.
    footprint = (ROOT / "hw" / "kicad" / "bfdac.pretty" /
                 (g.PCIE_FP[size] + ".kicad_mod")).read_text(encoding="utf-8")
    pad_at = {m[0]: (float(m[1]), float(m[2])) for m in
              re.findall(r'\(pad ([AB]\d+) smd rect \(at ([0-9.\-]+) ([0-9.\-]+)\)', footprint)}
    assert set(pad_at) == expected, (size, len(set(pad_at) ^ expected))
    assert len(re.findall(r'\(pad SH[12] smd', footprint)) == 2
    xs = sorted({x for x, y in pad_at.values()})
    gaps = [(a, b) for a, b in zip(xs, xs[1:]) if b - a > 1.01]
    assert len(gaps) == 1 and abs(gaps[0][1] - gaps[0][0] - 3.0) < 0.01, gaps   # key gap
    assert abs(gaps[0][0] - pad_at["A11"][0]) < 0.01
    assert {y for x, y in pad_at.values()} == {-3.6, 3.6}
    assert all(y < 0 for n, (x, y) in pad_at.items() if n[0] == "A")
    assert all(y > 0 for n, (x, y) in pad_at.items() if n[0] == "B")


def check_connector(sheet, labels, ref, sym_pins, expected_map):
    instances = component_instances(sheet, ref)
    nunits = g.PCIE_UNITS["x16" if len(expected_map) == 164 else "x4"]
    assert len(instances) == nunits, (ref, len(instances))
    assert {int(value(i, "unit")) for i in instances} == set(range(1, nunits + 1))
    size = "x16" if len(expected_map) == 164 else "x4"
    for instance in instances:
        assert value(instance, "lib_id") == '"bfdac:PCIe_%s"' % size
        assert property_value(instance, "Footprint") == "bfdac:" + g.PCIE_FP[size]
    by_unit = {int(value(i, "unit")): i for i in instances}
    for unit, instance in by_unit.items():
        for pin in (p for p in sym_pins if p["unit"] == unit):
            name = pin["num"]
            actual = labels.get(pin_endpoint(instance, pin))
            want = expected_map[name]
            assert actual == want, ("%s pin %s expected %s, got %s"
                                    % (ref, name, want, actual))


def validate():
    check_symbol("x16", 82, 4)
    check_symbol("x4", 32, 2)

    ctrl = read_sheet("ctrl.kicad_sch")
    power = read_sheet("power.kicad_sch")
    prereg = read_sheet("prereg.kicad_sch")

    _, x16_pins = g.get_symbol("bfdac:PCIe_x16")
    _, x4_pins = g.get_symbol("bfdac:PCIe_x4")

    expected_conn1 = g.pcie_conn1_map()
    # Conn1 discipline: side A = carrier power only (no AP domain), side B = AP domain
    # only (no carrier GND/power). V12SOM 20 contacts ~22 A at 1.1 A/finger.
    assert {p for p, n in expected_conn1.items() if n == "V12SOM"} == {
        "A%d" % i for i in range(1, 21)}
    assert {p for p, n in expected_conn1.items() if n == "V33_IF_IN"} == {
        "A57", "A58", "A59", "A60"}
    assert {p for p, n in expected_conn1.items() if n == "VAP_IO"} == {
        "B25", "B45", "B46", "B47", "B48"}
    assert all(not n.startswith("A") for p, n in expected_conn1.items() if n == "GND_AP")
    assert all(not p.startswith("B") for p, n in expected_conn1.items() if n == "GND")
    assert all(not p.startswith("B") for p, n in expected_conn1.items() if n == "V12SOM")
    assert expected_conn1["B15"] == "AP_IRQ_N"
    assert expected_conn1["B17"] == "AP_RST_N"
    assert expected_conn1["B23"] == "SOM_PG"

    check_connector(ctrl, global_labels(ctrl), "J506", x16_pins, expected_conn1)
    check_connector(prereg, global_labels(prereg), "J7705", x16_pins, expected_conn1)

    expected_603 = g.pcie_conn23("V4P3_LA", "V4P3_LB", "V4P3_LC")
    expected_604 = g.pcie_conn23("V4P3_RA", "V4P3_RB")
    check_connector(power, global_labels(power), "J603", x4_pins, expected_603)
    check_connector(power, global_labels(power), "J604", x4_pins, expected_604)
    check_connector(prereg, global_labels(prereg), "J7703", x4_pins, expected_603)
    check_connector(prereg, global_labels(prereg), "J7704", x4_pins, expected_604)

    # branch rails are independent regulator outputs - never shared between sites
    assert {p for p, n in expected_603.items() if n == "V4P3_LC"} == {
        "A%d" % i for i in range(21, 27)}
    assert all(expected_604["A%d" % i] == "GND" for i in range(21, 27))

    assert not component_instances(ctrl, "J507")
    assert not component_instances(ctrl, "J508")


if __name__ == "__main__":
    validate()
    print("PASS: PCIe x16 symbol/footprint = 164 contacts in 4 units; x4 = 64 in 2 units")
    print("PASS: Conn1 J506/J7705 labels match - side A carrier power, side B AP domain, grounds separate")
    print("PASS: Conn2/Conn3 J603/J604/J7703/J7704 rail pins match; J507/J508 absent")
