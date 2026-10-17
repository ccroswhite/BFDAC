# Round 111 (2026-09-26): gates G1 + G2 of hw/reconcile.md on the locked plant
# with the SHIPPING digital chain (109lut, kernel cosim109c3jw3, DCOFF 0.5):
#   G1 real base drive: Bq/Bqb 3.3 V -> Rout 25 -> rs 1350 / rp 301 -> VCM 1.345
#      (Thevenin 246 R) replaces the ideal B sources + 10 R stoppers
#   G2 MIDCODE 32.5 R_off (133 / 116 R)
#   119  D1  -1 dBFS 1 kHz, M 65536, DCOFF 0.5  -> rtz_fft39  (vs 112: HD3 -128.x, HD2..8 <= -115)
#   120  L1  -60 dBFS 1 kHz, M 65536, DCOFF 0.5 -> floor_read (vs 117: ADDED -141.9, max -152.5)
# Two solvers in parallel; ~95 min.
# Usage: powershell -ExecutionPolicy Bypass -File utils\r111_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$KERNEL = 'cosim109c3jw3'
$LUT = 'cosim109lut_inl.npy'
$gates = @(
    @{ t = "119"; M = 65536; bin = 11; amp = "-1";  seed = 201; extra = @{ DCOFF = "0.5" } },
    @{ t = "120"; M = 65536; bin = 11; amp = "-60"; seed = 202; extra = @{ DCOFF = "0.5" } })

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Build-Gate($g) {
    $t = $g.t
    Remove-Item "$lt\cosim${t}_pavg.npy" -ErrorAction SilentlyContinue
    $env:M = "$($g.M)"; $env:BIN = "$($g.bin)"; $env:DSEED = "$($g.seed)"; $env:AMPDB = $g.amp
    foreach ($k in $g.extra.Keys) { Set-Item "Env:$k" $g.extra[$k] }
    $env:KERNEL = $KERNEL; $env:RG5 = '100'; $env:MIDCODE = '32.5'
    python "$root\utils\dpd_volt.py" $LUT "cosim${t}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Out-Null
    python "$root\utils\patch_v80.py" $t | Out-Null
    python "$root\utils\patch_temp.py" $t 45 | Out-Null
    python "$root\utils\patch_passive.py" $t $t | Out-Null
    python "$root\utils\patch_p5.py" $t $t
    python "$root\utils\patch_drive.py" $t
    foreach ($k in @('M', 'BIN', 'DSEED', 'AMPDB', 'KERNEL', 'RG5', 'MIDCODE') + @($g.extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$t.cir") -WindowStyle Hidden
    "  [$t] launched $((Get-Date).ToString('HH:mm')): M $($g.M), $($g.amp) dBFS, DCOFF $($g.extra.DCOFF), MIDCODE 32.5, real drive"
}

"===== R111: G1 real base drive + G2 MIDCODE 32.5 (kernel $KERNEL, LUT $LUT) ====="
foreach ($g in $gates) { Build-Gate $g }
Wait-Slot 1
"===== D1: -1 dBFS 1 kHz (gate 119; 112 reference: all HD <= -115, HD3 stretch) ====="
python "$root\utils\rtz_fft39.py" 119 65536 11 2>&1 | Select-Object -Last 30
$env:GAIN_TAG = '119'
"===== L1: -60 dBFS + DCOFF 0.5 (gate 120; 117: ADDED -141.9, max bin -152.5) ====="
python "$root\utils\floor_read.py" 120 65536 11
Remove-Item Env:GAIN_TAG
"DONE $((Get-Date).ToString('HH:mm'))"
