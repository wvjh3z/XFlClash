param(
    [string]$InstallDirectory,
    [ValidateSet('OmoFlyHelperService','DaishuHelperService')][string]$ServiceName,
    [switch]$LibraryOnly
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-XbOwnedImage([string]$Image, [string]$Root) {
    if ([string]::IsNullOrWhiteSpace($Image) -or [string]::IsNullOrWhiteSpace($Root)) { return $false }
    try {
        $normalized = [IO.Path]::GetFullPath($Image)
        foreach ($name in @('OmoFly.exe','OmoFlyCore.exe','OmoFlyHelperService.exe','Daishu.exe','DaishuCore.exe','DaishuHelperService.exe')) {
            $expected = [IO.Path]::GetFullPath([IO.Path]::Combine($Root, $name))
            if ([StringComparer]::OrdinalIgnoreCase.Equals($normalized, $expected)) { return $true }
        }
    } catch { return $false }
    return $false
}
function Get-XbInstallProcesses { @(Get-CimInstance Win32_Process) }
function Stop-XbOwnedProcess($Process, [string]$Root) {
    # Re-read the image immediately before stopping; never kill by basename.
    $live = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$Process.ProcessId)
    if ($null -ne $live -and (Test-XbOwnedImage $live.ExecutablePath $Root)) {
        Stop-Process -Id ([int]$live.ProcessId) -Force -ErrorAction Stop
        try { Wait-Process -Id ([int]$live.ProcessId) -Timeout 15 -ErrorAction Stop } catch {
            $remaining = Get-CimInstance Win32_Process -Filter ('ProcessId=' + [int]$live.ProcessId)
            if ($null -ne $remaining -and (Test-XbOwnedImage $remaining.ExecutablePath $Root)) {
                throw 'Owned process did not stop within the deadline'
            }
        }
    }
}
function Get-XbInstallService([string]$Name) { Get-CimInstance Win32_Service -Filter ("Name='$Name'") }
function Remove-XbInstallService($Service) {
    if ($Service.State -ne 'Stopped') {
        $controller = Get-Service -Name $Service.Name -ErrorAction Stop
        try {
            $controller.Stop()
            $controller.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(30))
        } finally { $controller.Dispose() }
    }
    & "$env:SystemRoot\System32\sc.exe" delete $Service.Name | Out-Null
    if ($LASTEXITCODE -ne 0) { throw 'Brand helper deletion failed' }
}
function Get-XbOwnedProxySnapshot($Processes, [string]$Root) {
    $key = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
    $settings = Get-ItemProperty -LiteralPath $key -ErrorAction SilentlyContinue
    if ($null -eq $settings -or $null -eq $settings.PSObject.Properties['ProxyEnable'] -or $settings.ProxyEnable -ne 1 -or
        $null -eq $settings.PSObject.Properties['ProxyServer']) { return $null }
    $match = [regex]::Match([string]$settings.ProxyServer, '^127\.0\.0\.1:(\d+)$')
    if (-not $match.Success) { return $null }
    $port = [int]$match.Groups[1].Value
    $owned = @($Processes | Where-Object { Test-XbOwnedImage $_.ExecutablePath $Root } | ForEach-Object { [int]$_.ProcessId })
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $port -ErrorAction SilentlyContinue)
    if ($listeners.Count -eq 0 -or @($listeners | Where-Object { [int]$_.OwningProcess -notin $owned }).Count -gt 0) { return $null }
    return @{ Key=$key; Server=[string]$settings.ProxyServer; Port=$port }
}
function Clear-XbOwnedProxy($Snapshot) {
    if ($null -eq $Snapshot) { return }
    $settings = Get-ItemProperty -LiteralPath $Snapshot.Key -ErrorAction Stop
    if ([string]$settings.ProxyServer -ne $Snapshot.Server) { return }
    if (@(Get-NetTCPConnection -State Listen -LocalPort $Snapshot.Port -ErrorAction SilentlyContinue).Count -gt 0) { return }
    if (-not ('XbProxyNotification' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class XbProxyNotification {
  [DllImport("wininet.dll", SetLastError=true)]
  public static extern bool InternetSetOption(IntPtr h, int option, IntPtr buffer, int length);
  [StructLayout(LayoutKind.Sequential)]
  private struct Options { public int size; public IntPtr connection; public int count; public int error; public IntPtr options; }
  [DllImport("wininet.dll", EntryPoint="InternetQueryOptionW", SetLastError=true)]
  private static extern bool Query(IntPtr h, int option, ref Options data, ref int length);
  [DllImport("wininet.dll", EntryPoint="InternetSetOptionW", SetLastError=true)]
  private static extern bool Set(IntPtr h, int option, ref Options data, int length);
  public static bool DisableProxy() {
    int offset = IntPtr.Size == 8 ? 8 : 4;
    IntPtr option = Marshal.AllocHGlobal(IntPtr.Size == 8 ? 16 : 12);
    try {
      for (int i=0;i<(IntPtr.Size == 8 ? 16 : 12);i++) Marshal.WriteByte(option,i,0);
      Marshal.WriteInt32(option,0,1); // INTERNET_PER_CONN_FLAGS
      Options list = new Options(); list.size=Marshal.SizeOf(typeof(Options)); list.count=1; list.options=option;
      int length=list.size;
      if (!Query(IntPtr.Zero,75,ref list,ref length)) return false;
      int flags=Marshal.ReadInt32(option,offset);
      Marshal.WriteInt32(option,offset,(flags & ~2) | 1); // Remove manual proxy; preserve PAC/autodetect.
      return Set(IntPtr.Zero,75,ref list,list.size);
    } finally { Marshal.FreeHGlobal(option); }
  }
}
'@
    }
    # Use WinINet's per-connection API, not direct registry writes.
    if (-not [XbProxyNotification]::DisableProxy()) { throw 'Cannot clear the owned stopped proxy' }
    [XbProxyNotification]::InternetSetOption([IntPtr]::Zero,39,[IntPtr]::Zero,0) | Out-Null
    [XbProxyNotification]::InternetSetOption([IntPtr]::Zero,37,[IntPtr]::Zero,0) | Out-Null
}
function Stop-XbOwnedInstallation([string]$Root, [string]$Name) {
    if ($Name -notin @('OmoFlyHelperService','DaishuHelperService')) { throw 'Unknown brand service' }
    if (-not [IO.Path]::IsPathRooted($Root)) { throw 'Absolute installation directory required' }
    $ownRunner = $Name.Replace('HelperService','') + '.exe'
    foreach ($runner in @('FlClash.exe','OmoFly.exe','Daishu.exe')) {
        if ($runner -ne $ownRunner -and (Test-Path -LiteralPath (Join-Path $Root $runner))) {
            throw 'This directory belongs to another client; choose the default brand directory'
        }
    }
    $processes = @(Get-XbInstallProcesses)
    $proxy = Get-XbOwnedProxySnapshot $processes $Root
    $service = Get-XbInstallService $Name
    if ($null -ne $service) {
        $match = [regex]::Match([string]$service.PathName, '^\s*(?:"([^"]+)"|(\S+))')
        $image = if ($match.Groups[1].Success) { $match.Groups[1].Value } else { $match.Groups[2].Value }
        if (-not (Test-XbOwnedImage $image $Root) -or [IO.Path]::GetFileName($image) -ne ($Name + '.exe')) {
            throw 'Brand helper belongs to another installation directory'
        }
        Remove-XbInstallService $service
    }
    foreach ($process in $processes) {
        if (Test-XbOwnedImage $process.ExecutablePath $Root) { Stop-XbOwnedProcess $process $Root }
    }
    Clear-XbOwnedProxy $proxy
}

if (-not $LibraryOnly) {
    try { Stop-XbOwnedInstallation $InstallDirectory $ServiceName; exit 0 }
    catch { Write-Error ('Cannot prepare this brand installation: ' + $_.Exception.Message) -ErrorAction Continue; exit 1 }
}
