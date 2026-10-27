param(
    [Parameter(Mandatory=$true)][string]$RepositoryRoot,
    [string]$ModPath = 'C:\Program Files (x86)\Steam\steamapps\common\AbioticFactor\AbioticFactor\Binaries\Win64\ue4ss\Mods\AbioticSplitScreen',
    [string]$BackupRoot
)
$ErrorActionPreference = 'Stop'
if (Get-Process -Name 'AbioticFactor-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'Close Abiotic Factor first.' }
$source = Join-Path $RepositoryRoot 'mods\AbioticSplitScreen'
$sourceMain = Join-Path $source 'Scripts\main.lua'
if (-not (Test-Path -LiteralPath $sourceMain -PathType Leaf)) { throw 'Source archive is incomplete.' }
if (-not (Test-Path -LiteralPath (Split-Path -Parent $ModPath) -PathType Container)) { throw 'UE4SS Mods folder not found.' }
$main = Join-Path $ModPath 'Scripts\main.lua'
$sourceHash = (Get-FileHash -LiteralPath $sourceMain -Algorithm SHA256).Hash
$sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -File)
if (Test-Path -LiteralPath $main -PathType Leaf) {
    $oldHash = (Get-FileHash -LiteralPath $main -Algorithm SHA256).Hash
    if ($oldHash -eq $sourceHash) {
        $matched = $true
        foreach ($file in $sourceFiles) {
            $target = Join-Path $ModPath ($file.FullName.Substring($source.Length + 1))
            if (-not (Test-Path -LiteralPath $target -PathType Leaf)) { $matched=$false; break }
            if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) { $matched=$false; break }
        }
        if ($matched) { Write-Host 'v0.7.4 already installed.' -ForegroundColor Green; return }
    }
    if ($oldHash -notin @($sourceHash, '74ef6062b9e6a7688644992db01837221b344c329a35e6c8935e05d43804b72e')) {
        throw 'Unknown main.lua version. Nothing changed; send the current file.'
    }
}
$backup = $null
if (Test-Path -LiteralPath $ModPath -PathType Container) {
    $backupParent = $BackupRoot
    if (-not $backupParent) { $backupParent = Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'AbioticSplitScreenBackups' }
    New-Item -ItemType Directory -Path $backupParent -Force | Out-Null
    $backup = Join-Path $backupParent ([Guid]::NewGuid().ToString('N'))
    Copy-Item -LiteralPath $ModPath -Destination $backup -Recurse
    Write-Host ('Backup: ' + $backup)
}
try {
    New-Item -ItemType Directory -Path $ModPath -Force | Out-Null
    foreach ($file in $sourceFiles) {
        $target = Join-Path $ModPath ($file.FullName.Substring($source.Length + 1))
        New-Item -ItemType Directory -Path (Split-Path -Parent $target) -Force | Out-Null
        Copy-Item -LiteralPath $file.FullName -Destination $target -Force
        if ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash) {
            throw ('File verification failed: ' + $file.Name)
        }
    }
}
catch {
    $reason = $_.Exception.Message
    if ($backup) {
        try { Copy-Item -Path (Join-Path $backup '*') -Destination $ModPath -Recurse -Force }
        catch { throw ('Install/restore failed. Backup: ' + $backup + '. ' + $reason) }
        throw ('Previous files restored. ' + $reason)
    }
    throw
}
Write-Host 'Updated to v0.7.4. F1, wait, F2. Test Tab/Esc and quest marker. Send UE4SS.log.' -ForegroundColor Green
