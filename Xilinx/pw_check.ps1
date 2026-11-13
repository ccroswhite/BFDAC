$lines = [IO.File]::ReadAllLines((Resolve-Path "build_8m\post_route_closed_timing.rpt").Path)
for ($i = 0; $i -lt $lines.Length; $i++) {
    if ($lines[$i] -match "^Pulse Width Checks") {
        for ($j = $i; $j -lt $lines.Length; $j++) {
            if ($lines[$j] -match "From Clock:\s+mmcm_clkout0") {
                $lines[$j..([Math]::Min($j + 45, $lines.Length - 1))]
                break
            }
        }
        break
    }
}
