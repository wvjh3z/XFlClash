param([string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $Root 'tool/windows/remove_brand_user_data.ps1') -LibraryOnly
function Assert($condition, [string]$message) { if (-not $condition) { throw $message } }
function Put([string]$path) {
    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path))
    [IO.File]::WriteAllText($path, 'fixture')
}
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('brand-data-' + [guid]::NewGuid())
$junctions = @()
$fileLinks = @()
$count = 0
try {
    [void][IO.Directory]::CreateDirectory($fixture)
    Assert (Test-XbCleanupIdentity 'S-1-5-21-1' @('S-1-5-21-1')) 'Same desktop user rejected'
    Assert (-not (Test-XbCleanupIdentity 'S-1-5-21-2' @('S-1-5-21-1'))) 'Other administrator accepted'
    Assert (-not (Test-XbCleanupIdentity 'S-1-5-21-1' @())) 'Missing shell user accepted'
    Assert (-not (Test-XbCleanupIdentity 'S-1-5-21-1' @('S-1-5-21-1','S-1-5-21-2'))) 'Ambiguous shell accepted'
    Assert (Test-XbCleanupRootOwnership 'C:\Users\fixture\AppData\Local' 'C:\Users\fixture') 'Own profile root rejected'
    Assert (-not (Test-XbCleanupRootOwnership 'C:\Users\fixture-other\AppData' 'C:\Users\fixture')) 'Profile prefix collision accepted'
    Assert (-not (Test-XbCleanupRootOwnership 'C:\Users\other\AppData' 'C:\Users\fixture')) 'Other profile accepted'
    Assert (-not (Test-XbCleanupRootOwnership 'D:\redirected' 'C:\Users\fixture')) 'Unconfirmed redirected profile accepted'
    Assert (-not (Test-XbCleanupRootOwnership 'C:\Users\fixture' 'C:\')) 'Drive root accepted as user profile'
    $count += 9
    foreach ($brand in @('omofly','daishu')) {
        $other = if ($brand -eq 'omofly') { 'daishu' } else { 'omofly' }
        $case = Join-Path $fixture $brand
        $roots = @((Join-Path $case 'Roaming'),(Join-Path $case 'Local'))
        foreach ($folder in $roots) {
            Put (Join-Path $folder "com.cloud.app\$brand\nested\config.json")
            Put (Join-Path $folder "com.cloud.app\$other\keep.txt")
            Put (Join-Path $folder 'com.follow\clash\keep.txt')
            Put (Join-Path $folder 'unrelated.txt')
        }
        $results = @(Remove-XbBrandDataRoots $roots $brand)
        Assert (@($results | Where-Object { -not $_.Removed }).Count -eq 0) 'Safe cleanup failed'
        foreach ($folder in $roots) {
            Assert (-not (Test-Path -LiteralPath (Join-Path $folder "com.cloud.app\$brand"))) 'Brand data remains'
            Assert (Test-Path -LiteralPath (Join-Path $folder "com.cloud.app\$other\keep.txt")) 'Other brand removed'
            Assert (Test-Path -LiteralPath (Join-Path $folder 'com.follow\clash\keep.txt')) 'Upstream removed'
            Assert (Test-Path -LiteralPath (Join-Path $folder 'unrelated.txt')) 'Unrelated file removed'
            Assert (Test-Path -LiteralPath (Join-Path $folder 'com.cloud.app')) 'Shared parent removed'
        }
        Assert (@(Remove-XbBrandDataRoots $roots $brand | Where-Object { -not $_.Removed }).Count -eq 0) 'Repeated cleanup failed'
        $count += 2
        foreach ($position in @('root','nested','company')) {
            $folder = Join-Path $case $position
            $target = Join-Path $folder "com.cloud.app\$brand"
            $outside = Join-Path $case ("outside-"+$position)
            Put (Join-Path $outside 'keep.txt')
            $link = if ($position -eq 'company') { Join-Path $folder 'com.cloud.app' } elseif ($position -eq 'root') { $target } else { Join-Path $target 'link' }
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($link))
            if ($position -eq 'nested') { Put (Join-Path $target 'keep-local.txt') }
            & $env:ComSpec /d /c "mklink /J `"$link`" `"$outside`"" | Out-Null
            Assert ($LASTEXITCODE -eq 0) 'Could not create real junction fixture'
            $junctions += $link
            $result = @(Remove-XbBrandDataRoots @($folder) $brand)
            Assert (-not $result[0].Removed) 'Junction not rejected'
            Assert (Test-Path -LiteralPath (Join-Path $outside 'keep.txt')) 'Junction target touched'
            if ($position -eq 'nested') { Assert (Test-Path -LiteralPath (Join-Path $target 'keep-local.txt')) 'Preflight partially deleted root' }
            $count++
        }
        $folder = Join-Path $case 'symbolic'
        $target = Join-Path $folder "com.cloud.app\$brand"
        $outsideFile = Join-Path $case 'symbolic-outside.txt'
        Put $outsideFile
        [void][IO.Directory]::CreateDirectory($target)
        $link = Join-Path $target 'link.txt'
        & $env:ComSpec /d /c "mklink `"$link`" `"$outsideFile`"" | Out-Null
        Assert ($LASTEXITCODE -eq 0) 'Could not create file symbolic link fixture'
        $fileLinks += $link
        Assert (-not @(Remove-XbBrandDataRoots @($folder) $brand)[0].Removed) 'File symlink not rejected'
        Assert (Test-Path -LiteralPath $outsideFile) 'Symlink target touched'
        $count++
        $folder = Join-Path $case ('unicode-' + [char]0x6D4B + [char]0x8BD5)
        Put (Join-Path $folder "com.cloud.app\$brand\nested\config.json")
        Assert (@(Remove-XbBrandDataRoots @($folder) $brand)[0].Removed) 'Unicode root cleanup failed'
        $count++
        $folder = Join-Path $case 'locked'
        $target = Join-Path $folder "com.cloud.app\$brand"
        Put (Join-Path $target 'a.txt'); Put (Join-Path $target 'locked.txt')
        $held = [IO.File]::Open((Join-Path $target 'locked.txt'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        try {
            $result = @(Remove-XbBrandDataRoots @($folder) $brand)
            Assert (-not $result[0].Removed) 'Locked file reported removed'
            Assert (Test-Path -LiteralPath (Join-Path $target 'a.txt')) 'Preflight deleted other files before lock failure'
        } finally { $held.Dispose() }
        Assert (@(Remove-XbBrandDataRoots @($folder) $brand)[0].Removed) 'Unlocked retry failed'
        $count++
        $folder = Join-Path $case 'instance-lock'
        $target = Join-Path $folder "com.cloud.app\$brand"
        Put (Join-Path $target 'FlClash.lock'); Put (Join-Path $target 'config.json')
        $held = [IO.File]::Open((Join-Path $target 'FlClash.lock'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
        $held.Lock(0,1)
        try {
            Assert (-not @(Remove-XbBrandDataRoots @($folder) $brand)[0].Removed) 'Running instance lock ignored'
            Assert (Test-Path -LiteralPath (Join-Path $target 'config.json')) 'Active instance data deleted'
        } finally { $held.Dispose() }
        Assert (@(Remove-XbBrandDataRoots @($folder) $brand)[0].Removed) 'Instance lock release did not recover'
        $count++
        $folder = Join-Path $case 'readonly'
        $file = Join-Path $folder "com.cloud.app\$brand\read-only.txt"
        Put $file
        [IO.File]::SetAttributes($file,[IO.FileAttributes]::ReadOnly)
        $result = @(Remove-XbBrandDataRoots @($folder) $brand)
        Assert (-not $result[0].Removed) 'Read-only deletion failure hidden'
        Assert (Test-Path -LiteralPath $file) 'Read-only fixture unexpectedly deleted'
        [IO.File]::SetAttributes($file,[IO.FileAttributes]::Normal)
        Assert (@(Remove-XbBrandDataRoots @($folder) $brand)[0].Removed) 'Read-only recovery failed'
        $count++
        foreach ($invalid in @('', 'C:\', '\\server\share', (Join-Path $case '..\other'))) {
            Assert (-not @(Remove-XbBrandDataRoots @($invalid) $brand)[0].Removed) 'Invalid root accepted'
            $count++
        }
    }
    Write-Output "PASS: $count real Windows cleanup and identity checks"
} finally {
    foreach ($link in $fileLinks) { if ([IO.File]::Exists($link)) { [IO.File]::Delete($link) } }
    foreach ($link in $junctions) {
        if (Test-Path -LiteralPath $link) { & $env:ComSpec /d /c "rmdir `"$link`"" | Out-Null }
    }
    if (Test-Path -LiteralPath $fixture) { Remove-Item -LiteralPath $fixture -Recurse -Force }
}
& (Join-Path $PSScriptRoot 'windows_brand_data_cleanup_race_test.ps1') -Root $Root
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
exit 0
