$ErrorActionPreference='Stop'
$repo=Split-Path -Parent $PSScriptRoot
$collector=Join-Path $repo 'tools/collect-diagnostics.ps1'
$work=Join-Path ([IO.Path]::GetTempPath()) ('abiotic-report-test-'+[Guid]::NewGuid().ToString('N'))
$mod=Join-Path $work 'Steam Game/ue4ss/Mods/AbioticSplitScreen'
$saved=Join-Path $work 'Saved'
$out=Join-Path $work 'Desktop'
$ue4ss=Split-Path -Parent (Split-Path -Parent $mod)
New-Item -ItemType Directory -Path (Join-Path $mod 'Scripts'),(Join-Path $saved 'Logs'),(Join-Path $saved 'Crashes/old'),(Join-Path $saved 'Crashes/new'),(Join-Path $saved 'SaveGames') -Force | Out-Null
[IO.File]::WriteAllText((Join-Path $ue4ss 'UE4SS.log'),'UE4SS crash fixture')
[IO.File]::WriteAllText((Join-Path $saved 'Logs/AbioticFactor.log'),'Game crash fixture')
[IO.File]::WriteAllText((Join-Path $mod 'Scripts/main.lua'),'Installed mod fixture')
[IO.File]::WriteAllText((Join-Path $saved 'Crashes/old/CrashContext.runtime-xml'),'<old/>')
[IO.File]::WriteAllText((Join-Path $saved 'Crashes/new/CrashContext.runtime-xml'),'<new/>')
[IO.File]::SetLastWriteTimeUtc((Join-Path $saved 'Crashes/old/CrashContext.runtime-xml'),[DateTime]::UtcNow.AddDays(-1))
[IO.File]::WriteAllText((Join-Path $saved 'SaveGames/private.sav'),'Excluded save')
[IO.File]::WriteAllText((Join-Path $saved 'Crashes/new/minidump.dmp'),'Excluded dump')
$block=[scriptblock]::Create([IO.File]::ReadAllText($collector))
$archive=& $block -ModPath $mod -SavedPath $saved -OutputDirectory $out
if (-not (Test-Path -LiteralPath $archive)) { throw 'No report ZIP returned' }
$extract=Join-Path $work 'extract'
[IO.Compression.ZipFile]::ExtractToDirectory($archive,$extract)
$names=@(Get-ChildItem -LiteralPath $extract -File | ForEach-Object Name | Sort-Object)
if (($names -join ',') -ne 'AbioticFactor.log,CrashContext.runtime-xml,main.lua,report.txt,UE4SS.log') { throw 'Unexpected diagnostic ZIP membership' }
if ([IO.File]::ReadAllText((Join-Path $extract 'CrashContext.runtime-xml')) -ne '<new/>') { throw 'Latest crash context not selected' }
if ((Get-FileHash -LiteralPath (Join-Path $extract 'UE4SS.log')).Hash -ne (Get-FileHash -LiteralPath (Join-Path $ue4ss 'UE4SS.log')).Hash) { throw 'UE4SS log altered' }
if ([IO.File]::ReadAllText((Join-Path $mod 'Scripts/main.lua')) -ne 'Installed mod fixture') { throw 'Collector changed installed mod' }
Write-Host 'PASS report ZIP contents, latest context, byte-preserved log and no changes to installed mod'
$archive=& $block -ModPath $mod -SavedPath (Join-Path $work 'Missing Saved') -OutputDirectory $out
$missing=Join-Path $work 'missing-extract'
[IO.Compression.ZipFile]::ExtractToDirectory($archive,$missing)
$manifest=[IO.File]::ReadAllText((Join-Path $missing 'report.txt'))
if (-not $manifest.Contains('Missing: AbioticFactor.log') -or -not $manifest.Contains('Missing: crash directory')) { throw 'Missing game reports not explained' }
if (Test-Path -LiteralPath (Join-Path $missing 'CrashContext.runtime-xml')) { throw 'Wrong crash context included' }
Write-Host 'PASS missing game log/context are recorded without blocking available diagnostics'
Remove-Item -LiteralPath $work -Recurse -Force
Write-Host 'Diagnostic collector smoke checks passed in a temporary fixture; no actual user logs read.'
