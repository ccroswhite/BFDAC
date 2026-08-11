# Minimal LTspice .raw reader (binary, transient). Handles .step (multiple plots
# concatenated is NOT the LTspice format - steps share one plot; step boundaries
# are where time resets). Returns (names, data) with data shape (nvars, npoints).
# Time is float64, other variables float32 unless 'double' flag present.
import numpy as np
import re
import sys

def read_raw(path):
    with open(path, "rb") as f:
        blob = f.read()
    # header is UTF-16LE in modern LTspice; find 'Binary:' marker
    for enc, marker in (("utf-16-le", "Binary:\n".encode("utf-16-le")),
                        ("ascii", b"Binary:\n")):
        idx = blob.find(marker)
        if idx >= 0:
            header = blob[:idx].decode(enc, errors="replace")
            data_off = idx + len(marker)
            break
    else:
        raise ValueError("no Binary: marker found")
    nvars = int(re.search(r"No\. Variables:\s*(\d+)", header).group(1))
    npts = int(re.search(r"No\. Points:\s*(\d+)", header).group(1))
    dbl = "double" in re.search(r"Flags:\s*(.*)", header).group(1)
    names = []
    lines = header.splitlines()
    vi = next(i for i, l in enumerate(lines) if l.startswith("Variables:"))
    for l in lines[vi + 1: vi + 1 + nvars]:
        names.append(l.split("\t")[2])
    data = np.empty((nvars, npts))
    if dbl:
        arr = np.frombuffer(blob, dtype="<f8", count=nvars * npts, offset=data_off)
        data = arr.reshape(npts, nvars).T.copy()
    else:
        # per point: time float64 then (nvars-1) float32
        rec = np.dtype([("t", "<f8"), ("v", "<f4", (nvars - 1,))])
        arr = np.frombuffer(blob, dtype=rec, count=npts, offset=data_off)
        data[0] = arr["t"]
        data[1:] = arr["v"].T
    data[0] = np.abs(data[0])  # LTspice marks non-plotted points with negative time
    return names, data

if __name__ == "__main__":
    names, data = read_raw(sys.argv[1])
    print(f"{data.shape[1]} points, vars: {names}")
