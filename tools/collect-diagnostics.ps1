param(
    [string]$ModPath = 'C:\Program Files (x86)\Steam\steamapps\common\AbioticFactor\AbioticFactor\Binaries\Win64\ue4ss\Mods\AbioticSplitScreen',
    [string]$SavedPath,
    [string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
if (-not $SavedPath) { $SavedPath = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AbioticFactor\Saved' }
if (-not $OutputDirectory) { $OutputDirectory = [Environment]::GetFolderPath('Desktop') }
if (-not $OutputDirectory) { throw 'Desktop folder unavailable. Specify OutputDirectory.' }
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$tag = [Guid]::NewGuid().ToString('N')
$stage = Join-Path ([IO.Path]::GetTempPath()) ('AbioticSplitScreen-report-' + $tag)
$archive = Join-Path $OutputDirectory ('AbioticSplitScreen-crash-' + $tag + '.zip')
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $ue4ss = Split-Path -Parent (Split-Path -Parent $ModPath)
    $files = @(
        @{ Source=(Join-Path $ue4ss 'UE4SS.log'); Name='UE4SS.log' },
        @{ Source=(Join-Path $SavedPath 'Logs\AbioticFactor.log'); Name='AbioticFactor.log' },
        @{ Source=(Join-Path $ModPath 'Scripts\main.lua'); Name='main.lua' }
    )
    $notes = @('AbioticSplitScreen crash diagnostics. Source files were copied without alteration.')
    $crashes = Join-Path $SavedPath 'Crashes'
    if (Test-Path -LiteralPath $crashes -PathType Container) {
        $latest = Get-ChildItem -LiteralPath $crashes -Filter 'CrashContext.runtime-xml' -File -Recurse |
            Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 1
        if ($latest) {
            $files += @{ Source=$latest.FullName; Name='CrashContext.runtime-xml' }
            $notes += 'CrashContext is the newest available file; it may belong to an earlier run.'
        }
        else { $notes += 'Missing: CrashContext.runtime-xml (no matching crash context found).' }
    }
    else { $notes += 'Missing: crash directory (the game may not have produced a report).' }
    foreach ($file in $files) {
        if (Test-Path -LiteralPath $file.Source -PathType Leaf) {
            Copy-Item -LiteralPath $file.Source -Destination (Join-Path $stage $file.Name)
            $notes += ('Included: ' + $file.Name)
        }
        else { $notes += ('Missing: ' + $file.Name) }
    }
    $notes += 'SaveGames, minidumps and other mods are not included. No file is uploaded automatically.'
    [IO.File]::WriteAllLines((Join-Path $stage 'report.txt'), $notes)
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $archive)
    if (-not (Test-Path -LiteralPath $archive -PathType Leaf)) { throw 'Crash archive was not created.' }
    Write-Host ('Crash report saved: ' + $archive) -ForegroundColor Cyan
    Write-Output $archive
}
finally {
    if (Test-Path -LiteralPath $stage) { Remove-Item -LiteralPath $stage -Recurse -Force }
}
