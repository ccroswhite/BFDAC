# Detached tb_vu13p_mig run: full top + REAL ddr4_0 MIG (BFM sim mode) +
# Micron DDR4 model (2026-09-04).
#
# Prereq (once): vivado -mode batch -source scripts/gen_ddr4_example.tcl
#   -> Xilinx/sim_mig/ddr4_example/ddr4_0_ex/{imports, ip_user_files/sim_scripts}
# The IP compile lists (vlog.prj / vhdl.prj) and xsim.ini (precompiled
# microblaze/axi/fifo libraries) are taken from that example and re-rooted.
#
# Same Start-Process/file-redirect pattern as run_tb_top.ps1 (xsim deadlocks
# on Windows when stdout is a PowerShell pipe).
$env:PATH = "C:\AMDDesignTools\2026.1\Vivado\bin;" + $env:PATH
$viv  = "C:\AMDDesignTools\2026.1\Vivado"
$bin  = "$viv\bin"
$xil  = "C:\Users\ccros\src\BFDAC\Xilinx"
$tbd  = "$xil\Testbench"
$ex   = "$xil\sim_mig\ddr4_example\ddr4_0_ex"
$xs   = "$ex\ddr4_0_ex.ip_user_files\sim_scripts\ddr4_0\xsim"
$imp  = "$ex\imports"
$run  = "$xil\sim_mig\run"
$log  = "$tbd\tb_mig_run.log"

if (-not (Test-Path "$xs\vlog.prj")) { "missing $xs\vlog.prj - run scripts/gen_ddr4_example.tcl first"; exit 2 }
New-Item -ItemType Directory -Force $run | Out-Null
Set-Location $run
Copy-Item "$xs\xsim.ini" "$run\xsim.ini" -Force

function Slash($p) { return ($p -replace '\\', '/') }

# --- Re-root the IP compile lists to absolute paths -------------------------
$exS  = Slash $ex
$vivS = Slash $viv
$vlog = Get-Content "$xs\vlog.prj" | ForEach-Object {
    $_ -replace '"\.\./\.\./\.\./\.\./', "`"$exS/" `
       -replace '"(\.\./)+AMDDesignTools/2026\.1/Vivado/', "`"$vivS/" `
       -replace '"glbl\.v"', "`"$vivS/data/verilog/src/glbl.v`""
}
$vhdl = Get-Content "$xs\vhdl.prj" | ForEach-Object { $_ -replace '"\.\./\.\./\.\./\.\./', "`"$exS/" }

# --- Micron model + design RTL + TB (all into xil_defaultlib) ---------------
$impS = Slash $imp
$model = @(
    "sv xil_defaultlib -i `"$impS`" \",
    "`"$impS/arch_package.sv`" \",
    "`"$impS/proj_package.sv`" \",
    "`"$impS/interface.sv`" \",
    "`"$impS/ddr4_model.sv`" \",
    ""
)
$rtlFiles = Get-ChildItem "$xil\*.sv" | Where-Object { $_.Name -ne 'dac_ddr4_if.sv' } | ForEach-Object { "`"$(Slash $_.FullName)`" \" }
$design = @("sv xil_defaultlib -i `"$(Slash $xil)`" \") + $rtlFiles + @(
    "`"$(Slash $xil)/ip/axi_dwc_coef/sim/axi_dwc_coef.v`" \",
    "`"$(Slash $tbd)/tb_vu13p_mig.sv`" \",
    ""
)
# Strip the IP list's trailing 'nosort' so our blocks append cleanly, then re-add it.
$vlogAll = ($vlog | Where-Object { $_ -notmatch '^\s*nosort' -and $_ -notmatch '^# Do not sort' }) + $model + $design + @("# Do not sort compile order", "nosort")
$vlogAll | Set-Content "$run\vlog.prj" -Encoding ASCII
$vhdl    | Set-Content "$run\vhdl.prj" -Encoding ASCII

function Invoke-Stage($name, $exe, $argList) {
    "=== $name start $(Get-Date) ===" | Out-File $log -Append
    $out = "$run\$name.out"; $err = "$run\$name.err"
    $p = Start-Process -FilePath "$bin\$exe" -ArgumentList $argList -Wait -PassThru `
         -NoNewWindow -WorkingDirectory $run -RedirectStandardOutput $out -RedirectStandardError $err
    Get-Content $out | Out-File $log -Append
    Get-Content $err | Out-File $log -Append
    "=== $name exit code $($p.ExitCode) $(Get-Date) ===" | Out-File $log -Append
    return $p.ExitCode
}

"=== run start $(Get-Date) ===" | Out-File $log
$defs = @('-d','DDR4_16G_X16','-d','DDR4_625_Timing','-d','SILENT','-d','FIXED_3200')
if ($env:TB_DEFINES) { $env:TB_DEFINES.Split(' ') | Where-Object { $_ } | ForEach-Object { $defs += @('-d', $_) } }
$rc = Invoke-Stage "xvlog" "xvlog.bat" (@('--incr','--relax','-L','uvm') + $defs + @('-prj','vlog.prj'))
if ($rc -eq 0) { $rc = Invoke-Stage "xvhdl" "xvhdl.bat" @('--incr','--relax','-prj','vhdl.prj') }
if ($rc -eq 0) {
    $libs = @('xil_defaultlib','microblaze_v11_0_17','proc_sys_reset_v5_0_17','lmb_v10_v3_0_16',
              'lmb_bram_if_cntlr_v4_0_28','blk_mem_gen_v8_4_13','iomodule_v3_1_14','uvm',
              'axi_dwidth_converter_v2_1_38','axi_register_slice_v2_1_37','axi_infrastructure_v1_1_0',
              'generic_baseblocks_v2_1_2','fifo_generator_v13_2_15','axi_data_fifo_v2_1_37',
              'axi_clock_converter_v2_1_36','axi_protocol_converter_v2_1_38',
              'unisims_ver','unimacro_ver','secureip','xpm')
    $largs = @('--incr','--relax','--mt','8') + ($libs | ForEach-Object { @('-L', $_) }) +
             @('--snapshot','tb_mig','xil_defaultlib.tb_vu13p_mig','xil_defaultlib.glbl','-log','elaborate.log')
    $rc = Invoke-Stage "xelab" "xelab.bat" $largs
}
if ($rc -eq 0) { $rc = Invoke-Stage "xsim" "xsim.bat" @('tb_mig','-runall','-log','simulate.log') }
"=== DONE rc=$rc $(Get-Date) ===" | Out-File $log -Append
exit $rc
