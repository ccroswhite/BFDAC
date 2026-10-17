# bom item 17(i) accuracy sweep (2026-09-30): +1 % single-node offsets on the
# locked R114 plant (variant 125 LUT/kernel, DCOFF 0.5, MIDCODE 32.5), gate-126
# recipe shortened to M 16384 / BIN 3 (1.125 kHz) so 8 decks fit in ~3 h on two
# solvers.  Deltas vs the same-length baseline are the result; absolute floors
# at 16k are ~6 dB worse than the 65k gate.
#   base    - unchanged bias
#   vcm     - VCM  1.345 -> +1 %
#   vfr     - VFR  1.75  -> +1 %
#   chain   - VB1 and VE1 both +1 % (ratio preserved)
#   vb1     - VB1 alone +1 % (ratio broken)
#   cb2     - CASB2_P and _M both +1 %
#   cb2mis  - CASB2_P +0.2 %, _M unchanged (p/m mismatch)
#   vg      - V_VG 4.00 -> +0.5 % (the relaxed 17(i) requirement)
#   cb2m100 - CASB2_P +100 mV (realistic M6p/M6m V_th mismatch under one servoed node)
#   padmis  - Rpad_m 286 -> 280 R (+1 mA p/m padding mismatch, Mpad V_th spread under one gate node)
# Usage: powershell -ExecutionPolicy Bypass -File utils\sweep_refs.ps1 [-ReadOnly] [-Only name,name]
param([switch]$ReadOnly, [string[]]$Only)
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$V = '125'; $KERNEL = "cosim${V}c3jw3"; $BASE = '126s'; $M = 16384; $BIN = 3

$variants = [ordered]@{
    'vcm'    = @('^(V_vcm\s+vcm\s+0\s+DC\s+)\S+=>${1}1.35845')
    'vfr'    = @('^(V_fr\s+vfr\s+0\s+DC\s+)\S+=>${1}1.7675')
    'chain'  = @('^(Vb1\s+vb1\s+0\s+DC\s+)\S+=>${1}5.9994', '^(Ve1\s+ve1\s+0\s+DC\s+)\S+=>${1}7.272')
    'vb1'    = @('^(Vb1\s+vb1\s+0\s+DC\s+)\S+=>${1}5.9994')
    'cb2'    = @('^(Vcb2p\s+casb2_p\s+0\s+DC\s+)\S+=>${1}4.4137', '^(Vcb2m\s+casb2_m\s+0\s+DC\s+)\S+=>${1}4.4137')
    'cb2mis' = @('^(Vcb2p\s+casb2_p\s+0\s+DC\s+)\S+=>${1}4.37874')
    'vg'     = @('^(V_vg\s+v_vg\s+0\s+DC\s+)\S+=>${1}4.02')
    'cb2m100' = @('^(Vcb2p\s+casb2_p\s+0\s+DC\s+)\S+=>${1}4.47')
    'padmis' = @('^(Rpad_m\s+padb_em\s+vee15\s+)\S+=>${1}280')
}
$names = if ($Only) { @($variants.Keys | Where-Object { $Only -contains $_ }) } else { @($variants.Keys) }

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 30 }
}
function Launch($tag) {
    Remove-Item "$lt\cosim${tag}_pavg.npy" -ErrorAction SilentlyContinue
    Wait-Slot
    Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$tag.cir") -WindowStyle Hidden
    "  [$tag] launched $((Get-Date).ToString('HH:mm'))"
}
function Build-Stream($tag, $bin, $seed, $lut, $kernel, $M, $amp, $extra) {
    $env:BIN = "$bin"; $env:DSEED = "$seed"; $env:M = "$M"; $env:AMPDB = $amp; $env:KERNEL = $kernel
    foreach ($k in $extra.Keys) { Set-Item "Env:$k" $extra[$k] }
    python "$root\utils\dpd_volt.py" $lut "cosim${tag}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$tag] $($_.Line)" }
    $env:RG5 = '100'
    python "$root\utils\gen_cosim41.py" $tag | Out-Null
    python "$root\utils\patch_v80.py" $tag | Out-Null
    python "$root\utils\patch_temp.py" $tag 45 | Out-Null
    python "$root\utils\patch_passive.py" $tag $tag | Out-Null
    python "$root\utils\patch_p5.py" $tag $tag | Out-Null
    python "$root\utils\patch_drive.py" $tag | Out-Null
    foreach ($k in @('BIN', 'DSEED', 'M', 'AMPDB', 'KERNEL', 'RG5') + @($extra.Keys)) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
}
function Read-Gate($tag) {
    $o = python "$root\utils\rtz_fft39.py" $tag $M $BIN 2>&1
    $i = ($o | Select-String 'fund amp').LineNumber | Select-Object -Last 1
    if ($i) { $o | Select-Object -Skip ($i - 1) | Select-String 'HD|fund' | ForEach-Object { "    [$tag] $($_.Line.Trim())" } }
    else { "    [$tag] NO RESULT"; $o | Select-Object -Last 3 }
}

if (-not $ReadOnly) {
    "===== 17(i) sweep: baseline $BASE (M $M, BIN $BIN) $((Get-Date).ToString('HH:mm')) ====="
    if (-not $Only) { Build-Stream $BASE $BIN 218 "cosim${V}lut_inl.npy" $KERNEL $M "-1" @{ DCOFF = "0.5"; MIDCODE = "32.5" } }
    $src = Get-Content "$lt\bfdac_cosim$BASE.cir" -Raw
    foreach ($name in $names) {
        $tag = "${BASE}_$name"; $s = $src
        foreach ($r in $variants[$name]) {
            $pat, $rep = $r -split '=>', 2
            $n = ([regex]::Matches($s, $pat, 'Multiline')).Count
            if ($n -ne 1) { throw "[$tag] pattern '$pat' matched $n times" }
            $s = [regex]::Replace($s, $pat, $rep, 'Multiline')
        }
        Set-Content "$lt\bfdac_cosim$tag.cir" $s -NoNewline
        Copy-Item "$lt\cosim${BASE}_code.npy" "$lt\cosim${tag}_code.npy" -Force
        "  [$tag] deck written"
    }
    if (-not $Only) { Launch $BASE }
    foreach ($name in $names) { Launch "${BASE}_$name" }
    Wait-Slot 1
}

"===== RESULTS (M $M, BIN $BIN; compare to base) ====="
Read-Gate $BASE
foreach ($name in $names) { Read-Gate "${BASE}_$name" }
"DONE $((Get-Date).ToString('HH:mm'))"
