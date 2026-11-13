$ErrorActionPreference = 'Stop'
$out = Join-Path $PWD 'evidence'
$dest = 'C:\b42-smoke'
$report = [ordered]@{
  arch = $env:TEST_ARCH
  os = (Get-CimInstance Win32_OperatingSystem).Caption
  osBuild = [Environment]::OSVersion.Version.ToString()
  processArch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture.ToString()
  installed = $false
  limitations = @('GitHub administrator/UAC-disabled host', 'Network blocked: no login, VPN or Sentry traffic', 'Process survival does not prove UI or Core readiness')
}
$started = Get-Date
function Save-Report { $report | ConvertTo-Json -Depth 10 | Set-Content "$out/report.json" }
function Stop-TestProcesses {
  Get-Process | Where-Object { $_.Path -and $_.Path.StartsWith($dest, [StringComparison]::OrdinalIgnoreCase) } | Stop-Process -Force -ErrorAction SilentlyContinue
}
try {
  $installer = Start-Process "$env:RUNNER_TEMP/setup.exe" -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$dest","/LOG=$out/install.log") -PassThru
  if (-not $installer.WaitForExit(180000)) { $installer.Kill(); throw 'Installer timeout' }
  $report.installExit = $installer.ExitCode
  if ($installer.ExitCode -notin @(0,3010)) { throw 'Installer failed' }
  $report.installed = $true
  $executables = @(Get-ChildItem $dest -Recurse -Filter '*.exe')
  # Block app/Core output before any deliberate launch; no synthetic Sentry events.
  foreach ($file in $executables) {
    New-NetFirewallRule -DisplayName ('B42-smoke-' + $file.Name) -Direction Outbound -Program $file.FullName -Action Block | Out-Null
  }
  $report.installedExecutables = @($executables | Select-Object -ExpandProperty Name)
  # Fixed B42 entry verified from both installer logs, not guessed by exclusion.
  $entry = @(Get-ChildItem $dest -Filter 'Daishu.exe')
  if ($entry.Count -ne 1) { throw 'Ambiguous application entry' }
  $exe = $entry[0]
  $report.executable = $exe.Name
  $report.version = $exe.VersionInfo.FileVersion
  $report.productVersion = $exe.VersionInfo.ProductVersion
  $report.binarySignatures = @(Get-ChildItem $dest -Recurse -File | Where-Object { $_.Name -in @($exe.Name,'rust_api.dll') } | ForEach-Object {
    $s = Get-AuthenticodeSignature $_.FullName
    @{name=$_.Name;status=$s.Status.ToString();signer=if($s.SignerCertificate){$s.SignerCertificate.Subject}else{$null}}
  })
  $before = @(Get-ChildItem 'HKCU:\Software\Classes' | Select-Object -ExpandProperty PSChildName)
  $p = Start-Process $exe.FullName -WorkingDirectory $dest -PassThru -RedirectStandardOutput "$out/admin-stdout.log" -RedirectStandardError "$out/admin-stderr.log"
  Start-Sleep -Seconds 25
  $p.Refresh()
  $report.adminLaunch = @{alive=(-not $p.HasExited);exitCode=if($p.HasExited){$p.ExitCode}else{$null};windowTitle=$p.MainWindowTitle}
  $report.newProtocolKeys = @(Get-ChildItem 'HKCU:\Software\Classes' | Where-Object { $_.PSChildName -notin $before } | Select-Object -ExpandProperty PSChildName)
  Stop-TestProcesses
  # Explicit low-privilege account. Lack of a usable GUI session stays a limitation.
  $password = [Guid]::NewGuid().ToString() + '!aA9'
  $secure = ConvertTo-SecureString $password -AsPlainText -Force
  New-LocalUser -Name 'b42test' -Password $secure -AccountNeverExpires | Out-Null
  $users = Get-LocalGroup -SID 'S-1-5-32-545'
  Add-LocalGroupMember -Group $users -Member 'b42test'
  $credential = New-Object System.Management.Automation.PSCredential('.\b42test',$secure)
  try {
    $p = Start-Process $exe.FullName -WorkingDirectory $dest -Credential $credential -LoadUserProfile -PassThru
    Start-Sleep -Seconds 25
    $p.Refresh()
    $report.standardLaunch = @{alive=(-not $p.HasExited);exitCode=if($p.HasExited){$p.ExitCode}else{$null};windowTitle=$p.MainWindowTitle}
  } catch { $report.standardLaunch = @{available=$false;errorType=$_.Exception.GetType().Name;hresult=$_.Exception.HResult} }
  Stop-TestProcesses
  $report.codeIntegrity = @(Get-WinEvent -FilterHashtable @{LogName='Microsoft-Windows-CodeIntegrity/Operational';Id=3077,3089;StartTime=$started} -ErrorAction SilentlyContinue | Where-Object { $_.Message -like '*b42-smoke*' } | Select-Object Id,TimeCreated,Message)
  $uninstaller = Get-ChildItem $dest -Filter 'unins*.exe' | Select-Object -First 1
  if ($uninstaller) {
    $u = Start-Process $uninstaller.FullName -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -PassThru
    if (-not $u.WaitForExit(120000)) { $u.Kill(); throw 'Uninstall timeout' }
    $report.uninstallExit = $u.ExitCode
  }
} catch {
  $report.failure = @{type=$_.Exception.GetType().Name;message=$_.Exception.Message}
  throw
} finally {
  Stop-TestProcesses
  Save-Report
}
