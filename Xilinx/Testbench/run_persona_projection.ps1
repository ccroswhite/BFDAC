# Detached persona-projection runner (2026-12-02).
# Usage: .\run_persona_projection.ps1 -Fid 0x0000 [-Stim impulse] [-Nsamp 12288] ...
#   Compiles tb_persona_projection once per invocation (small; keeps it simple)
#   then runs xsim with the requested projection plusargs.
#   Output capture lands in build/voicing_sim4/cap_<fid>_<stim>.txt
param(
    [string]$Fid   = "0x0000",
    [string]$Fids  = "",   # comma list e.g. "0000,0208,0400" overrides -Fid
    [string]$Stim  = "impulse",
    [int]   $Nsamp = 12288,
    [int]   $Amp   = 7474300,
    [int]   $ToneCycle = 128,
    [int]   $VoEn  = 0,
    [int]   $K2    = 0,
    [int]   $K3    = 0,
    [string]$Image = "proj.hex",
    [string]$Out   = ""
)
$env:PATH = "C:\AMDDesignTools\2026.1\Vivado\bin;" + $env:PATH
$dir = "C:\Users\ccros\src\BFDAC\Xilinx\Testbench"
$tb  = "tb_persona_projection"
Set-Location $dir
# Image/capture paths must be relative: the -f args file passes them verbatim
# and xsim runs with this directory as cwd.
if ($Image -ne "proj.hex") { Copy-Item $Image "$dir\proj.hex" -Force }
if ($Out -eq "") {
    $Out = "cap_{0}_{1}.txt" -f $Fid.Replace("0x",""), $Stim
}
$log = "$dir\${tb}_${Fid}_${Stim}.log"
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

$rtl = @("dac_coef_subsys.sv", "coef_bank_loader.sv", "coef_bank_manager.sv",
         "coef_mute_envelope.sv", "voicing_commit_ctrl.sv",
         "fir_polyphase_stereo.sv", "fir_polyphase_interpolator.sv",
         "fir_stage1b_interp8.sv", "polyphase_mac_engine.sv",
         "polyphase_adder_tree.sv", "halfband_x2.sv", "dac_voicing_shaper.sv",
         "tpdf_dither_gen.sv")
$srcs = @($rtl | ForEach-Object { "`"$dir\..\$_`"" }) + @("`"$dir\$tb.sv`"")

$rc = Invoke-Stage "xvlog" "xvlog.bat" (@('-sv', '-i', "$dir\..", '-d', 'SIM') + $srcs)
if ($rc -eq 0) { $rc = Invoke-Stage "xelab" "xelab.bat" @($tb, '-s', "${tb}_snap") }
if ($rc -eq 0) {
    # loader.bat %* mangles '=' inside -testplusarg values on Windows; the -f
    # options file reaches xsim.exe untouched.
    $argsfile = "$dir\persona_args.f"
    @(
    $a = @(
        "${tb}_snap", '-runall',
        '-testplusarg', "IMAGE=$Image",
        '-testplusarg', "STIM=$Stim",
        '-testplusarg', "NSAMP=$Nsamp",
        '-testplusarg', "AMP=$Amp",
        '-testplusarg', "TONE_CYCLE=$ToneCycle",
        '-testplusarg', "VOEN=$VoEn",
        '-testplusarg', "K2=$K2",
        '-testplusarg', "K3=$K3",
        '-testplusarg', "OUT=$Out"
    )
    if ($Fids -ne "") { $a += @('-testplusarg', "FIDS=$Fids") }
    else              { $a += @('-testplusarg', "FID=$Fid") }
    $a | Out-File -Encoding ascii $argsfile
    $rc = Invoke-Stage "xsim" "xsim.bat" @('-f', $argsfile)
}
"=== run end rc=$rc $(Get-Date) ===" | Out-File $log -Append
exit $rc
