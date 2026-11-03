param(
  [string]$Configuration = 'Release',
  [string]$InnoCompiler = ''
)
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$publish = Join-Path $root 'windows\publish'
$data = Join-Path $root 'windows\data'
$artifacts = Join-Path $root 'windows\artifacts'
$csproj = Join-Path $root 'windows\src\MacSwitcher.Windows\MacSwitcher.Windows.csproj'
$versionFile = Join-Path $root 'windows\version.json'

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
  $signature = Get-AuthenticodeSignature $Path
  return $signature.Status -eq 'Valid' -and $signature.SignerCertificate.Subject -match 'Pyrsys B\.V\.'
}

$gitStatus = @(git -C $root status --porcelain=v1 --untracked-files=all)
if ($LASTEXITCODE -ne 0) { throw 'Unable to verify the source revision before packaging.' }
if ($gitStatus.Count -ne 0) { throw 'Packaging requires a clean Git worktree; commit or otherwise resolve source changes before building packages.' }
if (-not (Test-Path $data)) { throw 'Run build-data.py before packaging.' }
if (-not (Test-Path (Join-Path $root 'windows\assets\MacSwitcher.ico'))) { throw 'Run extract-icon.py before packaging.' }
Remove-Item $publish -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Force -Path $publish,$artifacts | Out-Null
$version = Get-Content $versionFile -Raw | ConvertFrom-Json
if ([int]$version.build -lt 1) { throw 'Windows build number must be positive.' }
$fileVersion = "0.1.$($version.build).0"
$infoVersion = "$($version.version)+build.$($version.build)"
dotnet publish $csproj -c $Configuration -o $publish /p:Platform=AnyCPU "/p:FileVersion=$fileVersion" "/p:InformationalVersion=$infoVersion"
if ($LASTEXITCODE -ne 0) { throw "dotnet publish failed: $LASTEXITCODE" }
$sourceDictionaryManifest = Join-Path $data 'dictionary-manifest.json'
$publishedDictionaryManifest = Join-Path $publish 'data\dictionary-manifest.json'
if (-not (Test-Path $publishedDictionaryManifest)) { throw 'dotnet publish did not include the generated dictionary bundle.' }
$sourceDictionaryHash = (Get-FileHash $sourceDictionaryManifest -Algorithm SHA256).Hash.ToLowerInvariant()
$publishedDictionaryHash = (Get-FileHash $publishedDictionaryManifest -Algorithm SHA256).Hash.ToLowerInvariant()
if ($sourceDictionaryHash -ne $publishedDictionaryHash) { throw 'Published dictionary manifest differs from the verified generated data.' }
Copy-Item (Join-Path $root 'windows\assets\MacSwitcher.ico') $publish
Copy-Item (Join-Path $root 'windows\README.md') $publish
Copy-Item (Join-Path $root 'LICENSE') $publish
Copy-Item (Join-Path $root 'NOTICE.md') $publish
$portableName = "MacSwitcher-Windows-$($version.version)-portable.zip"
$portablePath = Join-Path $artifacts $portableName
Compress-Archive -Path (Join-Path $publish '*') -DestinationPath $portablePath -Force

if (-not $InnoCompiler) {
  $compilerCandidates = @()
  if (${env:ProgramFiles(x86)}) { $compilerCandidates += Join-Path ${env:ProgramFiles(x86)} 'Inno Setup 6\ISCC.exe' }
  if ($env:LOCALAPPDATA) { $compilerCandidates += Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe' }
  foreach ($candidate in $compilerCandidates) {
    if (Test-Path $candidate) {
      try {
        if ((Test-TrustedInnoCompiler $candidate) -and (Get-InnoCompilerVersion $candidate) -eq '6.7.4') { $InnoCompiler = $candidate; break }
      } catch { }
    }
  }
}
if (-not (Test-Path $InnoCompiler)) { throw "ISCC compiler not found: $InnoCompiler" }
$compilerSignature = Get-AuthenticodeSignature $InnoCompiler
if ($compilerSignature.Status -ne 'Valid' -or $compilerSignature.SignerCertificate.Subject -notmatch 'Pyrsys B\.V\.') {
  throw "Inno Setup compiler signature verification failed: $($compilerSignature.Status)"
}
$compilerVersion = Get-InnoCompilerVersion $InnoCompiler
if ($compilerVersion -ne '6.7.4') { throw "Packaging requires verified Inno Setup 6.7.4, found $compilerVersion" }
$versionDefine = '/DAppVersion="' + $version.version + '"'
& $InnoCompiler $versionDefine (Join-Path $root 'windows\installer\MacSwitcher.iss')
if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed: $LASTEXITCODE" }

$setup = Join-Path $artifacts "MacSwitcher-Windows-$($version.version)-Setup.exe"
$sourceRevision = (git -C $root rev-parse HEAD).Trim()
$sourceSha256 = (& python (Join-Path $root 'windows\scripts\source-digest.py') --revision $sourceRevision)
if ($LASTEXITCODE -ne 0) { throw "Canonical source digest failed: $LASTEXITCODE" }
$sourceSha256 = ($sourceSha256 -join '').Trim()
if ($sourceSha256 -cnotmatch '^[0-9a-f]{64}$') { throw 'Canonical source digest must be exactly 64 lowercase hexadecimal characters.' }
$metadata = [ordered]@{
  schema = 1
  version = $version.version
  build = $version.build
  tag = $version.tag
  platform = 'windows'
  sourceRevision = $sourceRevision
  sourceSha256 = $sourceSha256
  sourceDirty = $false
  dictionaryManifestSha256 = (Get-FileHash (Join-Path $data 'dictionary-manifest.json') -Algorithm SHA256).Hash.ToLowerInvariant()
  ciOs = $env:ImageOS
  ciImageVersion = $env:ImageVersion
  innoSetup = @{ version = $compilerVersion; executable = (Resolve-Path $InnoCompiler).Path }
  signed = $false
  packages = @{}
}
foreach ($path in @($portablePath,$setup)) {
  if (-not (Test-Path $path)) { throw "Expected package not created: $path" }
  $hash = Get-FileHash $path -Algorithm SHA256
  $metadata.packages[[IO.Path]::GetFileName($path)] = @{ sha256 = $hash.Hash.ToLowerInvariant(); size = (Get-Item $path).Length }
}
$metadata | ConvertTo-Json -Depth 6 | Set-Content -Encoding utf8 (Join-Path $artifacts 'package-manifest.json')
Write-Output ($metadata | ConvertTo-Json -Compress -Depth 6)
