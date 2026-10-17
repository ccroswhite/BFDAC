# CASB2 servo sense-node audit (bom 17(k), 2026-10-01): short locked-plant runs
# (M 2048 / BIN 3 -> 9 kHz fundamental, 333 us) at three program levels with
# V(mid_p) V(mid_m) saved.  Question: does mean(mid_p) depend on level?  If it
# moves by more than a few mV across -60..-1 dBFS the ruled servo would modulate
# casb2 with the music envelope and must sense something else.
# Usage: powershell -ExecutionPolicy Bypass -File utils\servo_sense.ps1 [-ReadOnly]
param([switch]$ReadOnly)
$root = Split-Path $PSScriptRoot -Parent
$lt = 'C:\Users\ccros\Documents\LTspice'
$lts = 'C:\Program Files\ADI\LTspice\LTspice.exe'
$V = '125'; $KERNEL = "cosim${V}c3jw3"; $M = 2048; $BIN = 3
$levels = [ordered]@{ 'ss1' = '-1'; 'ss20' = '-20'; 'ss60' = '-60' }

function Wait-Slot($n = 2) {
    while ((Get-Process | Where-Object { $_.Name -like 'LTspice*' }).Count -ge $n) { Start-Sleep 15 }
}
function Build($tag, $amp) {
    $env:BIN = "$BIN"; $env:DSEED = '218'; $env:M = "$M"; $env:AMPDB = $amp; $env:KERNEL = $KERNEL
    $env:DCOFF = '0.5'; $env:MIDCODE = '32.5'
    python "$root\utils\dpd_volt.py" "cosim${V}lut_inl.npy" "cosim${tag}_code.npy" | Select-String 'saved' | ForEach-Object { "  [$tag] $($_.Line)" }
    $env:RG5 = '100'
    python "$root\utils\gen_cosim41.py" $tag | Out-Null
    python "$root\utils\patch_v80.py" $tag | Out-Null
    python "$root\utils\patch_temp.py" $tag 45 | Out-Null
    python "$root\utils\patch_passive.py" $tag $tag | Out-Null
    python "$root\utils\patch_p5.py" $tag $tag | Out-Null
    python "$root\utils\patch_drive.py" $tag | Out-Null
    foreach ($k in @('BIN', 'DSEED', 'M', 'AMPDB', 'KERNEL', 'RG5', 'DCOFF', 'MIDCODE')) { Remove-Item "Env:$k" -ErrorAction SilentlyContinue }
    $f = "$lt\bfdac_cosim$tag.cir"
    $s = Get-Content $f -Raw
    $s = $s -replace '(?m)^\.save V\(diffout\) V\(nsch\)\s*$', '.save V(diffout) V(nsch) V(mid_p) V(mid_m) V(casb2_p)'
    Set-Content $f $s -NoNewline
    (Select-String -Path $f -Pattern '^\.(tran|save)').Line | ForEach-Object { "  [$tag] $_" }
}

if (-not $ReadOnly) {
    "===== servo sense audit $((Get-Date).ToString('HH:mm')) ====="
    foreach ($tag in $levels.Keys) {
        Build $tag $levels[$tag]
        Wait-Slot
        Start-Process $lts -ArgumentList @('-b', "$lt\bfdac_cosim$tag.cir") -WindowStyle Hidden
        "  [$tag] launched $((Get-Date).ToString('HH:mm'))"
    }
    Wait-Slot 1
}
python "$root\utils\servo_sense.py" @($levels.Keys)
