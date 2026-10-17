# Rounds 104/105 (2026-09-22): TWO full re-ID campaigns on alternative I/V plants,
# interleaved on the 2-solver budget (TRAP 8):
#   104 = ratified P5 TIA with C_col 12n -> 47n            (patch_p5 CCOL=47n)
#   105 = passive R_load 100R + RC-filtered difference V-stage (patch_p5 IVMODE=rload)
#         (INVALID at 12n/10n - passives do not settle in the SEG-40 chop; see R106)
#   107 = ratified P5 TIA 12n + Rg5 back to 100R (R106 culprit; -Only 107)
# Each: stage 1 (2 LUT chop decks -> cosim<V>lut_inl.npy), stage 3 (6 records
# a-f, BINs 37/37/17/11/5/27), fit (V<V>=1 NUALL=1 CUBIC=1 RIDGE=1e8 ->
# cosim<V>c3j), gates <V>g37 (worst, seen bin) and <V>g23 (unseen bin).
# Full R101 protocol; compare against gates 102/103 (-115.8/-119.6, -119.5/-115.5).
# Usage: powershell -ExecutionPolicy Bypass -File utils\r104_105.ps1 [-Only 104|105]
param([string]$Only = "")
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$variants = @(
    @{ v = "104"; env = @{ CCOL = "47n" };        seed0 = 161 },
    @{ v = "105"; env = @{ IVMODE = "rload" };    seed0 = 171 },
    @{ v = "107"; env = @{ RG5 = "100" };         seed0 = 181 })
if ($Only) { $variants = $variants | Where-Object { $_.v -eq $Only } }
$bins = @(37, 37, 17, 11, 5, 27)

function Set-VarEnv($var) {
    foreach ($k in 'CCOL', 'IVMODE', 'RG5', 'PADMOS') { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    foreach ($k in $var.env.Keys) { Set-Item "Env:$k" $var.env[$k] }
}
function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Wait-All { Wait-Slot 1 }
function Launch($tag) {
    Remove-Item "$lt\cosim${tag}_pavg.npy" -ErrorAction SilentlyContinue   # TRAP 9
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$tag.cir") -WindowStyle Hidden
    "  [$tag] launched $((Get-Date).ToString('HH:mm'))"
}
function Build-Stream($tag, $bin, $seed, $lut, $kernel) {
    $env:BIN = "$bin"; $env:DSEED = "$seed"
    if ($kernel) {
        $env:KERNEL = $kernel
        python "$root\utils\dpd_volt.py" $lut "cosim${tag}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$tag] $($_.Line)" }
        Remove-Item Env:KERNEL
    } else {
        python "$root\utils\dpd_study.py" $lut "cosim${tag}_code.npy" 2>$null | Select-String 'saved' | ForEach-Object { "  [$tag] $($_.Line)" }
    }
    python "$root\utils\gen_cosim41.py" $tag | Out-Null
    python "$root\utils\patch_v80.py" $tag | Out-Null
    python "$root\utils\patch_temp.py" $tag 45 | Out-Null
    python "$root\utils\patch_passive.py" $tag $tag | Out-Null
    python "$root\utils\patch_p5.py" $tag $tag
    Remove-Item Env:BIN, Env:DSEED -ErrorAction SilentlyContinue
}
function Read-Gate($tag, $bin) {
    $o = python "$root\utils\rtz_fft39.py" $tag 16384 $bin 2>&1
    $i = ($o | Select-String 'fund amp').LineNumber | Select-Object -Last 1
    $o | Select-Object -Skip ($i - 1) | Select-String 'HD' | ForEach-Object { "    [$tag] $($_.Line.Trim())" }
}

"===== STAGE 1: LUT decks ====="
foreach ($var in $variants) {
    Set-VarEnv $var
    foreach ($src in '54lut_t45p', '54lut2_t45p') {
        $dst = "${src}$($var.v)"
        python "$root\utils\patch_p5.py" $src $dst
        Launch $dst
    }
}
Wait-All
foreach ($var in $variants) {
    $v = $var.v
    foreach ($src in '54lut_t45p', '54lut2_t45p') {
        python "$root\utils\rtz_inl_full.py" "cosim${src}$v" | Select-Object -First 1 | ForEach-Object { "  [${src}$v] $_" }
    }
    python -c "import numpy as np; LT=r'$lt'; a=np.load(LT+r'\cosim54lut_t45p${v}_inl.npy'); b=np.load(LT+r'\cosim54lut2_t45p${v}_inl.npy'); m=(a+b)/2; np.save(LT+r'\cosim${v}lut_inl.npy', m); print(f'  [${v}lut] run-to-run {np.std(a-b):.2f} ppm rms, max|INL| {np.abs(m).max():.2f} ppm -> cosim${v}lut_inl.npy')"
}

"===== STAGE 3: records (interleaved) ====="
for ($k = 0; $k -lt 6; $k++) {
    foreach ($var in $variants) {
        Set-VarEnv $var
        $tag = "$($var.v)$('abcdef'[$k])"
        Build-Stream $tag $bins[$k] ($var.seed0 + $k) "cosim$($var.v)lut_inl.npy" $null
        Launch $tag
    }
}
Wait-All

"===== FIT ====="
foreach ($var in $variants) {
    $v = $var.v
    "--- record signatures $v (SPICE, static LUT only)"
    for ($k = 0; $k -lt 6; $k++) { Read-Gate "$v$('abcdef'[$k])" $bins[$k] | Select-Object -First 2 }
    Set-Item "Env:V$v" 1; $env:NUALL = '1'; $env:CUBIC = '1'; $env:RIDGE = '1e8'
    python "$root\utils\volterra_id2.py" 2>$null | Select-String 'hold|static|saved' | ForEach-Object { "  [$v] $($_.Line)" }
    Remove-Item "Env:V$v", Env:NUALL, Env:CUBIC, Env:RIDGE
}

"===== GATES ====="
foreach ($var in $variants) {
    Set-VarEnv $var
    $v = $var.v
    Build-Stream "${v}g37" 37 ($var.seed0 + 6) "cosim${v}lut_inl.npy" "cosim${v}c3j"
    Launch "${v}g37"
    Build-Stream "${v}g23" 23 ($var.seed0 + 7) "cosim${v}lut_inl.npy" "cosim${v}c3j"
    Launch "${v}g23"
}
Wait-All
foreach ($var in $variants) {
    $v = $var.v
    "--- gate ${v}g37 (BIN 37, vs gate 102 -115.8/-119.6, gate 93 -125.6/-123.8)"
    Read-Gate "${v}g37" 37
    "--- gate ${v}g23 (BIN 23, vs gate 103 -119.5/-115.5, gate 94 -121.7/-121.6)"
    Read-Gate "${v}g23" 23
}
foreach ($k in 'CCOL', 'IVMODE', 'RG5', 'PADMOS') { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
"DONE $((Get-Date).ToString('HH:mm'))"
