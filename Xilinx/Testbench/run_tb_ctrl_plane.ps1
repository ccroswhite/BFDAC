# Detached small unit-TB runner (2026-09-03).
# Usage: .\run_tb_ctrl_plane.ps1 [tb_name] [rtl_file ...]
#   tb_dac_ctrl_plane / tb_spi_ctrl_plane  -> spi_slave + dac_ctrl_plane (default)
#   tb_coef_bank_manager                   -> coef_bank_manager
#   tb_coef_bank_loader                    -> coef_bank_loader (set TB_DEFINES="SIM TB_TPP256")
#   tb_system_ddr4_to_fir                  -> ALL RTL (minus MIG wrapper), TB_DEFINES="SIM"
#   anything else: pass the RTL file names (relative to Xilinx/) explicitly, or ALL.
# Optional: $env:TB_DEFINES = "A B=1" adds -d A -d B=1 to xvlog.
# Same Start-Process/file-redirect pattern as run_tb_top.ps1 (xsim deadlocks
# on Windows when stdout is a PowerShell pipe).
param([string]$tb = "tb_dac_ctrl_plane",
      [Parameter(ValueFromRemainingArguments=$true)][string[]]$rtl)
if (-not $rtl) {
    switch ($tb) {
        "tb_cell_measurement" { $rtl = @("spi_slave.sv", "dac_ctrl_plane.sv", "dac_dsp_core.sv", "fir_polyphase_stereo.sv", "fir_polyphase_interpolator.sv", "polyphase_mac_engine.sv", "polyphase_adder_tree.sv", "halfband_x2.sv", "tpdf_dither_gen.sv", "noise_shaper_ef3.sv", "dem_sort.sv", "dpd_engine.sv", "bench_test_stimulus.sv", "bench_test_controller.sv") }
        "tb_bench_controller" { $rtl = @("bench_test_controller.sv") }
        "tb_bench_stimulus" { $rtl = @("bench_test_stimulus.sv") }
        "tb_coef_bank_manager" { $rtl = @("coef_bank_manager.sv") }
        "tb_coef_bank_loader"  { $rtl = @("coef_bank_loader.sv") }
        "tb_system_ddr4_to_fir" { $rtl = @("ALL") }
        default                { $rtl = @("spi_slave.sv", "dac_ctrl_plane.sv") }
    }
}
$env:PATH = "C:\AMDDesignTools\2026.1\Vivado\bin;" + $env:PATH
$dir = "C:\Users\ccros\src\BFDAC\Xilinx\Testbench"
Set-Location $dir
$log = "$dir\${tb}_run.log"
$bin = "C:\AMDDesignTools\2026.1\Vivado\bin"

function Invoke-Stage($name, $exe, $argList) {
    "=== $name start $(Get-Date) ===" | Out-File $log -Append
    $out = "$dir\${tb}_$name.out"
    $err = "$dir\${tb}_$name.err"
    $p = Start-Process -FilePath "$bin\$exe" -ArgumentList $argList -Wait -PassThru `
         -NoNewWindow -WorkingDirectory $dir `
         -RedirectStandardOutput $out -RedirectStandardError $err
    Get-Content $out | Out-File $log -Append
    Get-Content $err | Out-File $log -Append
    "=== $name exit code $($p.ExitCode) $(Get-Date) ===" | Out-File $log -Append
    return $p.ExitCode
}

"=== run start $(Get-Date) ===" | Out-File $log
if ($rtl -contains "ALL") {
    $rtl = Get-ChildItem "$dir\..\*.sv" | Where-Object { $_.Name -ne 'dac_ddr4_if_mig.sv' } | ForEach-Object { $_.Name }
}
$srcs = @($rtl | ForEach-Object { "`"$dir\..\$_`"" }) + @("`"$dir\$tb.sv`"")
$defs = if ($tb -eq 'tb_cell_measurement') { @('-d', 'SIM') } else { @() }
if ($env:TB_DEFINES) { $env:TB_DEFINES.Split(' ') | Where-Object { $_ } | ForEach-Object { $defs += @('-d', $_) } }
$rc = Invoke-Stage "xvlog" "xvlog.bat" (@('-sv', '-i', "$dir\..") + $defs + $srcs)
if ($rc -eq 0) { $rc = Invoke-Stage "xelab" "xelab.bat" @($tb, '-s', "${tb}_snap") }
if ($rc -eq 0) { $rc = Invoke-Stage "xsim"  "xsim.bat"  @("${tb}_snap", '-runall') }
if ($rc -eq 0 -and $tb -in @('tb_bench_controller', 'tb_bench_stimulus', 'tb_cell_measurement', 'tb_dac_ctrl_plane')) {
    $result = Get-Content "$dir\${tb}_xsim.out" -Raw
    if ($result -notmatch 'TB_PASS:' -or $result -match '(?m)^\s*(Fatal:|Error:|FAIL:|TB_FAIL:)') { $rc = 1 }
}
"=== run end rc=$rc $(Get-Date) ===" | Out-File $log -Append
exit $rc
