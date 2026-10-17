# Round 91 quick-look runner: build leg a/b with the given PNP/RSUM, cut the
# transient to 8 us, save the replica/bus/rail signals, run LTspice, summarize.
# Usage: .\utils\q91_quick.ps1 -Leg a -Rsum 1000,10000 [-Pnp 2SA1036K]
param([string]$Leg = "a", [string[]]$Rsum = @("1000"), [string]$Pnp = "2SA1036K")
$lt = 'C:\Users\ccros\Documents\LTspice'
$root = Split-Path $PSScriptRoot -Parent
$runs = @()
foreach ($rs in $Rsum) {
    $env:RSUM = $rs; $env:PNP = $Pnp
    python "$root\utils\gen_cosim91.py" $Leg | Out-Null
    $s = Get-Content "$lt\bfdac_cosim91$Leg.cir" -Raw
    $s = $s.Replace('.tran 2n 2666.666394u 0', '.tran 2n 8u 0') -replace '\.save .*',
        '.save V(bus_plus) V(bus_minus) V(mid_p) V(casb_p) V(ns1p) Ic(QR1p) Ib(QR1p) Id(MR_p) Id(M5p) I(V_p8) I(V_n15r) I(V_fr) I(V_fr2) I(Ve1) I(Vb1) I(Vb2)'
    $n = "q91${Leg}_${Pnp}_r$rs"
    Set-Content "$lt\bfdac_$n.cir" $s
    & 'C:\Program Files\ADI\LTspice\LTspice.exe' -b "$lt\bfdac_$n.cir" | Out-Null
    $runs += $n
}
Remove-Item Env:RSUM, Env:PNP -ErrorAction SilentlyContinue
python -c @"
import sys; sys.path.insert(0, r'$root\utils'); from read_ltraw import read_raw; import numpy as np
V={'I(V_p8)':9,'I(V_n15r)':-15,'I(V_fr)':1.75,'I(V_fr2)':3,'I(Ve1)':7.2,'I(Vb1)':5.94,'I(Vb2)':9.54}
for tag in sys.argv[1:]:
    n, d = read_raw(rf'$lt\bfdac_{tag}.raw'); t = d[0]; m = t > 2e-6
    av = lambda x: np.trapezoid(x,t[m])/(t[m][-1]-t[m][0])
    print('==', tag); pt=0
    for s in n[1:]:
        x = d[n.index(s)][m]; p = -V[s]*av(x) if s in V else None; pt += p or 0
        print(f'  {s:12s} min {x.min():9.4f} max {x.max():9.4f} avg {av(x):9.4f} p-p {x.max()-x.min():8.4f}' + (f'  P {p:7.3f} W' if p is not None else ''))
    print(f'  rails total P {pt:.3f} W')
"@ $runs
