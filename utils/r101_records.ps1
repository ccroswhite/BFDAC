# Round 101 Stage 3: ID records on the RATIFIED P5 plant (v80 + passive replica
# + patch_p5 I/V, MOSFET pad, Rg5 10R, .temp 45). Mirrors r92_records.ps1:
# static-LUT streams (dpd_study.py with the stage-1 P5 LUT), gen_cosim41 decks
# from the v72 template, patch_v80 + patch_temp + patch_passive + patch_p5,
# LTspice runs throttled to 2 concurrent solvers (TRAP 8).
# Usage: .\utils\r101_records.ps1 [-Lut cosim101lut_inl.npy]
param([string]$Lut = "cosim101lut_inl.npy")
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
# tag -> BIN, seed (fresh seeds 151-156; R92 used 131-136, gates 137-140)
$recs = @(
    @{ tag = "101a"; bin = 37; seed = 151 },
    @{ tag = "101b"; bin = 37; seed = 152 },
    @{ tag = "101c"; bin = 17; seed = 153 },
    @{ tag = "101d"; bin = 11; seed = 154 },
    @{ tag = "101e"; bin = 5;  seed = 155 },
    @{ tag = "101f"; bin = 27; seed = 156 })
foreach ($r in $recs) {
    $t = $r.tag
    $env:BIN = "$($r.bin)"; $env:DSEED = "$($r.seed)"
    python "$root\utils\dpd_study.py" $Lut "cosim${t}_code.npy" | Select-String -Pattern 'HD2|HD3|saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Select-Object -Last 1
    python "$root\utils\patch_v80.py" $t
    python "$root\utils\patch_temp.py" $t 45
    python "$root\utils\patch_passive.py" $t $t
    python "$root\utils\patch_p5.py" $t $t
    Remove-Item "$lt\cosim${t}_pavg.npy" -ErrorAction SilentlyContinue   # TRAP 9: stale FFT cache
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge 2) { Start-Sleep 30 }
    Start-Process 'C:\Program Files\ADI\LTspice\LTspice.exe' -ArgumentList @('-b', "$lt\bfdac_cosim$t.cir") -WindowStyle Hidden
    "  [$t] launched $((Get-Date).ToString('HH:mm'))"
}
Remove-Item Env:BIN, Env:DSEED -ErrorAction SilentlyContinue
Start-Sleep 5
"LTspice processes running: $((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count)"
