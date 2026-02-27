param(
  [string]$OutputName = 'neru.exe',
  [switch]$CleanDeps
)

$ErrorActionPreference = 'Stop'

$litCmd = Get-Command lit -ErrorAction SilentlyContinue
$litPath = if ($litCmd) { 'lit' } elseif (Test-Path '.\lit') { '.\lit' } else { $null }
if (-not $litPath) { throw 'lit command not found. Install lit/luvi first.' }

if ($CleanDeps -and (Test-Path 'deps')) {
  Remove-Item -Recurse -Force 'deps'
}

& $litPath install
& $litPath make . $OutputName

if (-not (Test-Path $OutputName)) {
  throw "Build failed: output not found ($OutputName)"
}

Write-Host "Built $OutputName"
