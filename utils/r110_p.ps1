# Round 110 (2026-09-25): close L1 with the +0.5 code input offset (DCOFF 0.5,
# kernel cosim109c3jw3, LUT cosim109lut_inl.npy) on the locked plant.
#   117  -60 dBFS 1 kHz, M 65536, DCOFF 0.5   (109 without offset: -139.2 / max -149.1)
#   118  -90 dBFS 1 kHz, M 65536, DCOFF 0.5   (115 without offset: -136.9 / max -143.3 @15.5k)
# Two solvers in parallel; ~95 min. Readout: floor_read with GAIN_TAG=112.
# Usage: powershell -ExecutionPolicy Bypass -File utils\r110_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$KERNEL = 'cosim109c3jw3'
$LUT = 'cosim109lut_inl.npy'
$gates = @(
    @{ t = "117"; M = 65536; bin = 11; amp = "-60"; seed = 199; extra = @{ DCOFF = "0.5" } },
    @{ t = "118"; M = 65536; bin = 11; amp = "-90"; seed = 200; extra = @{ DCOFF = "0.5" } })

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Build-Gate($g) {
    $t = $g.t
    Remove-Item "$lt\cosim${t}_pavg.npy" -ErrorAction SilentlyContinue
    $env:M = "$($g.M)"; $env:BIN = "$($g.bin)"; $env:DSEED = "$($g.seed)"; $env:AMPDB = $g.amp
    foreach ($k in $g.extra.Keys) { Set-Item "Env:$k" $g.extra[$k] }
    $env:KERNEL = $KERNEL; $env:RG5 = '100'
    python "$root\utils\dpd_volt.py" $LUT "cosim${t}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Out-Null
    python "$root\utils\patch_v80.py" $t | Out-Null
    python "$root\utils\patch_temp.py" $t 45 | Out-Null
    python "$root\utils\patch_passive.py" $t $t | Out-Null
    python "$root\utils\patch_p5.py" $t $t
    foreach ($k in @('M', 'BIN', 'DSEED', 'AMPDB', 'KERNEL', 'RG5') + @($g.extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$t.cir") -WindowStyle Hidden
    "  [$t] launched $((Get-Date).ToString('HH:mm')): M $($g.M), $($g.amp) dBFS, DCOFF $($g.extra.DCOFF)"
}

"===== R110: L1 with DCOFF 0.5 (kernel $KERNEL, LUT $LUT) ====="
foreach ($g in $gates) { Build-Gate $g }
Wait-Slot 1
$env:GAIN_TAG = '112'
"===== L1: -60 dBFS + DCOFF 0.5 (gate 117; 109: ANALOG -139.2, max bin -149.1) ====="
python "$root\utils\floor_read.py" 117 65536 11
"===== L1: -90 dBFS + DCOFF 0.5 (gate 118; 115: ANALOG -136.9, max bin -143.3 @15.5k) ====="
python "$root\utils\floor_read.py" 118 65536 11
Remove-Item Env:GAIN_TAG
"DONE $((Get-Date).ToString('HH:mm'))"
