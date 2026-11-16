# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    Package PDBs from the shipped server build with its identity and SHA-256 hashes.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$PublishPath,
    [Parameter(Mandatory)][string]$Runtime,
    [Parameter(Mandatory)][string]$Version,
    [Parameter(Mandatory)][string]$Commit,
    [Parameter(Mandatory)][ValidateSet("NativeAOT", "SelfContained")][string]$BuildKind,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = "Stop"
foreach ($name in @("Midl.Cli.exe", "Midl.Cli.pdb")) {
    if (-not (Test-Path (Join-Path $PublishPath $name) -PathType Leaf)) {
        throw "Missing $name in $PublishPath. Publish the server with debug symbols enabled."
    }
}

$pdbs = @(Get-ChildItem $PublishPath -File -Filter "*.pdb" | Sort-Object Name)
$manifest = [ordered]@{
    version = $Version
    commit = $Commit
    runtime = $Runtime
    buildKind = $BuildKind
    executable = @{
        name = "Midl.Cli.exe"
        sha256 = (Get-FileHash (Join-Path $PublishPath "Midl.Cli.exe") -Algorithm SHA256).Hash
    }
    symbols = @($pdbs | ForEach-Object {
        @{ name = $_.Name; sha256 = (Get-FileHash $_.FullName -Algorithm SHA256).Hash }
    })
}

$OutputPath = [IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath) | Out-Null
$stream = [IO.File]::Create($OutputPath)
try {
    $zip = [IO.Compression.ZipArchive]::new($stream, [IO.Compression.ZipArchiveMode]::Create, $true)
    try {
        foreach ($pdb in $pdbs) {
            [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $pdb.FullName, $pdb.Name) | Out-Null
        }
        $entry = $zip.CreateEntry("manifest.json")
        $writer = [IO.StreamWriter]::new($entry.Open())
        try { $writer.Write(($manifest | ConvertTo-Json -Depth 4)) } finally { $writer.Dispose() }
    } finally { $zip.Dispose() }
} finally { $stream.Dispose() }

Write-Host "Packaged $($pdbs.Count) PDB(s) for $Runtime ($BuildKind): $OutputPath"
