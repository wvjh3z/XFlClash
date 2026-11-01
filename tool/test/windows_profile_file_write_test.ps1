param([string]$DartExecutable = (Join-Path $env:FLUTTER_ROOT 'bin/cache/dart-sdk/bin/dart.exe'))
$ErrorActionPreference='Stop'
[Console]::OutputEncoding=New-Object System.Text.UTF8Encoding($false)
$root=Join-Path $env:TEMP ('xb-atomic-write-'+[Guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root)|Out-Null
$dart=$DartExecutable
if(-not (Test-Path -LiteralPath $dart)){throw 'Set DartExecutable to an existing Dart SDK executable'}
$script=Join-Path $root 'copy_probe.dart'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/profile_file_write_native.dart') -Destination $script
$rows=@()
Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../lib/xboard/services/xb_profile_file_write.dart') -Destination (Join-Path $root 'xb_profile_file_write.dart')
foreach($brand in @('brand_a','brand_b')) {
 foreach($case in @('new','existing','read_only','held_no_delete','held_allow_delete','released_during_wait','exclusive_read','released_read','cancel_read','directory')) {
  $dir=Join-Path $root ($brand+'-'+$case)
  [IO.Directory]::CreateDirectory($dir)|Out-Null
  $source=Join-Path $dir 'source.yaml';$target=Join-Path $dir 'target.yaml'
  [IO.File]::WriteAllText($source,'new-config')
  if($case -eq 'directory'){[IO.Directory]::CreateDirectory($target)|Out-Null}
  elseif($case -ne 'new'){[IO.File]::WriteAllText($target,'old-config')}
  $handle=$null
  try {
   if($case -eq 'read_only'){[IO.File]::SetAttributes($target,[IO.FileAttributes]::ReadOnly)}
   if($case -eq 'held_no_delete' -or $case -eq 'released_during_wait'){$handle=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite)}
   if($case -eq 'held_allow_delete'){$handle=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::Read,([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))}
   if($case -in @('exclusive_read','released_read','cancel_read')){$handle=[IO.File]::Open($target,[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}
   if($case -in @('released_during_wait','released_read','cancel_read')) {
    $signals=Join-Path $dir 'signals';[IO.Directory]::CreateDirectory($signals)|Out-Null
    $psi=New-Object Diagnostics.ProcessStartInfo
    $psi.FileName=$dart;$psi.UseShellExecute=$false;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $psi.Arguments='"'+$script+'" "'+$source+'" "'+$target+'" "'+$signals+'"'
    if($case -eq 'cancel_read'){$psi.Arguments+=' cancel'}
    $process=New-Object Diagnostics.Process;$process.StartInfo=$psi
    if(-not $process.Start()){throw 'probe not started'}
    try {
     $watch=[Diagnostics.Stopwatch]::StartNew()
     while(-not (Test-Path (Join-Path $signals 'ready'))) {
      if($process.HasExited -or $watch.Elapsed.TotalSeconds -gt 12){throw 'probe never reached retry'}
      Start-Sleep -Milliseconds 10
     }
     $handle.Dispose();$handle=$null
     [IO.File]::WriteAllText((Join-Path $signals 'release'),'release')
     if(-not $process.WaitForExit(12000)){throw 'probe retry did not finish'}
     if($process.ExitCode -ne 0){throw 'probe retry failed'}
     $result=$process.StandardOutput.ReadToEnd() | ConvertFrom-Json
     $global:LASTEXITCODE=0
    } finally {if(-not $process.HasExited){$process.Kill()};$process.Dispose()}
   } else {
    $result=(& $dart $script $source $target | Out-String | ConvertFrom-Json)
   }
   if($LASTEXITCODE -ne 0){throw 'Dart fixture failed'}
   $rows += [pscustomobject]@{brand=$brand;scenario=$case;result=$result}
  } finally {
   if($handle){$handle.Dispose()}
   if($case -eq 'read_only'){[IO.File]::SetAttributes($target,[IO.FileAttributes]::Normal)}
  }
  if($case -in @('exclusive_read','cancel_read')){$result.old_preserved=([IO.File]::ReadAllText($target)-eq 'old-config')}
  if($case -eq 'held_no_delete') {
   $result=(& $dart $script $source $target | Out-String | ConvertFrom-Json)
   $rows += [pscustomobject]@{brand=$brand;scenario='released_then_retry';result=$result}
  }
 }
}
foreach($row in $rows) {
 $r=$row.result;$case=$row.scenario
 if(-not $r.cleanup_ok -or -not $r.staging_removed){throw 'STAGING_NOT_CLEANED'}
 if($case -in @('new','existing','released_then_retry','released_during_wait','released_read')) {
  if(-not $r.ok -or -not $r.new_present){throw 'EXPECTED_RECOVERY_FAILED'}
  if($case -eq 'released_during_wait' -and $r.attempts -ne 2){throw 'TRANSIENT_RETRY_NOT_EXERCISED'}
  if($case -eq 'released_read' -and ($r.attempts -ne 1 -or $r.waits -ne 1)){throw 'READ_RETRY_NOT_EXERCISED'}
 } elseif($case -eq 'held_allow_delete' -and $r.ok) {
  if(-not $r.new_present){throw 'NEW_BYTES_MISSING'}
 } else {
  if($r.ok){throw 'NEGATIVE_ACCEPTED'}
  if($case -ne 'directory' -and -not $r.old_preserved){throw 'OLD_BYTES_LOST'}
  if($case -in @('held_no_delete','held_allow_delete') -and $r.attempts -ne 4){throw 'RETRY_BUDGET_WRONG'}
  if($case -eq 'exclusive_read' -and ($r.attempts -ne 0 -or $r.waits -ne 3)){throw 'READ_BUDGET_WRONG'}
  if($case -eq 'cancel_read' -and ($r.attempts -ne 0 -or $r.waits -ne 1 -or -not $r.cancelled)){throw 'CANCEL_NOT_RESPECTED'}
  if($case -in @('read_only','directory') -and ($r.attempts -ne 0 -or $r.waits -ne 0)){throw 'UNSAFE_RETRY'}
 }
}
[pscustomobject]@{os=[Environment]::OSVersion.Version.ToString();dart=(& $dart --version | Out-String).Trim();results=$rows} | ConvertTo-Json -Depth 6
