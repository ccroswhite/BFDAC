# Round 92 Stage 3: ID records on the PASSIVE-replica plant (v80 + patch_passive,
# .temp 45). Mirrors the R86 recipe: static-LUT streams (dpd_study.py with the
# stage-1 LUT), gen_cosim41 decks from the v72 template, patch_v80 + patch_temp
# + patch_passive, all six LTspice runs launched detached in parallel.
# Usage: .\utils\r92_records.ps1 [-Lut cosim92lut_inl.npy]
param([string]$Lut = "cosim92lut_inl.npy")
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
# tag -> BIN, seed (fresh seeds 131-136; R86 used 123-128, gates 129/130)
$recs = @(
    @{ tag = "92a"; bin = 37; seed = 131 },
    @{ tag = "92b"; bin = 37; seed = 132 },
    @{ tag = "92c"; bin = 17; seed = 133 },
    @{ tag = "92d"; bin = 11; seed = 134 },
    @{ tag = "92e"; bin = 5;  seed = 135 },
    @{ tag = "92f"; bin = 27; seed = 136 })
foreach ($r in $recs) {
    $t = $r.tag
    $env:BIN = "$($r.bin)"; $env:DSEED = "$($r.seed)"
    python "$root\utils\dpd_study.py" $Lut "cosim${t}_code.npy" | Select-String -Pattern 'HD2|HD3|saved' | ForEach-Object { "  [$t] $($_.Line)" }
    python "$root\utils\gen_cosim41.py" $t | Select-Object -Last 1
    python "$root\utils\patch_v80.py" $t
    python "$root\utils\patch_temp.py" $t 45
    python "$root\utils\patch_passive.py" $t $t
    Remove-Item "$lt\cosim${t}_pavg.npy" -ErrorAction SilentlyContinue   # TRAP 9: stale FFT cache
    # TRAP 8: >2 concurrent LTspice solvers oversubscribe the CPU (~70x slower)
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge 2) { Start-Sleep 30 }
    Start-Process 'C:\Program Files\ADI\LTspice\LTspice.exe' -ArgumentList @('-b', "$lt\bfdac_cosim$t.cir") -WindowStyle Hidden
    "  [$t] launched $((Get-Date).ToString('HH:mm'))"
}
Remove-Item Env:BIN, Env:DSEED -ErrorAction SilentlyContinue
Start-Sleep 5
"LTspice processes running: $((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count)"
