# Round 113 (2026-09-27): fix for the G1 failure. R112 isolated it to the real
# base drive alone (122: HD2 -90.3 / HD3 -112.5 with ideal drive replaced by
# rs 1350 / rp 301, Rth 246 R; 121 = MIDCODE 32.5 + DCOFF with ideal drive
# passes -139.1 / -127.5). The 246 R source lets the steering pair's own
# base-current / C_bc transients move the base edge with the code-dependent
# bus voltage. Fix under test: compensated divider - Cs across rs, Cp across
# rp with Cs*rs = Cp*rp (flat attenuation), so the base node sees
# 1/(jw(Cs+Cp)) at edge speeds (~13 R at 100 MHz) while DC power is unchanged.
#   123  D1 -1 dBFS, real drive + Cs 22p / Cp 100p, MIDCODE 32.5, DCOFF 0.5
#   124  D1 -1 dBFS, real drive + Cs 47p / Cp 220p, MIDCODE 32.5, DCOFF 0.5
# Both -> rtz_fft39 (pass = 121 class: HD2 <= -130, HD3 <= -125). ~95 min.
# Usage: powershell -ExecutionPolicy Bypass -File utils\r113_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$KERNEL = 'cosim109c3jw3'
$LUT = 'cosim109lut_inl.npy'
$gates = @(
    @{ t = "123"; M = 65536; bin = 11; amp = "-1"; seed = 205; cs = "22p"; cp = "100p"; extra = @{ DCOFF = "0.5" } },
    @{ t = "124"; M = 65536; bin = 11; amp = "-1"; seed = 206; cs = "47p"; cp = "220p"; extra = @{ DCOFF = "0.5" } })

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Build-Gate($g) {
    $t = $g.t
    Remove-Item "$lt\cosim${t}_pavg.npy" -ErrorAction SilentlyContinue
    $env:M = "$($g.M)"; $env:BIN = "$($g.bin)"; $env:DSEED = "$($g.seed)"; $env:AMPDB = $g.amp
    foreach ($k in $g.extra.Keys) { Set-Item "Env:$k" $g.extra[$k] }
    $env:KERNEL = $KERNEL; $env:RG5 = '100'; $env:MIDCODE = '32.5'; $env:CS = $g.cs; $env:CP = $g.cp
    python "$root\utils\dpd_volt.py" $LUT "cosim${t}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Out-Null
    python "$root\utils\patch_v80.py" $t | Out-Null
    python "$root\utils\patch_temp.py" $t 45 | Out-Null
    python "$root\utils\patch_passive.py" $t $t | Out-Null
    python "$root\utils\patch_p5.py" $t $t
    python "$root\utils\patch_drive.py" $t
    foreach ($k in @('M', 'BIN', 'DSEED', 'AMPDB', 'KERNEL', 'RG5', 'MIDCODE', 'CS', 'CP') + @($g.extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$t.cir") -WindowStyle Hidden
    "  [$t] launched $((Get-Date).ToString('HH:mm')): $($g.amp) dBFS, real drive + Cs $($g.cs) / Cp $($g.cp)"
}

"===== R113: compensated base network (kernel $KERNEL, LUT $LUT) ====="
foreach ($g in $gates) { Build-Gate $g }
Wait-Slot 1
"===== 123: Cs 22p / Cp 100p (122 uncompensated: HD2 -90.3 HD3 -112.5; 121 ideal: -139.1 / -127.5) ====="
python "$root\utils\rtz_fft39.py" 123 65536 11 2>&1 | Select-Object -Last 10
"===== 124: Cs 47p / Cp 220p ====="
python "$root\utils\rtz_fft39.py" 124 65536 11 2>&1 | Select-Object -Last 10
"DONE $((Get-Date).ToString('HH:mm'))"
