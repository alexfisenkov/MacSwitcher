param([Parameter(Mandatory=$true)][string]$SetupPath)
$ErrorActionPreference = 'Stop'
$localData = Join-Path $env:LOCALAPPDATA 'MacSwitcherWindows'
$sentinel = Join-Path $localData 'ci-preservation-sentinel.txt'
if (Test-Path $localData) { throw 'Installer preservation test requires a clean runner without existing MacSwitcherWindows user data.' }
New-Item -ItemType Directory -Force -Path $localData | Out-Null
Set-Content -Path $sentinel -Value 'keep-user-data' -NoNewline

function Install-Package {
  $process = Start-Process -FilePath $SetupPath -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Installer failed with exit code $($process.ExitCode)" }
}
function Find-UninstallEntry {
  $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
  Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
    $item = Get-ItemProperty $_.PSPath
    if ($item.DisplayName -eq 'MacSwitcher') { return $item }
  } | Select-Object -First 1
}

Install-Package
$entry = Find-UninstallEntry
if (-not $entry) { throw 'Per-user uninstall registration was not created.' }
if (-not (Test-Path $sentinel)) { throw 'User data disappeared on first install.' }

Install-Package
if (-not (Test-Path $sentinel)) { throw 'User data disappeared on reinstall.' }
$entry = Find-UninstallEntry
if (-not $entry) { throw 'Uninstall registration disappeared after reinstall.' }
$installLocation = $entry.InstallLocation
if (-not $installLocation) { $installLocation = Split-Path ([Environment]::ExpandEnvironmentVariables($entry.UninstallString.Trim('"'))) }
$installedExe = Join-Path $installLocation 'MacSwitcher.Windows.exe'
if (-not (Test-Path $installedExe)) { throw 'Installed application executable was not found.' }
& (Join-Path $PSScriptRoot 'test-installed-startup.ps1') -ExePath $installedExe
if (-not $?) { throw 'Installed startup smoke failed.' }
$uninstaller = [Environment]::ExpandEnvironmentVariables($entry.UninstallString.Trim('"'))
if (-not (Test-Path $uninstaller)) { throw "Uninstaller not found: $uninstaller" }
$process = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
if ($process.ExitCode -ne 0) { throw "Uninstaller failed with exit code $($process.ExitCode)" }
if (-not (Test-Path $sentinel)) { throw 'User data disappeared on uninstall.' }
Remove-Item $localData -Recurse -Force
Write-Output 'Per-user install, reinstall, uninstall, and user-data-preservation checks passed.'
