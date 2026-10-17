# Round 106 (2026-09-24): ISOLATE the gate-102/104 distortion residue.
# Record-level A/B at BIN 37, seed 151 (= record 101a's stream), static LUT
# from the same plant (one chop deck each). Compare raw HD2/HD3 vs
#   101a (TIA 12n, Rg5 10, MOSFET pad): -110.5 / -96.3
#   92a  (28R proxy, Rg5 100, BJT pad):  ~-96  / -101..-104
# Variants (all TIA 12n unless noted):
#   106a  Rg5 100            (undo ruling 4b)
#   106b  BJT pad            (undo ruling 4a)
#   106c  Rg5 100 + BJT pad  (= gate-93 plant + TIA I/V only)
#   106d  105b: passive R_load 100 + V-stage, C_col 3.3n, C_vf 1n (tau 0.43 us),
#         LUT chop at SEG 80 (stretch_lut) so the passives settle
param([string]$Only = "")
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$variants = @(
    @{ v = "106a"; env = @{ RG5 = "100" } },
    @{ v = "106b"; env = @{ PADMOS = "0" } },
    @{ v = "106c"; env = @{ RG5 = "100"; PADMOS = "0" } },
    @{ v = "106d"; env = @{ IVMODE = "rload"; CCOL = "3.3n"; CVF = "1n" }; seg = 80 })
if ($Only) { $variants = $variants | Where-Object { $_.v -eq $Only } }
$envkeys = 'RG5', 'PADMOS', 'IVMODE', 'CCOL', 'CVF'

function Set-VarEnv($var) {
    foreach ($k in $envkeys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    foreach ($k in $var.env.Keys) { Set-Item "Env:$k" $var.env[$k] }
}
function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Launch($tag) {
    Remove-Item "$lt\cosim${tag}_pavg.npy" -ErrorAction SilentlyContinue
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$tag.cir") -WindowStyle Hidden
    "  [$tag] launched $((Get-Date).ToString('HH:mm'))"
}

"===== LUT decks ====="
foreach ($var in $variants) {
    Set-VarEnv $var
    $v = $var.v
    if ($var.seg) {
        python "$root\utils\stretch_lut.py" 54lut_t45p "54lut_t45p${v}pre" $var.seg
        python "$root\utils\patch_p5.py" "54lut_t45p${v}pre_s$($var.seg)" "54lut_t45p${v}_s$($var.seg)"
        Remove-Item "$lt\bfdac_cosim54lut_t45p${v}pre_s$($var.seg).cir"
        Launch "54lut_t45p${v}_s$($var.seg)"
    } else {
        python "$root\utils\patch_p5.py" 54lut_t45p "54lut_t45p$v"
        Launch "54lut_t45p$v"
    }
}
Wait-Slot 1
foreach ($var in $variants) {
    $v = $var.v
    $tag = if ($var.seg) { "cosim54lut_t45p${v}_s$($var.seg)" } else { "cosim54lut_t45p$v" }
    python "$root\utils\rtz_inl_full.py" $tag | Select-Object -First 1 | ForEach-Object { "  [$v lut] $_" }
    Copy-Item "$lt\${tag}_inl.npy" "$lt\cosim${v}lut_inl.npy"
}

"===== records (BIN 37, seed 151) ====="
foreach ($var in $variants) {
    Set-VarEnv $var
    $v = $var.v
    $env:BIN = "37"; $env:DSEED = "151"
    python "$root\utils\dpd_study.py" "cosim${v}lut_inl.npy" "cosim${v}_code.npy" 2>$null | Select-String 'saved' | ForEach-Object { "  [$v] $($_.Line)" }
    Remove-Item Env:BIN, Env:DSEED
    python "$root\utils\gen_cosim41.py" $v | Out-Null
    python "$root\utils\patch_v80.py" $v | Out-Null
    python "$root\utils\patch_temp.py" $v 45 | Out-Null
    python "$root\utils\patch_passive.py" $v $v | Out-Null
    python "$root\utils\patch_p5.py" $v $v
    Launch $v
}
Wait-Slot 1
"===== record signatures (SPICE, static LUT only; 101a = -110.5 / -96.3) ====="
foreach ($var in $variants) {
    $v = $var.v
    $o = python "$root\utils\rtz_fft39.py" $v 16384 37 2>&1
    $i = ($o | Select-String 'fund amp').LineNumber | Select-Object -Last 1
    $o | Select-Object -Skip ($i - 1) | Select-String 'HD2|HD3|HD4|HD5' | ForEach-Object { "  [$v] $($_.Line.Trim())" }
}
foreach ($k in $envkeys) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
"DONE $((Get-Date).ToString('HH:mm'))"
