$ErrorActionPreference = 'Stop'
$expected = '6.7.4'
$candidates = @(
  (Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe'),
  (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe')
) | Where-Object { $_ -and (Test-Path $_) }

$compiler = $null
foreach ($candidate in $candidates) {
  $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($candidate).FileVersion
  if ($version -match '^6\.7\.4(\.0)?$') { $compiler = $candidate; break }
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
$actual = [Diagnostics.FileVersionInfo]::GetVersionInfo($compiler).FileVersion
if ($actual -notmatch '^6\.7\.4(\.0)?$') { throw "Expected Inno Setup $expected, found $actual" }
$signature = Get-AuthenticodeSignature $compiler
if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
  throw "Inno Setup compiler signature verification failed: $($signature.Status)"
}
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
