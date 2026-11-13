$ErrorActionPreference='Stop'
$account=$env:B42_TEST_ACCOUNT
$password=$env:B42_TEST_PASSWORD
Remove-Item Env:B42_TEST_ACCOUNT,Env:B42_TEST_PASSWORD -ErrorAction SilentlyContinue
if(-not $account -or -not $password){throw 'Missing test credentials'}
$result=[ordered]@{installed=$false;loginRecordCommitted=$false;uninstalled=$false;noPostCredentialScreenshots=$true}
$out=Join-Path $PWD 'evidence'
$dest='C:\b42-login'
$prefs=Join-Path $env:APPDATA 'com.cloud.app\daishu'
New-Item -ItemType Directory -Force $prefs | Out-Null
# Use the existing device reporting opt-out before SDK initialization.
'{"flutter.xb_sentry_reporting_enabled_v1":false}' | Set-Content (Join-Path $prefs 'shared_preferences.json') -Encoding utf8NoBOM
$p=Start-Process "$env:RUNNER_TEMP/setup.exe" -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$dest","/LOG=$out/install.log") -PassThru
if(-not $p.WaitForExit(180000)){throw 'Installer timeout'}
if($p.ExitCode -ne 0){throw 'Installer failed'}
$result.installed=$true
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class LoginProbeWindow {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd,int x,int y,int w,int h,bool repaint);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
}
'@
try {
 $p=Start-Process "$dest/Daishu.exe" -WorkingDirectory $dest -PassThru -RedirectStandardOutput "$env:RUNNER_TEMP/client.private.stdout" -RedirectStandardError "$env:RUNNER_TEMP/client.private.stderr"
 Start-Sleep -Seconds 20
 $p.Refresh()
 if($p.HasExited){throw 'Application exited'}
 [LoginProbeWindow]::MoveWindow($p.MainWindowHandle,20,20,900,680,$true) | Out-Null
 [LoginProbeWindow]::SetForegroundWindow($p.MainWindowHandle) | Out-Null
 Start-Sleep -Seconds 3
 # Locations from the credential-free AMD64 screenshot, relative to capture origin.
 [LoginProbeWindow]::SetCursorPos(593,602) | Out-Null
 [LoginProbeWindow]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [LoginProbeWindow]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Seconds 5
 [LoginProbeWindow]::SetCursorPos(110,600) | Out-Null
 [LoginProbeWindow]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [LoginProbeWindow]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Seconds 3
 [LoginProbeWindow]::SetCursorPos(620,207) | Out-Null
 [LoginProbeWindow]::mouse_event(2,0,0,0,[UIntPtr]::Zero)
 [LoginProbeWindow]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Start-Sleep -Seconds 3
 $image=[System.Drawing.Bitmap]::new(900,680)
 $graphics=[System.Drawing.Graphics]::FromImage($image)
 $graphics.CopyFromScreen([System.Drawing.Point]::new(20,20),[System.Drawing.Point]::Empty,[System.Drawing.Size]::new(900,680))
 $image.Save("$out/prelogin.png")
 $graphics.Dispose();$image.Dispose()
 $result.version=(Get-Item "$dest/Daishu.exe").VersionInfo.FileVersion
 $settings=Get-Content (Join-Path $prefs 'shared_preferences.json') -Raw | ConvertFrom-Json -AsHashtable
 if($settings['flutter.xb_sentry_reporting_enabled_v1'] -ne $false){throw 'Reporting opt-out was not retained'}
 if([LoginProbeWindow]::GetForegroundWindow() -ne $p.MainWindowHandle){throw 'App not foreground; credentials withheld'}
 [LoginProbeWindow]::SetCursorPos(520,313) | Out-Null
 [LoginProbeWindow]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[LoginProbeWindow]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Set-Clipboard -Value $account
 [System.Windows.Forms.SendKeys]::SendWait('^v')
 [LoginProbeWindow]::SetCursorPos(520,373) | Out-Null
 [LoginProbeWindow]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[LoginProbeWindow]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 Set-Clipboard -Value $password
 [System.Windows.Forms.SendKeys]::SendWait('^v')
 Set-Clipboard -Value ''
 $account=$null;$password=$null
 [LoginProbeWindow]::SetCursorPos(520,439) | Out-Null
 [LoginProbeWindow]::mouse_event(2,0,0,0,[UIntPtr]::Zero);[LoginProbeWindow]::mouse_event(4,0,0,0,[UIntPtr]::Zero)
 # Boolean evidence only: do not export token values or client logs.
 for($i=0;$i -lt 40;$i++) {
   Start-Sleep -Seconds 3
   try {
     $settings=Get-Content (Join-Path $prefs 'shared_preferences.json') -Raw | ConvertFrom-Json -AsHashtable
     $raw=$settings['flutter.xb_access_token_v1_brand_b_record_v2']
     if($raw){$record=$raw | ConvertFrom-Json -AsHashtable;if($record['key'] -or $record['value']){$result.loginRecordCommitted=$true;break}}
   } catch { }
 }
 if(-not $result.loginRecordCommitted){throw 'Login record not committed within observation window'}
} finally {
 Get-Process | Where-Object {$_.Path -and $_.Path.StartsWith($dest,[StringComparison]::OrdinalIgnoreCase)} | Stop-Process -Force -ErrorAction SilentlyContinue
 $uninstaller=Get-ChildItem $dest -Filter 'unins*.exe' | Select-Object -First 1
 if($uninstaller){$u=Start-Process $uninstaller.FullName -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -PassThru;if($u.WaitForExit(120000)){$result.uninstallExit=$u.ExitCode;$result.uninstalled=($u.ExitCode -eq 0 -and -not (Test-Path "$dest/Daishu.exe"))}}
 Remove-Item "$env:RUNNER_TEMP/client.private.stdout","$env:RUNNER_TEMP/client.private.stderr" -Force -ErrorAction SilentlyContinue
 Remove-Item $prefs -Recurse -Force -ErrorAction SilentlyContinue
 $result | ConvertTo-Json | Set-Content "$out/login-result.json"
}
