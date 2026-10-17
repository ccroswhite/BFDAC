"""Print pin names/numbers of KiCad library symbols (resolves `extends`).

usage: python utils/sym_pins.py Regulator_Linear TPS7A20xxxDBV [more symbols...]
"""
import re
import sys

KICAD_SYMS = r"C:\Program Files\KiCad\10.0\share\kicad\symbols"


def symbol_block(src, name):
    i = src.find('(symbol "%s"' % name)
    if i < 0:
        return None
    depth, j = 0, i
    while j < len(src):
        c = src[j]
        if c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth == 0:
                return src[i:j + 1]
        j += 1
    return src[i:]


def main():
    lib, names = sys.argv[1], sys.argv[2:]
    src = open("%s\\%s.kicad_sym" % (KICAD_SYMS, lib), encoding="utf-8").read()
    for n in names:
        blk = symbol_block(src, n)
        if blk is None:
            print(n, "NOT FOUND")
            continue
        ext = re.search(r'\(extends "([^"]+)"', blk)
        fp = re.search(r'"Footprint" "([^"]+)"', blk)
        print("==", n, "extends", ext.group(1) if ext else "-", "| fp", fp.group(1) if fp else "-")
        if ext:
            blk = symbol_block(src, ext.group(1))
        for m in re.finditer(r'\(pin (\w+) \w+(.*?)\(number "([^"]+)"', blk, re.S):
            nm = re.search(r'\(name "([^"]+)"', m.group(2))
            print("  pin %-4s %-12s %s" % (m.group(3), nm.group(1) if nm else "?", m.group(1)))


if __name__ == "__main__":
    main()
