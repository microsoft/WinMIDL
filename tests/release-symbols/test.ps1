# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

$ErrorActionPreference = "Stop"
$packageScript = Join-Path $PSScriptRoot "..\..\scripts\package-symbols.ps1"
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("winmidl-symbol-tests-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $testRoot | Out-Null
$failures = 0

function Test-Case([string]$Name, [scriptblock]$Body) {
    try {
        & $Body
        Write-Host "PASS: $Name"
    } catch {
        $script:failures++
        Write-Host "FAIL: ${Name}: $_"
    }
}

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

try {
    foreach ($kind in @("NativeAOT", "SelfContained")) {
        Test-Case "Packages matching $kind symbols without binaries" {
            $publish = Join-Path $testRoot $kind
            New-Item -ItemType Directory -Path $publish | Out-Null
            Set-Content (Join-Path $publish "Midl.Cli.exe") "executable fixture"
            Set-Content (Join-Path $publish "Midl.Cli.pdb") "server symbols"
            if ($kind -eq "SelfContained") {
                Set-Content (Join-Path $publish "Midl.Analysis.pdb") "analysis symbols"
            }
            $output = Join-Path $testRoot "$kind.zip"
            & $packageScript -PublishPath $publish -Runtime win-x64 -Version 0.1.20 `
                -Commit abc123 -BuildKind $kind -OutputPath $output

            $zip = [IO.Compression.ZipFile]::OpenRead($output)
            try {
                $expectedCount = if ($kind -eq "NativeAOT") { 2 } else { 3 }
                Assert-True ($zip.Entries.Count -eq $expectedCount) "Unexpected archive contents"
                Assert-True ($null -eq $zip.GetEntry("Midl.Cli.exe")) "Executable leaked into symbol archive"
                $reader = [IO.StreamReader]::new($zip.GetEntry("manifest.json").Open())
                try { $manifest = $reader.ReadToEnd() | ConvertFrom-Json } finally { $reader.Dispose() }
                Assert-True ($manifest.version -eq "0.1.20" -and $manifest.commit -eq "abc123" -and
                    $manifest.runtime -eq "win-x64" -and $manifest.buildKind -eq $kind) "Build identity was lost"
                Assert-True ($manifest.executable.sha256 -eq
                    (Get-FileHash (Join-Path $publish "Midl.Cli.exe") -Algorithm SHA256).Hash) "Wrong executable hash"
                foreach ($symbol in $manifest.symbols) {
                    $reader = [IO.StreamReader]::new($zip.GetEntry($symbol.name).Open())
                    try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
                    Assert-True ($text -eq (Get-Content (Join-Path $publish $symbol.name) -Raw)) "Symbol contents changed"
                    Assert-True ($symbol.sha256 -eq
                        (Get-FileHash (Join-Path $publish $symbol.name) -Algorithm SHA256).Hash) "Wrong symbol hash"
                }
                Assert-True (Test-Path (Join-Path $publish "Midl.Cli.pdb")) "Packaging removed original symbols"
            } finally { $zip.Dispose() }
        }
    }

    foreach ($missing in @("Midl.Cli.exe", "Midl.Cli.pdb")) {
        Test-Case "Rejects missing $missing" {
            $publish = Join-Path $testRoot ("missing-" + $missing)
            New-Item -ItemType Directory -Path $publish | Out-Null
            $present = if ($missing -eq "Midl.Cli.exe") { "Midl.Cli.pdb" } else { "Midl.Cli.exe" }
            Set-Content (Join-Path $publish $present) "fixture"
            $output = Join-Path $testRoot "$missing.zip"
            $message = ""
            try {
                & $packageScript -PublishPath $publish -Runtime win-arm64 -Version 0.1.20 `
                    -Commit abc123 -BuildKind NativeAOT -OutputPath $output
            } catch { $message = $_.Exception.Message }
            Assert-True ($message.Contains("Missing $missing")) "Expected explicit missing-file failure, got: $message"
            Assert-True (-not (Test-Path $output)) "Failure left a success-shaped archive"
        }
    }
} finally {
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}

if ($failures -ne 0) { throw "$failures release symbol tests failed" }
