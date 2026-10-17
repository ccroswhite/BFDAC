# Round 116 (2026-09-28): k2 trim gate on the real-drive plant (variant 125).
# R115 readout: the residual 2nd-order line is a few-% MISMATCH of the LUT
# bow (stream HD2 -87.7 / f2-f1 -95.2 injected, plant-own the same magnitude):
#   129 f2-f1 (750 Hz): analog/stream 2.45 % at  -3.7 deg  (in-phase 2.44 %)
#   126 HD2   (2 kHz):                0.93 % at -34   deg  (in-phase 0.77 %)
#   130 HD2   (2 kHz, 12-chop LUT):   1.46 % at -21   deg  (in-phase 1.36 %)
# Same-sign in-phase residual = over-correction; the 12-chop LUT has the SAME
# bow (0.0519 ppm/cell^2) so chop noise is not the limiter. K2TRIM=0.985
# (bow x 0.985) predicts f2-f1 ~-135, HD2 -129/-133 (balanced between the
# 750 Hz and 2 kHz mismatches). Shipping LUT stays 4-chop 125lut.
#   131  D1 -1 dBFS 1 kHz M 65536, DCOFF 0.5    -> rtz_fft39  (vs 126)
#   132  two-tone 19+20 kHz -3 dBFS M 65536     -> imd_read   (vs 129)
# Both on separate solvers, ~95 min.
# Usage: powershell -ExecutionPolicy Bypass -File utils\r116_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$V = '125'
$KERNEL = "cosim${V}c3jw3"
$TRIM = '0.985'

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
    python "$root\utils\dpd_volt.py" $lut "cosim${tag}_code.npy" | Select-String 'saved|K2TRIM' | ForEach-Object { "  [$tag] $($_.Line)" }
    $env:RG5 = '100'
    python "$root\utils\gen_cosim41.py" $tag | Out-Null
    python "$root\utils\patch_v80.py" $tag | Out-Null
    python "$root\utils\patch_temp.py" $tag 45 | Out-Null
    python "$root\utils\patch_passive.py" $tag $tag | Out-Null
    python "$root\utils\patch_p5.py" $tag $tag | Out-Null
    python "$root\utils\patch_drive.py" $tag | Out-Null
    foreach ($k in @('BIN', 'DSEED', 'M', 'AMPDB', 'BIN2', 'KERNEL', 'RG5') + @($extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}

"===== R116 $((Get-Date).ToString('HH:mm')) K2TRIM=$TRIM ====="
Build-Stream "131" 11 223 "cosim${V}lut_inl.npy" $KERNEL 65536 "-1" 0 @{ DCOFF = "0.5"; MIDCODE = "32.5"; K2TRIM = $TRIM }
$null = Launch "131"
Build-Stream "132" 204 224 "cosim${V}lut_inl.npy" $KERNEL 65536 "-3" 212 @{ MIDCODE = "32.5"; K2TRIM = $TRIM }
$null = Launch "132"
Wait-Slot 1

"===== readout: gate 131 (126: HD2 -128.3 HD3 -135.1 HD4 -131.7 HD5 -133.8 HD6 -128.2 HD7 -140.7 HD8 -152.4) ====="
$o = python "$root\utils\rtz_fft39.py" 131 65536 11 2>&1
$i = ($o | Select-String 'IDEAL').LineNumber
$o | Select-Object -Skip ($i - 1)
"===== readout: gate 132 (129: f2-f1 -127.3 (floor -134.6), 2f1-f2 -137.7, 2f2-f1 -139.6) ====="
python "$root\utils\imd_read.py" 132 65536 204 212 2>&1 | Select-Object -Last 25
"DONE $((Get-Date).ToString('HH:mm'))"
