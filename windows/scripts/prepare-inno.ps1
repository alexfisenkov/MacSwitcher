$ErrorActionPreference = 'Stop'
$expected = '6.7.4'

function Get-InnoCompilerVersion([string]$Path) {
  $probeDir = Join-Path $env:TEMP ('MacSwitcher-Inno-Version-' + [Guid]::NewGuid().ToString('N'))
  New-Item -ItemType Directory -Path $probeDir | Out-Null
  $probeScript = Join-Path $probeDir 'version-probe.iss'
  @'
[Setup]
AppId={{CB55DC8F-B8D0-4E2C-B5B0-A5596E504F0D}
AppName=InnoVersionProbe
AppVersion=1.0
DefaultDirName={tmp}\InnoVersionProbe
'@ | Set-Content -Encoding ASCII $probeScript
  try {
    # Inno Setup 6.7.4 rejects --version. Its supported compiler output reports
    # the engine version during a real compile; /O- disables all package output.
    $output = @(& $Path '/O-' $probeScript 2>&1)
    $result = $LASTEXITCODE
    $summary = (@($output | Select-Object -Last 6 | ForEach-Object {
      $line = $_.ToString()
      if ($line.Length -gt 300) { $line.Substring(0, 300) } else { $line }
    }) -join ' | ')
    if ($result -ne 0) { throw "ISCC version probe failed with exit code $result. Output: $summary" }
    $versions = @($output | ForEach-Object {
      $match = [regex]::Match($_.ToString(), '^Compiler engine version:\s+Inno Setup\s+(\d+\.\d+\.\d+)\s*$')
      if ($match.Success) { $match.Groups[1].Value }
    } | Where-Object { $_ })
    if ($versions.Count -ne 1) { throw "ISCC version probe did not return exactly one compiler engine version. Output: $summary" }
    return $versions[0]
  }
  finally { Remove-Item $probeDir -Recurse -Force -ErrorAction SilentlyContinue }
}

function Test-TrustedInnoCompiler([string]$Path) {
  $candidateSignature = Get-AuthenticodeSignature $Path
  return $candidateSignature.Status -eq 'Valid' -and $candidateSignature.SignerCertificate.Subject -match 'Pyrsys B\.V\.'
}

$candidates = @(
  (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) }

$compiler = $null
foreach ($candidate in $candidates) {
  try {
    if ((Test-TrustedInnoCompiler $candidate) -and (Get-InnoCompilerVersion $candidate) -eq $expected) { $compiler = $candidate; break }
  } catch { }
}

$receiptDir = Join-Path $PSScriptRoot '..\artifacts'
New-Item -ItemType Directory -Force -Path $receiptDir | Out-Null
if (-not $compiler) {
  $installer = Join-Path $env:TEMP 'innosetup-6.7.4.exe'
  Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_4/innosetup-6.7.4.exe' -OutFile $installer
  $signature = Get-AuthenticodeSignature $installer
  if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
    throw "Official Inno Setup signature verification failed: $($signature.Status)"
  }
  Start-Process -FilePath $installer -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART' -Wait
  $compiler = Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'
  if (-not (Test-Path $compiler)) { $compiler = Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe' }
}

if (-not (Test-Path $compiler)) { throw 'Inno Setup 6.7.4 ISCC.exe was not found after setup.' }
$signature = Get-AuthenticodeSignature $compiler
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
  throw "Inno Setup compiler signature verification failed: $($signature.Status)"
}
$actual = Get-InnoCompilerVersion $compiler
if ($actual -ne $expected) { throw "Expected Inno Setup $expected, found $actual" }
$receipt = [ordered]@{
  tool = 'Inno Setup'
  version = $actual
  compiler = $compiler
  signatureStatus = $signature.Status.ToString()
  signer = $signature.SignerCertificate.Subject
  officialRelease = 'https://github.com/jrsoftware/issrc/releases/tag/is-6_7_4'
  sha256 = (Get-FileHash $compiler -Algorithm SHA256).Hash.ToLowerInvariant()
}
$receipt | ConvertTo-Json -Depth 4 | Set-Content -Encoding utf8 (Join-Path $receiptDir 'inno-setup-receipt.json')
Write-Output ($receipt | ConvertTo-Json -Compress)
