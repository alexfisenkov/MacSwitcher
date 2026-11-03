param([Parameter(Mandatory=$true)][string]$SetupPath)
$ErrorActionPreference = 'Stop'
$localData = Join-Path $env:LOCALAPPDATA 'MacSwitcherWindows'
$sentinel = Join-Path $localData 'ci-preservation-sentinel.txt'
$artifacts = Join-Path $PSScriptRoot '..\artifacts'
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
if (Test-Path $localData) { throw 'Installer preservation test requires a clean runner without existing MacSwitcherWindows user data.' }
New-Item -ItemType Directory -Force -Path $localData | Out-Null
Set-Content -Path $sentinel -Value 'keep-user-data' -NoNewline

function Install-Package {
  $process = Start-Process -FilePath $SetupPath -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
  if ($process.ExitCode -ne 0) { throw "Installer failed with exit code $($process.ExitCode)" }
  return $process.ExitCode
}
function Find-UninstallEntry {
  $base = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall'
  Get-ChildItem $base -ErrorAction SilentlyContinue | ForEach-Object {
    $item = Get-ItemProperty $_.PSPath
    if ($item.DisplayName -eq 'MacSwitcher') { return $item }
  } | Select-Object -First 1
}

$firstInstallExitCode = Install-Package
$entry = Find-UninstallEntry
if (-not $entry) { throw 'Per-user uninstall registration was not created.' }
if (-not (Test-Path $sentinel)) { throw 'User data disappeared on first install.' }

$reinstallExitCode = Install-Package
if (-not (Test-Path $sentinel)) { throw 'User data disappeared on reinstall.' }
$entry = Find-UninstallEntry
if (-not $entry) { throw 'Uninstall registration disappeared after reinstall.' }
$installLocation = $entry.InstallLocation
if (-not $installLocation) { $installLocation = Split-Path ([Environment]::ExpandEnvironmentVariables($entry.UninstallString.Trim('"'))) }
$installedExe = Join-Path $installLocation 'MacSwitcher.Windows.exe'
if (-not (Test-Path $installedExe)) { throw 'Installed application executable was not found.' }
& (Join-Path $PSScriptRoot 'test-installed-startup.ps1') -ExePath $installedExe
if (-not $?) { throw 'Installed startup smoke failed.' }
$startupReceiptPath = Join-Path $artifacts 'installed-startup.json'
$startupReceipt = Get-Content $startupReceiptPath -Raw | ConvertFrom-Json
if ($startupReceipt.status -ne 'PASS') { throw 'Installed startup receipt did not report PASS.' }
$uninstaller = [Environment]::ExpandEnvironmentVariables($entry.UninstallString.Trim('"'))
if (-not (Test-Path $uninstaller)) { throw "Uninstaller not found: $uninstaller" }
$uninstallProcess = Start-Process -FilePath $uninstaller -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-' -Wait -PassThru
if ($uninstallProcess.ExitCode -ne 0) { throw "Uninstaller failed with exit code $($uninstallProcess.ExitCode)" }
if (-not (Test-Path $sentinel)) { throw 'User data disappeared on uninstall.' }
$setupHash = (Get-FileHash $SetupPath -Algorithm SHA256).Hash.ToLowerInvariant()
Remove-Item $localData -Recurse -Force
$receipt = [ordered]@{
  schema = 1
  status = 'PASS'
  setupFile = [IO.Path]::GetFileName($SetupPath)
  setupSha256 = $setupHash
  firstInstallExitCode = $firstInstallExitCode
  reinstallExitCode = $reinstallExitCode
  installedStartupStatus = $startupReceipt.status
  reopenSettingsCount = [int]($startupReceipt.reopenRequestPid -ne $null)
  normalQuitExitCode = $startupReceipt.quitRequestExitCode
  uninstallExitCode = $uninstallProcess.ExitCode
  userDataPreservedOnInstall = $true
  userDataPreservedOnReinstall = $true
  userDataPreservedOnUninstall = $true
  userDataRemovedAfterReceipt = $true
}
$receiptPath = Join-Path $artifacts 'installer-receipt.json'
$receipt | ConvertTo-Json -Depth 5 | Set-Content -Encoding utf8 $receiptPath
$readBack = Get-Content $receiptPath -Raw | ConvertFrom-Json
if ($readBack.status -ne 'PASS' -or $readBack.setupSha256 -ne $setupHash) { throw 'Installer receipt read-back did not match.' }
Write-Output ($receipt | ConvertTo-Json -Compress -Depth 5)
