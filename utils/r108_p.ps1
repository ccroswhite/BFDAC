# Round 108 (2026-09-24): acceptance-spec tests D2 / D3 / L1 on the LOCKED plant
# (P5 TIA 12n + Rg5 100R, 45C, 107lut + 107c3j kernel). Two solvers (TRAP 8).
#   108  D3  IMD 19+20 kHz, -3 dBFS peak, M 16384, bins 51/53 (= gate 96 recipe)
#            -> imd_read.py 108 16384 51 53                       (~35 min)
#   109  L1  -60 dBFS 1 kHz, M 65536 -> floor_read.py 109 65536 11 (~95 min)
#   110  L1  digital silence, M 65536 -> floor_read.py 110 65536 0 (~95 min)
#   111  D1/D2  -1 dBFS 1 kHz, M 65536, HD2..HD8 all in band (= gate 95 recipe)
#            -> rtz_fft39.py 111 65536 11                         (~95 min)
# Usage: powershell -ExecutionPolicy Bypass -File utils\r108_p.ps1
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$gates = @(
    @{ t = "108"; M = 16384; bin = 51; bin2 = 53; amp = "-3";   seed = 190 },
    @{ t = "109"; M = 65536; bin = 11; bin2 = 0;  amp = "-60";  seed = 191 },
    @{ t = "110"; M = 65536; bin = 11; bin2 = 0;  amp = "-200"; seed = 192 },
    @{ t = "111"; M = 65536; bin = 11; bin2 = 0;  amp = "-1";   seed = 193 })

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Build-Gate($g) {
    $t = $g.t
    $env:M = "$($g.M)"; $env:BIN = "$($g.bin)"; $env:DSEED = "$($g.seed)"; $env:AMPDB = $g.amp
    if ($g.bin2) { $env:BIN2 = "$($g.bin2)" }
    $env:KERNEL = 'cosim107c3j'; $env:RG5 = '100'
    python "$root\utils\dpd_volt.py" cosim107lut_inl.npy "cosim${t}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Out-Null
    python "$root\utils\patch_v80.py" $t | Out-Null
    python "$root\utils\patch_temp.py" $t 45 | Out-Null
    python "$root\utils\patch_passive.py" $t $t | Out-Null
    python "$root\utils\patch_p5.py" $t $t
    Remove-Item Env:M, Env:BIN, Env:DSEED, Env:AMPDB, Env:KERNEL, Env:RG5 -ErrorAction SilentlyContinue
    Remove-Item Env:BIN2 -ErrorAction SilentlyContinue
    Remove-Item "$lt\cosim${t}_pavg.npy" -ErrorAction SilentlyContinue
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$t.cir") -WindowStyle Hidden
    "  [$t] launched $((Get-Date).ToString('HH:mm')) (M $($g.M), BIN $($g.bin)$(if ($g.bin2) {'/' + $g.bin2}), $($g.amp) dBFS)"
}

"===== GATES ====="
foreach ($g in $gates) { Build-Gate $g }
Wait-Slot 1

"===== D3: IMD 19+20 kHz (gate 108; gate 96 on the proxy: f2-f1 -129.4, 2f1-f2 -126.0, 2f2-f1 -126.0) ====="
python "$root\utils\imd_read.py" 108 16384 51 53 2>&1 | Select-Object -Last 25
"===== L1: -60 dBFS floor (gate 109) ====="
python "$root\utils\floor_read.py" 109 65536 11
"===== L1: digital silence floor (gate 110) ====="
python "$root\utils\floor_read.py" 110 65536 0
"===== D1/D2: -1 dBFS 1 kHz long record (gate 111; gate 95 on the proxy: HD2..8 -122.1/-122.1/-124.8/-124.4/-136.0/-125.3/-122.6) ====="
$o = python "$root\utils\rtz_fft39.py" 111 65536 11 2>&1
$i = ($o | Select-String 'IDEAL').LineNumber
$o | Select-Object -Skip ($i - 1)
"===== D2 between-harmonic floor at -1 dBFS (gate 111, beta 20) ====="
$env:BETA = '20'; python "$root\utils\floor_read.py" 111 65536 11; Remove-Item Env:BETA
"DONE $((Get-Date).ToString('HH:mm'))"
