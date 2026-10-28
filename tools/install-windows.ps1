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
        if ($matched) { Write-Host 'v0.8.3 container-action context trial already installed.' -ForegroundColor Green; return }
    }
    if ($oldHash -notin @($sourceHash, 'f471c7d37a55e15a032152ad124491a407152a4285e170b78601dda6fe3e7858', 'b2ab35283ea3fcbca892e591cd295b888ce5536aa43ca7ad950491c6676f17a8', 'b6be7be81d721c1a28b9fa252f86d04cbe448db3a1a460a1b1ad88d9b2285d8b', 'f3650148c4b3f93035c5af7c3176b4d663d56b2b5de0a6288bc1f07f07d63fd9', 'a6442e3d72410596d91fc18ac059b2afd108840332e23bdaedb2f377ee79c257', 'e311d4e9aaec25d7777aae534b3fa48533a3e7c2cef8f953d7525fc6aafa595f', 'd4aeff2c592816aab7057227974335d442a0f174108df382240ddfa7914b7553', '74ef6062b9e6a7688644992db01837221b344c329a35e6c8935e05d43804b72e')) {
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
Write-Host 'Updated to v0.8.3 container-action context trial. Native v0.8 hooks remain disabled. Restart fully. F1, wait, F2, E on container, then test Take All/F and inspect both inventories. Send UE4SS.log.' -ForegroundColor Green
