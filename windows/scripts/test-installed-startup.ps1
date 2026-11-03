param([Parameter(Mandatory=$true)][string]$ExePath)
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes
Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;

public static class MacSwitcherCommandLine
{
    [DllImport("shell32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern IntPtr CommandLineToArgvW(string commandLine, out int argumentCount);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern IntPtr LocalFree(IntPtr memory);

    public static string[] Split(string commandLine)
    {
        int count;
        IntPtr argv = CommandLineToArgvW(commandLine, out count);
        if (argv == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        try
        {
            string[] result = new string[count];
            for (int i = 0; i < count; i++)
            {
                IntPtr value = Marshal.ReadIntPtr(argv, i * IntPtr.Size);
                result[i] = Marshal.PtrToStringUni(value) ?? String.Empty;
            }
            return result;
        }
        finally { LocalFree(argv); }
    }
}
'@

$exe = (Resolve-Path $ExePath).Path
$resultPath = Join-Path $PSScriptRoot '..\artifacts\installed-startup.json'
New-Item -ItemType Directory -Force -Path (Split-Path $resultPath) | Out-Null
$stage = 'resolve'
$primary = $null
$reopenProcessId = $null
$reopenedWindows = 0
$checkedLabels = @()
$quitExitCode = $null
$reopenWindowCount = 0
$sameProductProcessCount = 0
$primaryProcessCount = 0
$nonBrokerProcessCount = 0
$automationBrokerCount = 0
$ownedBrokerCount = 0
$unownedBrokerCount = 0

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

function Test-AutomationBrokerProcess($ProcessInfo) {
  $arguments = [MacSwitcherCommandLine]::Split([string]$ProcessInfo.CommandLine)
  return $arguments -contains '--automation-broker'
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
    'Исправлять раскладку автоматически',
    'Запоминать мои исправления на этом компьютере',
    'При неоднозначном слове предпочитать русский',
    'Сохранять правильные слова в выделении'
  )
  foreach ($label in $expected) { if ($checkedLabels -notcontains $label) { throw 'Expected settings control was not visible.' } }
  Close-OwnedWindow $settings

  $stage = 'reopen-request'
  $reopen = Start-Process -FilePath $exe -ArgumentList '--settings' -PassThru -Wait
  $reopenProcessId = $reopen.Id
  if ($reopen.ExitCode -ne 0) { throw 'Duplicate settings request failed.' }
  $stage = 'reopen-window'
  $settingsAgain = Wait-OwnedWindow $primary.Id 'Настройки MacSwitcher'
  $reopenedWindows++
  $reopenWindowCount = $reopenedWindows
  Close-OwnedWindow $settingsAgain
  Start-Sleep -Milliseconds 300

  $stage = 'process-inventory'
  $canonicalExe = [IO.Path]::GetFullPath($exe)
  $sameProductProcesses = @(Get-CimInstance Win32_Process -Filter "Name='MacSwitcher.Windows.exe'" |
    Where-Object { $_.ExecutablePath -and [IO.Path]::GetFullPath($_.ExecutablePath) -ieq $canonicalExe })
  $sameProductProcessCount = $sameProductProcesses.Count
  $stage = 'primary-count'
  $primaryProcessCount = @($sameProductProcesses | Where-Object { $_.ProcessId -eq $primary.Id }).Count
  if ($primaryProcessCount -ne 1) { throw 'The installed primary process was not present in the process inventory.' }

  $stage = 'broker-parent'
  foreach ($processInfo in $sameProductProcesses) {
    if ($processInfo.ProcessId -eq $primary.Id) { continue }
    if (Test-AutomationBrokerProcess $processInfo) {
      $automationBrokerCount++
      if ($processInfo.ParentProcessId -eq $primary.Id) { $ownedBrokerCount++ }
      else { $unownedBrokerCount++ }
    } else { $nonBrokerProcessCount++ }
  }
  if ($nonBrokerProcessCount -ne 0 -or $unownedBrokerCount -ne 0 -or $ownedBrokerCount -gt 1) {
    throw 'Reopening settings created an unexpected app process or unowned automation broker.'
  }

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
    reopenWindowCount = $reopenWindowCount
    sameProductProcessCount = $sameProductProcessCount
    primaryProcessCountAfterReopen = $primaryProcessCount
    nonBrokerProcessCount = $nonBrokerProcessCount
    automationBrokerCount = $automationBrokerCount
    ownedAutomationBrokerCount = $ownedBrokerCount
    unownedAutomationBrokerCount = $unownedBrokerCount
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
    reopenWindowCount = $reopenWindowCount
    sameProductProcessCount = $sameProductProcessCount
    primaryProcessCount = $primaryProcessCount
    nonBrokerProcessCount = $nonBrokerProcessCount
    automationBrokerCount = $automationBrokerCount
    ownedAutomationBrokerCount = $ownedBrokerCount
    unownedAutomationBrokerCount = $unownedBrokerCount
    quitRequestExitCode = $quitExitCode
  }
  $receipt | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 $resultPath
  Write-Output ($receipt | ConvertTo-Json -Compress -Depth 4)
  throw "Installed startup smoke failed at stage '$stage'."
}
