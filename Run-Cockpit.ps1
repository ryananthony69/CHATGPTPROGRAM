param()

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Join-Path $root 'app\Cockpit.ps1'

if (-not (Test-Path -LiteralPath $app)) {
  Write-Host "Missing app script: $app" -ForegroundColor Red
  exit 1
}

Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
  -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-Sta','-File', $app) `
  -WorkingDirectory $root
