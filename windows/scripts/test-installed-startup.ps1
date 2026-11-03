param([Parameter(Mandatory=$true)][string]$ExePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$exe = (Resolve-Path $ExePath).Path
$resultPath = Join-Path $PSScriptRoot '..\artifacts\installed-startup.json'
New-Item -ItemType Directory -Force -Path (Split-Path $resultPath) | Out-Null
$stage = 'resolve'
$primary = $null
$reopenProcessId = $null
$reopenedWindows = 0
$checkedLabels = @()
$quitExitCode = $null

function Get-OwnedWindow([int]$ProcessId, [string]$Name) {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $condition = New-Object System.Windows.Automation.PropertyCondition(
    [System.Windows.Automation.AutomationElement]::ProcessIdProperty, $ProcessId)
  $windows = $root.FindAll([System.Windows.Automation.TreeScope]::Children, $condition)
  foreach ($window in $windows) {
    $current = $window.Current
    if ($current.ControlType -eq [System.Windows.Automation.ControlType]::Window -and $current.Name -eq $Name) { return $window }
  }
  return $null
}

function Wait-OwnedWindow([int]$ProcessId, [string]$Name, [int]$TimeoutSeconds = 25) {
  $until = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
  do {
    $window = Get-OwnedWindow $ProcessId $Name
    if ($window) { return $window }
    Start-Sleep -Milliseconds 100
  } while ([DateTime]::UtcNow -lt $until)
  throw 'Expected application window did not appear.'
}

function Close-OwnedWindow($Window) {
  $pattern = $Window.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
  $pattern.Close()
}

function Acknowledge-OwnedWelcome($Window) {
  $buttons = $Window.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::Button)))
  foreach ($button in $buttons) {
    if ($button.Current.Name -in @('OK', 'ОК')) {
      $invoke = $button.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern)
      $invoke.Invoke()
      return
    }
  }
  throw 'Welcome dialog button was not available through UI Automation.'
}

function Send-NormalQuit([string]$Path) {
  $request = Start-Process -FilePath $Path -ArgumentList '--quit' -Wait -PassThru
  return $request.ExitCode
}

try {
  $stage = 'first-launch'
  $primary = Start-Process -FilePath $exe -ArgumentList '--settings' -PassThru
  $welcome = Wait-OwnedWindow $primary.Id 'Добро пожаловать в MacSwitcher'
  Acknowledge-OwnedWelcome $welcome
  $settings = Wait-OwnedWindow $primary.Id 'Настройки MacSwitcher'
  $checkboxes = $settings.FindAll([System.Windows.Automation.TreeScope]::Descendants,
    (New-Object System.Windows.Automation.PropertyCondition(
      [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
      [System.Windows.Automation.ControlType]::CheckBox)))
  $checkedLabels = @($checkboxes | ForEach-Object { $_.Current.Name })
  $expected = @(
    'Включить обработку Shift',
    'Исправлять слово при двойном Shift',
    'При неоднозначном слове предпочитать русский',
    'Сохранять правильные слова в выделении'
  )
  foreach ($label in $expected) { if ($checkedLabels -notcontains $label) { throw 'Expected settings control was not visible.' } }
  Close-OwnedWindow $settings

  $stage = 'reopen-settings'
  $reopen = Start-Process -FilePath $exe -ArgumentList '--settings' -PassThru -Wait
  $reopenProcessId = $reopen.Id
  if ($reopen.ExitCode -ne 0) { throw 'Duplicate settings request failed.' }
  $settingsAgain = Wait-OwnedWindow $primary.Id 'Настройки MacSwitcher'
  $reopenedWindows++
  Close-OwnedWindow $settingsAgain
  Start-Sleep -Milliseconds 300
  $canonicalExe = [IO.Path]::GetFullPath($exe)
  $sameProductProcesses = @(Get-CimInstance Win32_Process -Filter "Name='MacSwitcher.Windows.exe'" |
    Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $canonicalExe })
  if ($sameProductProcesses.Count -ne 1 -or $sameProductProcesses[0].ProcessId -ne $primary.Id) { throw 'Reopening settings created an unexpected app process.' }

  $stage = 'normal-exit'
  $quitExitCode = Send-NormalQuit $exe
  if ($quitExitCode -ne 0) { throw 'Normal quit request failed.' }
  if (-not $primary.WaitForExit(15000)) { throw 'Primary app did not exit normally.' }

  $receipt = [ordered]@{
    schema = 1
    status = 'PASS'
    stages = @('first-launch', 'settings-controls', 'reopen-settings', 'single-primary-process', 'normal-exit')
    primaryPid = $primary.Id
    reopenRequestPid = $reopenProcessId
    primaryProcessCountAfterReopen = $sameProductProcesses.Count
    quitRequestExitCode = $quitExitCode
    controls = $expected
  }
  $receipt | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $resultPath
  Write-Output ($receipt | ConvertTo-Json -Compress -Depth 4)
}
catch {
  if ($primary -and -not $primary.HasExited) {
    try {
      $quitExitCode = Send-NormalQuit $exe
      $null = $primary.WaitForExit(10000)
    } catch { }
  }
  $receipt = [ordered]@{
    schema = 1
    status = 'FAIL'
    stage = $stage
    primaryPid = if ($primary) { $primary.Id } else { $null }
    reopenRequestPid = $reopenProcessId
    quitRequestExitCode = $quitExitCode
  }
  $receipt | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $resultPath
  Write-Output ($receipt | ConvertTo-Json -Compress -Depth 4)
  throw "Installed startup smoke failed at stage '$stage'."
}
