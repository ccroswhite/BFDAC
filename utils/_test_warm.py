import sys
sys.path.insert(0, r'c:\Users\ccros\src\BFDAC\utils')
from fir_rtl_model import load_coefs, FIRInterpolator

coefs = load_coefs(r'c:\Users\ccros\src\BFDAC\Xilinx\fir_coefs.txt')
amp = 8388607
SAMPLE_CLKS = 8163

# RTL: cap[16..64] = 2199140433906 (4 identical outputs)
RTL_IDX  = 16
RTL_VAL  = 2199140433906

for warm in [0, 640, 1280, 2048, 8192, 8210, 16384]:
    fir = FIRInterpolator(coefs)
    for _ in range(warm):
        fir.tick(0, 0)
    fir.tick(1, amp)
    outputs = []
    for c in range(SAMPLE_CLKS - 1):
        out, vld = fir.tick(0, 0)
        if vld:
            outputs.append(out)
    for s in range(16):
        fir.tick(1, 0)
        for c in range(SAMPLE_CLKS - 1):
            out, vld = fir.tick(0, 0)
            if vld:
                outputs.append(out)
    nz_idx = [i for i, v in enumerate(outputs) if v != 0]
    match = outputs[RTL_IDX] == RTL_VAL if len(outputs) > RTL_IDX else False
    tag = 'MATCH' if match else 'MISS'
    if nz_idx:
        print(f'warm={warm:6d}: first_nz[{nz_idx[0]}]={outputs[nz_idx[0]]}, nz={len(nz_idx)} [{tag}]')
    else:
        print(f'warm={warm:6d}: no outputs [{tag}]')
