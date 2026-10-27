& {
$ErrorActionPreference = 'Stop'
$win64 = 'C:\Program Files (x86)\Steam\steamapps\common\AbioticFactor\AbioticFactor\Binaries\Win64'
$file = Join-Path $win64 'ue4ss\Mods\AbioticSplitScreen\Scripts\main.lua'
if (Get-Process -Name 'AbioticFactor-Win64-Shipping' -ErrorAction SilentlyContinue) { throw 'Close the game and crash dialog first.' }
if (-not (Test-Path -LiteralPath $file -PathType Leaf)) { throw 'main.lua not found; nothing changed.' }
$tag = [Guid]::NewGuid().ToString('N')
$report = Join-Path ([IO.Path]::GetTempPath()) ('AbioticSplitScreen-crash-' + $tag)
New-Item -ItemType Directory -Path $report | Out-Null
Copy-Item -LiteralPath $file -Destination (Join-Path $report 'main.lua')
$saved = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'AbioticFactor\Saved'
$logs = @((Join-Path $win64 'ue4ss\UE4SS.log'), (Join-Path $saved 'Logs\AbioticFactor.log'))
foreach ($path in $logs) {
    if (Test-Path -LiteralPath $path -PathType Leaf) { Copy-Item -LiteralPath $path -Destination $report }
    else { Write-Warning ('Log missing: ' + $path) }
}
$crashes = Join-Path $saved 'Crashes'
if (Test-Path -LiteralPath $crashes -PathType Container) {
    $crash = Get-ChildItem -LiteralPath $crashes -Filter 'CrashContext.runtime-xml' -File -Recurse | Sort-Object LastWriteTime -Descending | Select-Object -First 1
    if ($crash) { Copy-Item -LiteralPath $crash.FullName -Destination $report }
}
$desktop = [Environment]::GetFolderPath('Desktop')
if (-not $desktop) { $desktop = [Environment]::GetFolderPath('UserProfile') }
$zip = Join-Path $desktop ('AbioticSplitScreen-crash-' + $tag.Substring(0,8) + '.zip')
Compress-Archive -Path (Join-Path $report '*') -DestinationPath $zip
Write-Host ('SEND THIS ZIP: ' + $zip) -ForegroundColor Cyan
$v6 = 'd81da0c55b2f72ed1ca6c48bf7bdb6ada3d5afcc760bbd022218425a1ea657b7'
$v7 = 'dfa4191fd7645a8237d1c100a1937e72a8745cc358c3606a4887d13a276998b6'
$hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
if ($hash -eq $v6) { Write-Host 'v0.6 already installed.'; return }
if ($hash -ne $v7) { throw 'Unknown main.lua version. Report saved; mod unchanged. Send the ZIP.' }
$backup = Get-ChildItem -LiteralPath (Split-Path -Parent $file) -Filter 'main.lua.backup-*' -File | Where-Object {
    (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() -eq $v6
} | Select-Object -First 1
if (-not $backup) { throw 'Verified v0.6 backup missing. Report saved; mod unchanged. Send the ZIP.' }
$failed = $file + '.crash-v07-' + $tag
Copy-Item -LiteralPath $file -Destination $failed
Copy-Item -LiteralPath $backup.FullName -Destination $file -Force
if ((Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant() -ne $v6) {
    Copy-Item -LiteralPath $failed -Destination $file -Force
    throw 'Rollback verification failed; previous file restored. Send the ZIP.'
}
Write-Host 'Restored v0.6. Send the ZIP before another game test.' -ForegroundColor Green
}
