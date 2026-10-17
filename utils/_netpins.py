import sys, xml.etree.ElementTree as ET
refs = set(sys.argv[2:])
for net in ET.parse(sys.argv[1]).getroot().iter("net"):
    for nd in net.findall("node"):
        if nd.get("ref") in refs:
            print("%s pin %s (%s) -> %s" % (nd.get("ref"), nd.get("pin"), nd.get("pinfunction"), net.get("name")))
