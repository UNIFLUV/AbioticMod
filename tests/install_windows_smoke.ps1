$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent $PSScriptRoot
$installer = Join-Path $repo 'tools/install-windows.ps1'
$temporary = Join-Path ([IO.Path]::GetTempPath()) ('abiotic-installer-test-' + [Guid]::NewGuid().ToString('N'))
$source = Join-Path $repo 'mods/AbioticSplitScreen'
$target = Join-Path $temporary 'Steam Game/ue4ss/Mods/AbioticSplitScreen'
$backups = Join-Path $temporary 'backups'
$main = Join-Path $target 'Scripts/main.lua'
New-Item -ItemType Directory -Path (Split-Path -Parent $main) -Force | Out-Null
Copy-Item -LiteralPath (Join-Path $source 'Scripts/main.lua') -Destination $main
[IO.File]::WriteAllText((Join-Path $target 'keep.me'), 'Existing custom file')
$installBlock = [scriptblock]::Create([IO.File]::ReadAllText($installer))
& $installBlock -RepositoryRoot $repo -ModPath $target -BackupRoot $backups
foreach ($file in @(Get-ChildItem -LiteralPath $source -Recurse -File)) {
    $dest = Join-Path $target ($file.FullName.Substring($source.Length + 1))
    if ((Get-FileHash -LiteralPath $dest).Hash -ne (Get-FileHash -LiteralPath $file.FullName).Hash) { throw 'Installed file mismatch' }
}
if ([IO.File]::ReadAllText((Join-Path $target 'keep.me')) -ne 'Existing custom file') { throw 'Custom file overwritten' }
$count = @(Get-ChildItem -LiteralPath $backups -Directory).Count
& $installer -RepositoryRoot $repo -ModPath $target -BackupRoot $backups
if (@(Get-ChildItem -LiteralPath $backups -Directory).Count -ne $count) { throw 'Idempotent install created a backup' }
Write-Host 'PASS install, verification, backup, custom-file preservation and repeat installation'
[IO.File]::WriteAllText($main, 'Unknown customized main.lua')
$refused = $false
try { & $installer -RepositoryRoot $repo -ModPath $target -BackupRoot $backups }
catch { $refused = $_.Exception.Message.Contains('Unknown main.lua') }
if (-not $refused -or [IO.File]::ReadAllText($main) -ne 'Unknown customized main.lua') { throw 'Unknown main.lua guard failed' }
Write-Host 'PASS unknown main.lua is refused before changes'
Copy-Item -LiteralPath (Join-Path $source 'Scripts/main.lua') -Destination $main -Force
$child = Join-Path $target 'Scripts/inventory_ui.lua'
[IO.File]::WriteAllText($child, 'Previous child module')
$installerFaultState = @{Injected=$false}
function Copy-Item {
    param([string]$Path,[string]$LiteralPath,[string]$Destination,[switch]$Recurse,[switch]$Force)
    if (-not $installerFaultState.Injected -and $LiteralPath -and $LiteralPath.EndsWith('waypoint_ui.lua')) {
        $installerFaultState.Injected = $true
        throw 'Injected copy failure'
    }
    Microsoft.PowerShell.Management\Copy-Item @PSBoundParameters
}
$rolledBack = $false
try { & $installer -RepositoryRoot $repo -ModPath $target -BackupRoot $backups }
catch { $rolledBack = $_.Exception.Message.Contains('Previous files restored') }
finally { Remove-Item Function:\Copy-Item }
if (-not $installerFaultState.Injected -or -not $rolledBack -or [IO.File]::ReadAllText($child) -ne 'Previous child module') { throw 'Rollback failed' }
Write-Host 'PASS failed copy restores prior files from backup'
Remove-Item -LiteralPath $temporary -Recurse -Force
Write-Host 'Installer smoke checks passed in an isolated temporary folder; the actual game was not run.'
