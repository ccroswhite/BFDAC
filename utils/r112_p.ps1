# Round 112 (2026-09-26): isolate the gate-119 D1 failure (HD2 -90.4 / HD3
# -111.4 vs 112's -137.4 / -131.5; IDEAL stream identical). 119 changed three
# things at once vs 112: real base drive (G1), MIDCODE 32.5 (G2), DCOFF 0.5.
#   121  D1 -1 dBFS, ideal drive, MIDCODE 32.5, DCOFF 0.5   (G2 + DCOFF only)
#   122  D1 -1 dBFS, real drive,  MIDCODE 32,   no DCOFF    (G1 only)
# Both -> rtz_fft39. Two solvers in parallel; ~95 min.
# Usage: powershell -ExecutionPolicy Bypass -File utils\r112_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$KERNEL = 'cosim109c3jw3'
$LUT = 'cosim109lut_inl.npy'
$gates = @(
    @{ t = "121"; M = 65536; bin = 11; amp = "-1"; seed = 203; drive = $false; midcode = "32.5"; extra = @{ DCOFF = "0.5" } },
    @{ t = "122"; M = 65536; bin = 11; amp = "-1"; seed = 204; drive = $true;  midcode = "32";   extra = @{} })

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Build-Gate($g) {
    $t = $g.t
    Remove-Item "$lt\cosim${t}_pavg.npy" -ErrorAction SilentlyContinue
    $env:M = "$($g.M)"; $env:BIN = "$($g.bin)"; $env:DSEED = "$($g.seed)"; $env:AMPDB = $g.amp
    foreach ($k in $g.extra.Keys) { Set-Item "Env:$k" $g.extra[$k] }
    $env:KERNEL = $KERNEL; $env:RG5 = '100'; $env:MIDCODE = $g.midcode
    python "$root\utils\dpd_volt.py" $LUT "cosim${t}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Out-Null
    python "$root\utils\patch_v80.py" $t | Out-Null
    python "$root\utils\patch_temp.py" $t 45 | Out-Null
    python "$root\utils\patch_passive.py" $t $t | Out-Null
    python "$root\utils\patch_p5.py" $t $t
    if ($g.drive) { python "$root\utils\patch_drive.py" $t }
    foreach ($k in @('M', 'BIN', 'DSEED', 'AMPDB', 'KERNEL', 'RG5', 'MIDCODE') + @($g.extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$t.cir") -WindowStyle Hidden
    "  [$t] launched $((Get-Date).ToString('HH:mm')): $($g.amp) dBFS, MIDCODE $($g.midcode), DCOFF $($g.extra.DCOFF), drive $(if ($g.drive) {'REAL'} else {'ideal'})"
}

"===== R112: isolate gate-119 D1 failure (kernel $KERNEL, LUT $LUT) ====="
foreach ($g in $gates) { Build-Gate $g }
Wait-Slot 1
"===== 121: ideal drive + MIDCODE 32.5 + DCOFF 0.5 (112: HD2 -137.4 HD3 -131.5; 119: -90.4 / -111.4) ====="
python "$root\utils\rtz_fft39.py" 121 65536 11 2>&1 | Select-Object -Last 10
"===== 122: real drive only (MIDCODE 32, no DCOFF) ====="
python "$root\utils\rtz_fft39.py" 122 65536 11 2>&1 | Select-Object -Last 10
"DONE $((Get-Date).ToString('HH:mm'))"
