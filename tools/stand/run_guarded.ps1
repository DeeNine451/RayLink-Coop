# Runs a stand script and stops the stand's games at once if a game outside the stand starts (the owner's game: memory).
#   powershell -ExecutionPolicy Bypass -File tools\stand\run_guarded.ps1 -Script leave_group.ps1 -Out leave_lvs.out -ScriptArgs '-Role lvs'
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$Out,
    [string]$ScriptArgs = '',
    [string]$Stand = 'E:\RayLinkGames\GAMMA\game-dev',
    # outputs (the scenario's .out and .err): the repository's temp\stand, the run history (ignored)
    [string]$OutDir = (Join-Path $PSScriptRoot '..\..\temp\stand')
)
$ErrorActionPreference = 'Stop'
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$outPath = Join-Path $OutDir $Out
$errPath = $outPath + '.err'
$line = "-NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot $Script)`" $ScriptArgs"
$run = Start-Process -FilePath 'powershell.exe' -ArgumentList $line -PassThru -WindowStyle Hidden -RedirectStandardOutput $outPath -RedirectStandardError $errPath
$null = $run.Handle
$stopped = $false
while (-not $run.HasExited) {
    $games = Get-Process -Name 'AnomalyCoop*', 'RayLinkServer*', 'AnomalyDX*' -ErrorAction SilentlyContinue
    $foreign = $games | Where-Object { -not $_.Path -or -not $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) }
    if ($foreign) {
        $stopped = $true
        Stop-Process -Id $run.Id -Force
        $games | Where-Object { $_.Path -and $_.Path.StartsWith($Stand, [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { Stop-Process -Id $_.Id -Force }
        break
    }
    Start-Sleep -Seconds 3
}
if ($stopped) { Write-Host 'GUARD: a game outside the stand started, the stand run was stopped' }
else { Write-Host 'run finished' }
Get-Content -LiteralPath $outPath -Encoding UTF8 | Select-Object -Last 150
if ((Test-Path -LiteralPath $errPath) -and (Get-Item -LiteralPath $errPath).Length -gt 0) { Write-Host '--- stderr ---'; Get-Content -LiteralPath $errPath | Select-Object -Last 30 }
