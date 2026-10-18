param(
    [string]$VivadoBin = "C:\AMDDesignTools\2026.1\Vivado\bin",
    [string]$LogDir = "",
    [switch]$CompileOnly
)
$ErrorActionPreference = "Stop"
$tbDir = $PSScriptRoot
$rtlDir = Split-Path $tbDir -Parent
$repoDir = Split-Path $rtlDir -Parent
if (-not $LogDir) { $LogDir = Join-Path $repoDir "logs\stream_rates" }
New-Item -ItemType Directory -Force $LogDir | Out-Null
$summary = Join-Path $LogDir "summary.log"
$runTag = [System.IO.Path]::GetFileName((Resolve-Path $LogDir).Path) -replace '[^A-Za-z0-9_]', '_'
$results = [System.Collections.Generic.List[object]]::new()
$env:PATH = "$VivadoBin;" + $env:PATH
Set-Location $tbDir

function Stage([string]$name, [string]$tool, [string[]]$arguments) {
    $out = Join-Path $LogDir "$name.out"
    $err = Join-Path $LogDir "$name.err"
    "$(Get-Date -Format o) START $name" | Out-File $summary -Append
    $process = Start-Process -FilePath (Join-Path $VivadoBin $tool) `
        -ArgumentList $arguments -WorkingDirectory $tbDir -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    "$(Get-Date -Format o) EXIT $name $($process.ExitCode)" | Out-File $summary -Append
    if ($process.ExitCode -ne 0) { throw "$name failed; see $out and $err" }
    return $out
}

try {
    "Stream-rate RTL checks; NO synthesis, place or route. $(Get-Date -Format o)" | Out-File $summary
    $generator = Join-Path $repoDir "utils\dpd_rtl_gen.py"
    $pythonCmd = Get-Command python -ErrorAction Stop
    $goldenOutput = & $pythonCmd.Source $generator 2>&1
    $goldenExitCode = $LASTEXITCODE
    $goldenOutput | Out-File (Join-Path $LogDir "generate_dpd_vectors.out")
    if ($goldenExitCode -ne 0) { throw "DPD golden-vector generator failed; see generate_dpd_vectors.out" }
    $sources = Get-ChildItem "$rtlDir\*.sv" |
        Where-Object Name -ne "dac_ddr4_if_mig.sv" |
        ForEach-Object { '"' + $_.FullName + '"' }
    $tests = @("tb_stream_rate_controller", "tb_i2s_master_rates", "tb_stream_pipeline",
               "tb_fir_window", "tb_coef_bank_loader", "tb_dac_ctrl_plane", "tb_spi_ctrl_plane",
               "tb_bench_controller", "tb_bench_stimulus", "tb_cell_measurement", "tb_cal_coef_store",
               "tb_fir_polyphase_stereo", "tb_vu13p_top", "tb_dpd_engine", "tb_dpd_deadline_monitor",
               "tb_coef_bank_manager", "tb_halfband_x2", "tb_automute", "tb_tpdf_dither_gen",
               "tb_qspi_subsys")
    $testSources = $tests | ForEach-Object { '"' + (Join-Path $tbDir "$_.sv") + '"' }
    $glbl = Join-Path (Split-Path $VivadoBin -Parent) "data\verilog\src\glbl.v"
    Stage "compile" "xvlog.bat" (@("-sv", "-i", "`"$rtlDir`"", "-d", "SIM") +
        $sources + $testSources + @("`"$glbl`"")) | Out-Null

    $jobs = @(
        @{Top="tb_stream_rate_controller"; Name="rate_control"; Generic=@()},
        @{Top="tb_i2s_master_rates"; Name="i2s_rates"; Generic=@()},
        @{Top="tb_fir_window"; Name="fir_x16"; Generic=@("-generic_top",'"RATE_SHIFT=0"')},
        @{Top="tb_fir_window"; Name="fir_x8"; Generic=@("-generic_top",'"RATE_SHIFT=1"')},
        @{Top="tb_fir_window"; Name="fir_x4"; Generic=@("-generic_top",'"RATE_SHIFT=2"')},
        @{Top="tb_fir_window"; Name="fir_x2"; Generic=@("-generic_top",'"RATE_SHIFT=3"')},
        @{Top="tb_fir_polyphase_stereo"; Name="fir_polyphase_stereo"; Generic=@()},
        @{Top="tb_stream_pipeline"; Name="stream_pipeline"; Generic=@()},
        @{Top="tb_coef_bank_manager"; Name="coef_bank_boundary"; Generic=@()},
        @{Top="tb_halfband_x2"; Name="halfband_precision_alignment"; Generic=@()},
        @{Top="tb_automute"; Name="automute_timers_mute_busy"; Generic=@()},
        @{Top="tb_tpdf_dither_gen"; Name="stereo_tpdf_range"; Generic=@()},
        @{Top="tb_qspi_subsys"; Name="qspi_boot_backpressure"; Generic=@()},
        @{Top="tb_dpd_deadline_monitor"; Name="dpd_deadline"; Generic=@()},
        @{Top="tb_dpd_engine"; Name="dpd_49cy"; Generic=@()},
        @{Top="tb_dpd_engine"; Name="dpd_50cy"; Generic=@("-generic_top",'"EN_PERIOD=50"')},
        @{Top="tb_dpd_engine"; Name="dpd_56cy"; Generic=@("-generic_top",'"EN_PERIOD=56"')},
        @{Top="tb_coef_bank_loader"; Name="filter_rate"; Generic=@()},
        @{Top="tb_dac_ctrl_plane"; Name="control"; Generic=@()},
        @{Top="tb_spi_ctrl_plane"; Name="spi"; Generic=@()},
        @{Top="tb_bench_controller"; Name="bench_control"; Generic=@()},
        @{Top="tb_bench_stimulus"; Name="bench_stimulus"; Generic=@()},
        @{Top="tb_cell_measurement"; Name="cell_measurement"; Generic=@()},
        @{Top="tb_cal_coef_store"; Name="cal_store"; Generic=@()},
        @{Top="tb_vu13p_top"; Name="top"; Generic=@()}
    )
    foreach ($job in $jobs) {
        $snapshot = "rates_${runTag}_$($job.Name)"
        Stage "$($job.Name)_elaborate" "xelab.bat" `
            (@($job.Top, "glbl", "-L", "unisims_ver", "-s", $snapshot) + $job.Generic) | Out-Null
        $result = "ELABORATED"
        if (-not $CompileOnly) {
            $outputPath = Stage "$($job.Name)_simulate" "xsim.bat" @($snapshot, "-runall",
                "-log", "`"$(Join-Path $LogDir "$($job.Name)_xsim.log")`"")
            $text = Get-Content $outputPath -Raw
            $failed = $text -match "(?im)^\s*(Fatal:|Error:|ERROR:|FAIL:|FAILURES:|TB_FAIL:|MISMATCH|\*+\s+\d+\s+ERROR)"
            $passed = $text -match "TB_PASS:|ALL TESTS PASS|PASS: \d+ samples|=== tb_spi_ctrl_plane complete ==="
            if ($failed -or -not $passed) { throw "$($job.Name) did not pass; see $outputPath" }
            $result = "PASS"
        }
        $results.Add([pscustomobject]@{Test=$job.Name; Result=$result})
        "$($job.Name): $result" | Out-File $summary -Append
    }
    $results | ConvertTo-Json | Out-File (Join-Path $LogDir "results.json")
    "COMPLETE $(Get-Date -Format o)" | Out-File $summary -Append
    exit 0
} catch {
    "FAILED: $_" | Out-File $summary -Append
    $results | ConvertTo-Json | Out-File (Join-Path $LogDir "results.json")
    exit 1
}
