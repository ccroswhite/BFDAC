"""Validate the generated SEAF symbols, footprint pad count, and connector nets."""
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


def validate():
    _, pins = g.get_symbol("bfdac:Samtec_SEAF40")
    assert len(pins) == 240
    assert {unit: sum(pin["unit"] == unit for pin in pins) for unit in range(1, 7)} == {
        unit: 40 for unit in range(1, 7)
    }
    assert {int(pin["num"]) for pin in pins} == set(range(1, 241))

    footprint = (ROOT / "hw" / "kicad" / "bfdac.pretty" /
                 (g.SEAF40_NAME + ".kicad_mod")).read_text(encoding="utf-8")
    smd_pads = {int(number) for number in re.findall(r'\(pad "(\d+)" smd', footprint)}
    assert smd_pads == set(range(1, 241))
    assert footprint.count("np_thru_hole") == 2
    expected_fp = "bfdac:" + g.SEAF40_NAME

    ctrl = read_sheet("ctrl.kicad_sch")
    power = read_sheet("power.kicad_sch")
    prereg = read_sheet("prereg.kicad_sch")
    connector_units = {}
    for tree, ref in ((ctrl, "J506"), (power, "J603"), (power, "J604"), (prereg, "J7705")):
        instances = component_instances(tree, ref)
        assert len(instances) == 6, (ref, len(instances))
        assert {int(value(instance, "unit")) for instance in instances} == set(range(1, 7))
        for instance in instances:
            assert value(instance, "lib_id") == '"bfdac:Samtec_SEAF40"'
            assert property_value(instance, "Footprint") == expected_fp
        connector_units[ref] = {int(value(instance, "unit")): instance for instance in instances}
    assert not component_instances(ctrl, "J507")
    assert not component_instances(ctrl, "J508")

    expected_conn1 = g.seaf_conn1_map()
    v12_pads = set(range(82, 92)) | set(range(122, 132)) | set(range(162, 172))
    v12_returns = set(range(41, 53)) | set(range(201, 213)) | {81, 92, 121, 132, 161, 172}
    v33_pads = {110, 111, 150, 151}
    v33_guard = {69, 70, 71, 72, 189, 190, 191, 192, 109, 112, 149, 152}
    assert {pad for pad, net in expected_conn1.items() if net == "V12SOM"} == v12_pads
    assert all(expected_conn1[pad] == "GND" for pad in v12_returns)
    assert all(expected_conn1[pad] != "GND_AP" for pad in v12_pads | v12_returns)
    assert {pad for pad, net in expected_conn1.items() if net == "V33_IF_IN"} == v33_pads
    assert all(expected_conn1[pad] == "GND" for pad in v33_guard)
    assert {pad for pad, net in expected_conn1.items() if net == "VAP_IO"} == {25, 74, 76, 78, 80}
    assert expected_conn1[15] == "AP_IRQ_N"
    assert expected_conn1[17] == "AP_RST_N"
    assert expected_conn1[23] == "SOM_PG"
    for ref, labels in (("J506", global_labels(ctrl)), ("J7705", global_labels(prereg))):
        for unit, instance in connector_units[ref].items():
            for pin in (pin for pin in pins if pin["unit"] == unit):
                number = int(pin["num"])
                actual = labels.get(pin_endpoint(instance, pin))
                assert actual == expected_conn1[number], (
                    "%s pad %d expected %s, got %s" %
                    (ref, number, expected_conn1[number], actual)
                )

    def expected_power(a, b, c=None):
        d = {1: "P16A", 2: "GND", 3: "N16A", 4: "GND",
             5: "V8P3", 6: "GND", 7: a, 8: "GND",
             9: a, 10: a, 11: a, 12: "GND", 13: "GND", 14: "GND",
             15: b, 16: b, 17: b, 18: b,
             19: "GND", 20: "GND", 21: "GND", 22: "GND",
             41: "P16A", 42: "GND", 43: "N16A", 44: "GND",
             45: "V8P3", 46: "GND"}
        if c:
            d.update({23: c, 24: c, 25: c, 26: c,
                      27: "GND", 28: "GND", 29: "GND", 30: "GND"})
        return d

    expected = {"J603": expected_power("V4P3_LA", "V4P3_LB", "V4P3_LC"),
                "J604": expected_power("V4P3_RA", "V4P3_RB")}
    power_labels = global_labels(power)
    for ref in ("J603", "J604"):
        for unit, instance in connector_units[ref].items():
            for pin in (pin for pin in pins if pin["unit"] == unit):
                number = int(pin["num"])
                actual = power_labels.get(pin_endpoint(instance, pin))
                want = expected[ref].get(number)
                assert actual == want, (ref, unit, number, want, actual)

    assert not any(expected_conn1[pad] == "GND_AP" for pad in
                   (82, 83, 84, 85, 86, 87, 88, 89, 90, 91,
                    122, 123, 124, 125, 126, 127, 128, 129, 130, 131,
                    162, 163, 164, 165, 166, 167, 168, 169, 170, 171))
    assert all(expected_conn1[pad] == "GND" for pad in
               (41, 42, 43, 44, 45, 46, 47, 48, 49, 50, 51, 52,
                201, 202, 203, 204, 205, 206, 207, 208, 209, 210, 211, 212,
                81, 92, 121, 132, 161, 172))
    assert all(expected_conn1[pad] == "V33_IF_IN" for pad in (110, 111, 150, 151))
    assert all(expected_conn1[pad] == "VAP_IO" for pad in (25, 74, 76, 78, 80))
    assert all(expected_conn1[pad] == "GND" for pad in
               (69, 70, 71, 72, 189, 190, 191, 192, 109, 112, 149, 152))


if __name__ == "__main__":
    validate()
    print("PASS: SEAF symbol and footprint map 240 contacts across six 40-pin rows")
    print("PASS: Conn1 labels match all 240 assignments and keep AP/carrier grounds separate")
    print("PASS: Conn2/Conn3 rail pins match; J507/J508 are absent from the active schematic")
