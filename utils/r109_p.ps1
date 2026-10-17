# Round 109 (2026-09-25): digital-chain fixes for the R108 misses, gated on the
# LOCKED plant (P5 TIA 12n + Rg5 100R, 45C). Two solvers (TRAP 8).
# Stage 1: four more independent LUT chops (reorder_lut.py seeds 46..49) ->
#          cosim109lut_inl.npy = 6-chop average (lut, lut2, lut3..lut6).
# Stage 2: gates with kernel cosim109c3jw3 (= 107a-f + gate-108 two-tone record,
#          stat table -> sine-weighted cubic; built offline by volterra_id2 V109=1
#          and inject_scan.py STATFIT=3):
#   112  D1  -1 dBFS 1 kHz, M 65536            -> rtz_fft39 (vs 111: HD4/6 -113)
#   114  L1  silence + DCOFF 0.5 code, M 65536 -> floor_read (mechanism test vs 110)
#   113  D3  19+20 kHz -3 dBFS, M 16384        -> imd_read  (vs 108: 2f1-f2 -114.3)
#   116  L1  silence, M 65536                  -> floor_read (new-kernel baseline)
#   115  L1  -90 dBFS 1 kHz, M 65536           -> floor_read (level-dependent tone?)
# Usage: powershell -ExecutionPolicy Bypass -File utils\r109_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$KERNEL = 'cosim109c3jw3'
$LUT = 'cosim109lut_inl.npy'
$gates = @(
    @{ t = "112"; M = 65536; bin = 11; bin2 = 0;  amp = "-1";   seed = 194; extra = @{} },
    @{ t = "114"; M = 65536; bin = 11; bin2 = 0;  amp = "-200"; seed = 196; extra = @{ DCOFF = "0.5" } },
    @{ t = "113"; M = 16384; bin = 51; bin2 = 53; amp = "-3";   seed = 195; extra = @{} },
    @{ t = "116"; M = 65536; bin = 11; bin2 = 0;  amp = "-200"; seed = 198; extra = @{} },
    @{ t = "115"; M = 65536; bin = 11; bin2 = 0;  amp = "-90";  seed = 197; extra = @{} })

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Launch($tag) {
    Remove-Item "$lt\cosim${tag}_pavg.npy" -ErrorAction SilentlyContinue
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$tag.cir") -WindowStyle Hidden
    "  [$tag] launched $((Get-Date).ToString('HH:mm'))"
}
function Build-Gate($g) {
    $t = $g.t
    $env:M = "$($g.M)"; $env:BIN = "$($g.bin)"; $env:DSEED = "$($g.seed)"; $env:AMPDB = $g.amp
    if ($g.bin2) { $env:BIN2 = "$($g.bin2)" }
    foreach ($k in $g.extra.Keys) { Set-Item "Env:$k" $g.extra[$k] }
    $env:KERNEL = $KERNEL; $env:RG5 = '100'
    python "$root\utils\dpd_volt.py" $LUT "cosim${t}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Out-Null
    python "$root\utils\patch_v80.py" $t | Out-Null
    python "$root\utils\patch_temp.py" $t 45 | Out-Null
    python "$root\utils\patch_passive.py" $t $t | Out-Null
    python "$root\utils\patch_p5.py" $t $t
    foreach ($k in @('M', 'BIN', 'DSEED', 'AMPDB', 'KERNEL', 'RG5', 'BIN2') + @($g.extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Launch $t
    "  [$t] M $($g.M), BIN $($g.bin)$(if ($g.bin2) {'/' + $g.bin2}), $($g.amp) dBFS, extra $($g.extra.Keys -join ',')"
}

"===== STAGE 1: LUT chops lut3..lut6 on the locked plant ====="
$env:RG5 = '100'
foreach ($n in 3, 4, 5, 6) {
    python "$root\utils\reorder_lut.py" 54lut_t45p107 "54lut${n}_t45p107"
    Launch "54lut${n}_t45p107"
}
Remove-Item Env:RG5 -ErrorAction SilentlyContinue
Wait-Slot 1
foreach ($n in 3, 4, 5, 6) {
    python "$root\utils\rtz_inl_full.py" "cosim54lut${n}_t45p107" | Select-Object -First 1 | ForEach-Object { "  [lut$n] $_" }
}
python -c "import numpy as np; LT=r'$lt'; L=[np.load(LT+r'\cosim54lut%s_t45p107_inl.npy' % s) for s in ('','2','3','4','5','6')]; A=np.array(L); m=A.mean(0); np.save(LT+r'\cosim109lut_inl.npy', m); print('  [109lut] 6-chop average: per-chop rms dev from mean %.2f ppm, max|INL| %.2f ppm, vs 107lut(2-chop) rms diff %.2f ppm -> cosim109lut_inl.npy' % (np.sqrt(((A-m)**2).mean()), np.abs(m).max(), np.std(m-np.load(LT+r'\cosim107lut_inl.npy'))))"

"===== STAGE 2: gates (kernel $KERNEL, LUT $LUT) ====="
foreach ($g in $gates) { Build-Gate $g }
Wait-Slot 1

"===== D1: -1 dBFS 1 kHz (gate 112; 111: -128.9/-124.6/-113.0/-132.0/-113.1/-134.8/-115.7) ====="
$o = python "$root\utils\rtz_fft39.py" 112 65536 11 2>&1
$i = ($o | Select-String 'IDEAL').LineNumber
$o | Select-Object -Skip ($i - 1)
"===== D3: IMD 19+20 kHz (gate 113; 108: f2-f1 -117.8, 2f1-f2 -114.3, 2f2-f1 -115.5) ====="
python "$root\utils\imd_read.py" 113 16384 51 53 2>&1 | Select-Object -Last 25
$env:GAIN_TAG = '112'
"===== L1: silence, new kernel (gate 116; 110: ANALOG -131.1 dB0 = 12.012 kHz line -131.3) ====="
python "$root\utils\floor_read.py" 116 65536 11
"===== L1: silence + DCOFF 0.5 (gate 114) ====="
python "$root\utils\floor_read.py" 114 65536 11
"===== L1: -90 dBFS (gate 115; 109 at -60: ANALOG -139.2, max bin -149.1) ====="
python "$root\utils\floor_read.py" 115 65536 11
Remove-Item Env:GAIN_TAG
"DONE $((Get-Date).ToString('HH:mm'))"
