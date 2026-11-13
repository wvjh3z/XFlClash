$ErrorActionPreference='Stop'
$out=Join-Path $PWD 'evidence'
$dest='C:\b42-login'
$prefs=Join-Path $env:APPDATA 'com.cloud.app\daishu'
New-Item -ItemType Directory -Force $prefs | Out-Null
# Use the existing device reporting opt-out before SDK initialization.
'{"flutter.xb_sentry_reporting_enabled_v1":false}' | Set-Content (Join-Path $prefs 'shared_preferences.json') -Encoding utf8NoBOM
$p=Start-Process "$env:RUNNER_TEMP/setup.exe" -ArgumentList @('/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/SP-',"/DIR=$dest","/LOG=$out/install.log") -PassThru
if(-not $p.WaitForExit(180000)){throw 'Installer timeout'}
if($p.ExitCode -ne 0){throw 'Installer failed'}
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public class LoginProbeWindow {
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
 [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr hwnd,int x,int y,int w,int h,bool repaint);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern void mouse_event(uint flags,uint dx,uint dy,uint data,UIntPtr extra);
}
'@
try {
 $p=Start-Process "$dest/Daishu.exe" -WorkingDirectory $dest -PassThru
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
 @{stage='prelogin-only';credentialsUsed=$false;windowTitle=$p.MainWindowTitle;version=(Get-Item "$dest/Daishu.exe").VersionInfo.FileVersion} | ConvertTo-Json | Set-Content "$out/login-probe.json"
} finally {
 Get-Process | Where-Object {$_.Path -and $_.Path.StartsWith($dest,[StringComparison]::OrdinalIgnoreCase)} | Stop-Process -Force -ErrorAction SilentlyContinue
 $uninstaller=Get-ChildItem $dest -Filter 'unins*.exe' | Select-Object -First 1
 if($uninstaller){$u=Start-Process $uninstaller.FullName -ArgumentList '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART' -PassThru;$u.WaitForExit(120000) | Out-Null}
}
