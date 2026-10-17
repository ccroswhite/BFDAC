# Round 115 (2026-09-28): the two P8 follow-ups on the real-drive plant
# (variant 125 = locked plant + patch_drive, MIDCODE 32.5 + DCOFF 0.5).
#   A  65k two-tone gate 129 (19+20 kHz -3 dBFS, bins 204/212 at M 65536,
#      125lut + 125c3jw3) -> imd_read sensing floor ~-134 instead of -128,
#      to resolve gate 127's f2-f1 -128.1 (dCS -130).
#   B  HD2 recovery: 8 more independent LUT chops (lut, lut2, lut7..lut12;
#      seeds 44, 45, 50..55) on the 125 plant -> cosim125lut12_inl.npy
#      (12-chop mean; LUT noise 0.57/sqrt(12) = 0.16 ppm rms vs 0.29 at 4
#      chops - the 2-chop -> 6-chop step took HD2 from -121 to -137 on the
#      ideal plant). Kernel 125c3jw3 unchanged (its static content is the
#      smooth cubic, the LUT carries the fine table). Gate 130 = D1 -1 dBFS
#      1 kHz M 65536 with the 12-chop LUT -> rtz_fft39 (vs 126: HD2 -128.3).
# Two solvers: 129 takes one slot (~95 min), chops fill the other (~80 min),
# 130 launches when the chops are done. ~3.5 h total.
# Usage: powershell -ExecutionPolicy Bypass -File utils\r115_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$V = '125'
$KERNEL = "cosim${V}c3jw3"
$chops = @('', '2', '7', '8', '9', '10', '11', '12')

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Launch($tag) {
    Remove-Item "$lt\cosim${tag}_pavg.npy" -ErrorAction SilentlyContinue
    Wait-Slot
    $p = Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$tag.cir") -WindowStyle Hidden -PassThru
    Write-Host "  [$tag] launched $((Get-Date).ToString('HH:mm'))"
    return $p
}
function Build-Stream($tag, $bin, $seed, $lut, $kernel, $M, $amp, $bin2 = 0, $extra = @{}) {
    $env:BIN = "$bin"; $env:DSEED = "$seed"; $env:M = "$M"; $env:AMPDB = $amp; $env:KERNEL = $kernel
    if ($bin2) { $env:BIN2 = "$bin2" }
    foreach ($k in $extra.Keys) { Set-Item "Env:$k" $extra[$k] }
    python "$root\utils\dpd_volt.py" $lut "cosim${tag}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$tag] $($_.Line)" }
    $env:RG5 = '100'
    python "$root\utils\gen_cosim41.py" $tag | Out-Null
    python "$root\utils\patch_v80.py" $tag | Out-Null
    python "$root\utils\patch_temp.py" $tag 45 | Out-Null
    python "$root\utils\patch_passive.py" $tag $tag | Out-Null
    python "$root\utils\patch_p5.py" $tag $tag | Out-Null
    python "$root\utils\patch_drive.py" $tag | Out-Null
    foreach ($k in @('BIN', 'DSEED', 'M', 'AMPDB', 'BIN2', 'KERNEL', 'RG5') + @($extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

"===== R115 $((Get-Date).ToString('HH:mm')) ====="
"===== A: 65k two-tone gate 129 (125lut + $KERNEL) ====="
Build-Stream "129" 204 221 "cosim${V}lut_inl.npy" $KERNEL 65536 "-3" 212 @{ MIDCODE = "32.5" }
$null = Launch "129"

"===== B: 8 more LUT chops on the $V plant ====="
$procs = @()
foreach ($n in $chops) {
    python "$root\utils\reorder_lut.py" 54lut_t45p107 "54lut${n}_t45p$V" | Out-Null
    python "$root\utils\patch_drive.py" "54lut${n}_t45p$V" | Out-Null
    $procs += Launch "54lut${n}_t45p$V"
}
foreach ($p in $procs) { $p.WaitForExit() }   # chops only; 129 may still be running
foreach ($n in $chops) {
    python "$root\utils\rtz_inl_full.py" "cosim54lut${n}_t45p$V" | Select-Object -First 1 | ForEach-Object { "  [lut$n] $_" }
}
python -c "import numpy as np; LT=r'$lt'; S=('','2','3','4','5','6','7','8','9','10','11','12'); A=np.array([np.load(LT+r'\cosim54lut%s_t45p$V`_inl.npy' % s) for s in S]); m=A.mean(0); np.save(LT+r'\cosim${V}lut12_inl.npy', m); m4=np.load(LT+r'\cosim${V}lut_inl.npy'); print('  [${V}lut12] 12-chop mean: per-chop rms dev %.2f ppm, max|INL| %.2f ppm, vs 4-chop 125lut rms diff %.2f ppm -> cosim${V}lut12_inl.npy' % (np.sqrt(((A-m)**2).mean()), np.abs(m).max(), np.std(m-m4)))"

"===== B: gate 130 D1 with the 12-chop LUT ====="
Build-Stream "130" 11 222 "cosim${V}lut12_inl.npy" $KERNEL 65536 "-1" 0 @{ DCOFF = "0.5"; MIDCODE = "32.5" }
$null = Launch "130"
Wait-Slot 1

"===== A readout: gate 129 (127 @16k: f2-f1 -128.1 (floor -128), 2f1-f2 -134.1, 2f2-f1 -137.1) ====="
python "$root\utils\imd_read.py" 129 65536 204 212 2>&1 | Select-Object -Last 25
"===== B readout: gate 130 (126 @4-chop: HD2 -128.3 HD3 -135.1 HD4 -131.7 HD5 -133.8 HD6 -128.2 HD7 -140.7 HD8 -152.4) ====="
$o = python "$root\utils\rtz_fft39.py" 130 65536 11 2>&1
$i = ($o | Select-String 'IDEAL').LineNumber
$o | Select-Object -Skip ($i - 1)
"DONE $((Get-Date).ToString('HH:mm'))"
