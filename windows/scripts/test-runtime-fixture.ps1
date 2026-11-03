$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$resultDir = Join-Path $root 'windows\artifacts'
New-Item -ItemType Directory -Force -Path $resultDir | Out-Null
$env:MACSWITCHER_WINDOWS_EXE = Join-Path $root 'windows\src\MacSwitcher.Windows\bin\Release\net462\MacSwitcher.Windows.exe'
$output = & dotnet run -c Release --project (Join-Path $root 'windows\tests\MacSwitcher.Runtime.Tests\MacSwitcher.Runtime.Tests.csproj') 2>&1
$exitCode = $LASTEXITCODE
$output | ForEach-Object { Write-Output $_ }
$resultLine = $output | Where-Object { $_ -match '^\{"status":"(PASS|FAIL|NOT_RUN)"' } | Select-Object -Last 1
if (-not $resultLine) { throw 'Runtime fixture did not produce a closed status receipt.' }
$resultPath = Join-Path $resultDir 'runtime-fixture.json'
Set-Content -Path $resultPath -Value $resultLine -Encoding utf8
$result = $resultLine | ConvertFrom-Json
if ($exitCode -ne 0 -or $result.status -ne 'PASS') { throw "Runtime fixture was not accepted: $resultLine" }
Write-Output "Runtime fixture receipt saved: $resultPath ($($result.status))"
