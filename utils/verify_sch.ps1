# Schematic verification: deck cross-check + KiCad ERC, all output to logs/.
# usage: pwsh -NoProfile -File utils\verify_sch.ps1   (run from the repo root; detach with Start-Process)
# Outputs: logs/xcheck.log, logs/erc.log, logs/erc.json; logs/verify_sch.done is written LAST (exit codes + time).
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force logs | Out-Null
Remove-Item logs\verify_sch.done -ErrorAction SilentlyContinue

python utils\kicad_xcheck.py *> logs\xcheck.log
$xc = $LASTEXITCODE

$cli = "C:\Program Files\KiCad\10.0\bin\kicad-cli.exe"
& $cli sch erc --format json --severity-all -o logs\erc.json hw\kicad\bfdac_analog.kicad_sch *> logs\erc.log
$ec = $LASTEXITCODE

$summ = 'import json; d=json.load(open("logs/erc.json")); v=[(s["path"],x) for s in d["sheets"] for x in s["violations"]]; print("ERC violations", len(v)); [print(x["severity"], x["type"], p, x["description"][:160]) for p,x in v[:60]]'
if (Test-Path logs\erc.json) { python -c $summ *>> logs\erc.log } else { "erc.json not produced" | Out-File -Append logs\erc.log }

"xcheck exit $xc; erc exit $ec; finished $(Get-Date -Format s)" | Out-File logs\verify_sch.done
