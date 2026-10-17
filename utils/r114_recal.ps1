# Round 114 (2026-09-27): full re-ID campaign on the REAL-BASE-DRIVE plant
# (variant 125 = locked plant + patch_drive: LVC1G74 Rout 25 -> rs 1350 / rp 301
# -> VCM 1.345; hw/reconcile.md G1). R111-113 showed the 109 LUT/kernel do not
# fit this plant (its static bow is 3x the ideal-drive bow because the FF
# output resistance x network current shifts the levels the passive replica
# sums; utils/drive_inl.py). Protocol = R101/R109:
#   stage 1  4 independent LUT chops lut3..6 (reorder_lut, from 54lut_t45p107)
#            + patch_drive -> cosim125lut_inl.npy (4-chop mean)
#   stage 3  records 125a-f (BINs 37/37/17/11/5/27, static LUT, dpd_study) and
#            125t (19+20 kHz two-tone, bins 51/53, 109c3jw3 stream, = gate-108
#            recipe) so D3 is not an extrapolation
#   fit      volterra_id2 VREC=125 NUALL=1 CUBIC=1 RIDGE=1e8 -> cosim125c3j;
#            inject_scan STATFIT=3 -> cosim125c3jw3 (stat table -> weighted cubic)
#   gates    126 D1 -1 dBFS 1 kHz M 65536 (DCOFF 0.5, MIDCODE 32.5) -> rtz_fft39
#            127 D3 19+20 kHz -3 dBFS M 16384                      -> imd_read
#            128 L1 -60 dBFS + DCOFF 0.5 M 65536                   -> floor_read
# Two solvers (TRAP 8); ~5-6 h. Compare: 112/121 (D1 -137/-131, -139/-127.5),
# 113 (D3 f2-f1 -156, 2f1-f2 -137, 2f2-f1 -139), 117/120 (L1 ADDED -142/-145).
# Usage: powershell -ExecutionPolicy Bypass -File utils\r114_recal.ps1 [-Skip1]
param([switch]$Skip1)
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$V = '125'
$bins = @(37, 37, 17, 11, 5, 27)
$seed0 = 211

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Launch($tag) {
    Remove-Item "$lt\cosim${tag}_pavg.npy" -ErrorAction SilentlyContinue   # TRAP 9
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$tag.cir") -WindowStyle Hidden
    "  [$tag] launched $((Get-Date).ToString('HH:mm'))"
}
function Build-Stream($tag, $bin, $seed, $lut, $kernel, $M = 16384, $amp = "-1", $bin2 = 0, $extra = @{}) {
    $env:BIN = "$bin"; $env:DSEED = "$seed"; $env:M = "$M"; $env:AMPDB = $amp
    if ($bin2) { $env:BIN2 = "$bin2" }
    foreach ($k in $extra.Keys) { Set-Item "Env:$k" $extra[$k] }
    if ($kernel) {
        $env:KERNEL = $kernel
        python "$root\utils\dpd_volt.py" $lut "cosim${tag}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$tag] $($_.Line)" }
    } else {
        python "$root\utils\dpd_study.py" $lut "cosim${tag}_code.npy" 2>$null | Select-String 'saved' | ForEach-Object { "  [$tag] $($_.Line)" }
    }
    $env:RG5 = '100'
    python "$root\utils\gen_cosim41.py" $tag | Out-Null
    python "$root\utils\patch_v80.py" $tag | Out-Null
    python "$root\utils\patch_temp.py" $tag 45 | Out-Null
    python "$root\utils\patch_passive.py" $tag $tag | Out-Null
    python "$root\utils\patch_p5.py" $tag $tag | Out-Null
    python "$root\utils\patch_drive.py" $tag | Out-Null
    foreach ($k in @('BIN', 'DSEED', 'M', 'AMPDB', 'BIN2', 'KERNEL', 'RG5', 'MIDCODE') + @($extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}
function Read-Gate($tag, $bin, $M = 16384) {
    $o = python "$root\utils\rtz_fft39.py" $tag $M $bin 2>&1
    $i = ($o | Select-String 'fund amp').LineNumber | Select-Object -Last 1
    $o | Select-Object -Skip ($i - 1) | Select-String 'HD' | ForEach-Object { "    [$tag] $($_.Line.Trim())" }
}

"===== R114: re-ID on the real-drive plant (variant $V) $((Get-Date).ToString('HH:mm')) ====="
if (-not $Skip1) {
    "===== STAGE 1: LUT chops lut3..6 + patch_drive ====="
    foreach ($n in 3, 4, 5, 6) {
        python "$root\utils\reorder_lut.py" 54lut_t45p107 "54lut${n}_t45p$V" | Out-Null
        python "$root\utils\patch_drive.py" "54lut${n}_t45p$V"
        Launch "54lut${n}_t45p$V"
    }
    Wait-Slot 1
    foreach ($n in 3, 4, 5, 6) {
        python "$root\utils\rtz_inl_full.py" "cosim54lut${n}_t45p$V" | Select-Object -First 1 | ForEach-Object { "  [lut$n] $_" }
    }
    python -c "import numpy as np; LT=r'$lt'; A=np.array([np.load(LT+r'\cosim54lut%d_t45p$V`_inl.npy' % n) for n in (3,4,5,6)]); m=A.mean(0); np.save(LT+r'\cosim${V}lut_inl.npy', m); print('  [${V}lut] 4-chop mean: per-chop rms dev %.2f ppm, max|INL| %.2f ppm, vs 109lut rms diff %.2f ppm -> cosim${V}lut_inl.npy' % (np.sqrt(((A-m)**2).mean()), np.abs(m).max(), np.std(m-np.load(LT+r'\cosim109lut_inl.npy'))))"
}

"===== STAGE 3: records ${V}a-f + two-tone ${V}t ====="
for ($k = 0; $k -lt 6; $k++) {
    $tag = "$V$('abcdef'[$k])"
    Build-Stream $tag $bins[$k] ($seed0 + $k) "cosim${V}lut_inl.npy" $null
    Launch $tag
}
Build-Stream "${V}t" 51 ($seed0 + 6) "cosim${V}lut_inl.npy" "cosim109c3jw3" 16384 "-3" 53
Launch "${V}t"
Wait-Slot 1

"===== FIT ====="
"--- record signatures (SPICE, static LUT only)"
for ($k = 0; $k -lt 6; $k++) { Read-Gate "$V$('abcdef'[$k])" $bins[$k] | Select-Object -First 2 }
python "$root\utils\imd_read.py" "${V}t" 16384 51 53 2>&1 | Select-String 'analog' | Select-Object -First 4 | ForEach-Object { "    [${V}t] $($_.Line.Trim())" }
$env:VREC = $V; $env:NUALL = '1'; $env:CUBIC = '1'; $env:RIDGE = '1e8'
python "$root\utils\volterra_id2.py" 2>$null | Select-String 'records|hold|dyn-action|saved' | ForEach-Object { "  [$V] $($_.Line)" }
Remove-Item Env:VREC, Env:NUALL, Env:CUBIC, Env:RIDGE
$env:STATFIT = '3'
python "$root\utils\inject_scan.py" "cosim${V}lut_inl.npy" "cosim${V}c3j" 2>&1 | Select-Object -Last 12 | ForEach-Object { "  [inject] $_" }
Remove-Item Env:STATFIT
$KERNEL = "cosim${V}c3jw3"

"===== GATES (LUT ${V}lut, kernel $KERNEL, MIDCODE 32.5) ====="
Build-Stream "126" 11 ($seed0 + 7) "cosim${V}lut_inl.npy" $KERNEL 65536 "-1"  0  @{ DCOFF = "0.5"; MIDCODE = "32.5" }
Launch "126"
Build-Stream "127" 51 ($seed0 + 8) "cosim${V}lut_inl.npy" $KERNEL 16384 "-3"  53 @{ MIDCODE = "32.5" }
Launch "127"
Build-Stream "128" 11 ($seed0 + 9) "cosim${V}lut_inl.npy" $KERNEL 65536 "-60" 0  @{ DCOFF = "0.5"; MIDCODE = "32.5" }
Launch "128"
Wait-Slot 1

"===== D1: -1 dBFS 1 kHz (gate 126; 121 ideal drive: HD2 -139.1 HD3 -127.5; 119 old LUT: -90.4/-111.4) ====="
$o = python "$root\utils\rtz_fft39.py" 126 65536 11 2>&1
$i = ($o | Select-String 'IDEAL').LineNumber
$o | Select-Object -Skip ($i - 1)
"===== D3: IMD 19+20 kHz (gate 127; 113: f2-f1 -156.4, 2f1-f2 -136.6, 2f2-f1 -139.3) ====="
python "$root\utils\imd_read.py" 127 16384 51 53 2>&1 | Select-Object -Last 25
"===== L1: -60 dBFS + DCOFF 0.5 (gate 128; 120: ADDED -144.8, max -155.5) ====="
$env:GAIN_TAG = '126'
python "$root\utils\floor_read.py" 128 65536 11
Remove-Item Env:GAIN_TAG
"DONE $((Get-Date).ToString('HH:mm'))"
