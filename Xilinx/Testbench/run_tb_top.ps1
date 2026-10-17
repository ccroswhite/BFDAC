# Detached tb_vu13p_top regression run (2026-09-01)
#
# NOTE: xvlog/xelab/xsim deadlock on Windows when stdout is a PowerShell
# pipe ("2>&1 | Out-File"). Each stage is therefore launched via
# Start-Process with file redirection and its output appended afterwards.
$env:PATH = "C:\AMDDesignTools\2026.1\Vivado\bin;" + $env:PATH
$dir = "C:\Users\ccros\src\BFDAC\Xilinx\Testbench"
Set-Location $dir
$log = "$dir\tb_top_run.log"
$bin = "C:\AMDDesignTools\2026.1\Vivado\bin"

function Invoke-Stage($name, $exe, $argList) {
    "=== $name start $(Get-Date) ===" | Out-File $log -Append
    $out = "$dir\tb_top_$name.out"
    $err = "$dir\tb_top_$name.err"
    $p = Start-Process -FilePath "$bin\$exe" -ArgumentList $argList -Wait -PassThru `
         -NoNewWindow -WorkingDirectory $dir `
         -RedirectStandardOutput $out -RedirectStandardError $err
    Get-Content $out | Out-File $log -Append
    Get-Content $err | Out-File $log -Append
    "=== $name exit code $($p.ExitCode) $(Get-Date) ===" | Out-File $log -Append
    return $p.ExitCode
}

"=== run start $(Get-Date) ===" | Out-File $log

# Exclude: dac_ddr4_if_mig.sv (redefines dac_ddr4_if with the real MIG IP
# ddr4_0/axi_dwc_coef — the tb uses the stub in dac_ddr4_if.sv) and the
# superseded flash_bridge.sv.
$exclude = @('dac_ddr4_if_mig.sv', 'flash_bridge.sv')
$srcs = (Get-ChildItem "$dir\..\*.sv" | Where-Object { $exclude -notcontains $_.Name } |
         ForEach-Object { "`"$($_.FullName)`"" })
$glbl = "C:\AMDDesignTools\2026.1\Vivado\data\verilog\src\glbl.v"
$rc = Invoke-Stage "xvlog" "xvlog.bat" (@('-sv') + $srcs + @("`"$dir\tb_vu13p_top.sv`"", "`"$glbl`""))
if ($rc -eq 0) {
    $rc = Invoke-Stage "xelab" "xelab.bat" @('tb_vu13p_top','glbl','-s','tb_top','-L','unisims_ver')
}
if ($rc -eq 0) {
    $rc = Invoke-Stage "xsim" "xsim.bat" @('tb_top','-runall')
}

"=== DONE $(Get-Date) ===" | Out-File $log -Append
