# Windows PowerShell 5.1 compatible. Dot-sourcing only defines functions for tests.
# No downloads or shared-runtime uninstall on the end user's machine.
[CmdletBinding()]
param([string]$ConfigPath, [string]$PayloadPath, [string]$LogPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function ConvertTo-XbVersion([string]$Value) {
    if ($Value -notmatch '^v?(\d+\.\d+\.\d+\.\d+)$') { return $null }
    try { return [version]$Matches[1] } catch { return $null }
}

function Read-XbRuntimeConfig([string]$Path) {
    $c = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $minimum = ConvertTo-XbVersion $c.minimumVersion
    $bundled = ConvertTo-XbVersion $c.bundledVersion
    if ($null -eq $minimum -or $null -eq $bundled -or $minimum.Major -ne 14 -or
        $bundled.Major -ne 14 -or $bundled -lt $minimum -or $c.architecture -ne 'x64' -or
        $c.sha256 -cnotmatch '^[0-9a-f]{64}$' -or $c.size -le 0 -or
        $c.url -cnotmatch '^https://download\.visualstudio\.microsoft\.com/download/pr/[^?#]+/VC_redist\.x64\.exe$' -or
        $c.validatedCompilerFamily -notmatch '^19\.\d+$') {
        throw 'Invalid VC runtime policy'
    }
    return $c
}

function Test-XbPayloadHash([string]$Path, $Config) {
    return (Test-Path -LiteralPath $Path -PathType Leaf) -and
        (Get-Item -LiteralPath $Path).Length -eq $Config.size -and
        (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -eq $Config.sha256
}

function Get-XbFileVersion([string]$Path) {
    $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($Path)
    return [version]::new($v.FileMajorPart, $v.FileMinorPart, $v.FileBuildPart, $v.FilePrivatePart)
}

function Get-XbRegisteredVersions {
    # Explicit views: a 32-bit registry entry for x86 is never enough for x64.
    foreach ($view in @([Microsoft.Win32.RegistryView]::Registry64,
                         [Microsoft.Win32.RegistryView]::Registry32)) {
        $base = $null; $key = $null
        try {
            $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
                [Microsoft.Win32.RegistryHive]::LocalMachine, $view)
            $key = $base.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\x64')
            if ($null -ne $key -and $key.GetValue('Installed', 0) -eq 1) {
                $version = ConvertTo-XbVersion ([string]$key.GetValue('Version', ''))
                if ($null -ne $version) { $version }
            }
        } finally {
            if ($null -ne $key) { $key.Dispose() }
            if ($null -ne $base) { $base.Dispose() }
        }
    }
}

function Get-XbSystemDllVersions {
    foreach ($name in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
        $path = Join-Path ([Environment]::SystemDirectory) $name
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) { return }
        Get-XbFileVersion $path
    }
}

function Test-XbRuntimeReady([version]$Minimum) {
    $registered = @(Get-XbRegisteredVersions | Where-Object { $_ -ge $Minimum })
    if ($registered.Count -eq 0) { return $false }
    $dlls = @(Get-XbSystemDllVersions)
    return $dlls.Count -eq 3 -and @($dlls | Where-Object { $_ -lt $Minimum }).Count -eq 0
}

function Invoke-XbRedist([string]$Path, [string]$Action, [string]$Log) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $Path
    $start.Arguments = "$Action /quiet /norestart /log `"$Log`""
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    $process = [Diagnostics.Process]::Start($start)
    try {
        if (!$process.WaitForExit(600000)) {
            # Do not kill Windows Installer halfway through a system update.
            # Stop this app installation and tell the user to wait/retry.
            return 4004
        }
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Install-XbRuntime($Config, [string]$Payload, [string]$Log) {
    $minimum = [version]$Config.minimumVersion
    $bundled = [version]$Config.bundledVersion
    if (Test-XbRuntimeReady $minimum) { return 0 }
    if (!(Test-XbPayloadHash $Payload $Config)) { return 4002 }
    $registered = @(Get-XbRegisteredVersions)
    # A damaged newer system runtime cannot be repaired by our older payload.
    if (@($registered | Where-Object { $_ -gt $bundled }).Count -gt 0) { return 4006 }
    $action = '/install'
    if (@($registered | Where-Object { $_ -eq $bundled }).Count -gt 0) { $action = '/repair' }
    $code = Invoke-XbRedist $Payload $action $Log
    # Never silently continue before reboot, even if the registry already changed.
    if ($code -eq 3010 -or $code -eq 1641) { return 3010 }
    # 1638 / HRESULT_FROM_WIN32(ERROR_PRODUCT_VERSION): another/newer installer
    # may have raced us. Only a fresh registry AND DLL check can accept it.
    if ($code -eq 0 -or $code -eq 1638 -or $code -eq -2147023258) {
        if (Test-XbRuntimeReady $minimum) { return 0 }
        return 4003
    }
    return $code
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if (![Environment]::Is64BitProcess -or [Environment]::OSVersion.Platform -ne 'Win32NT' -or
            [Environment]::OSVersion.Version.Major -lt 10) { exit 4001 }
        $config = Read-XbRuntimeConfig $ConfigPath
        Add-Content -LiteralPath ($LogPath + '.wrapper.txt') -Encoding UTF8 -Value (
            "VC prerequisite: minimum=$($config.minimumVersion); bundled=$($config.bundledVersion)")
        $code = Install-XbRuntime $config $PayloadPath $LogPath
        Add-Content -LiteralPath ($LogPath + '.wrapper.txt') -Encoding UTF8 -Value "Result=$code"
        exit $code
    } catch {
        # Separate wrapper log: never overwrite Microsoft's installation log.
        try { Add-Content -LiteralPath ($LogPath + '.wrapper.txt') -Value $_.Exception.Message -Encoding UTF8 } catch {}
        exit 4005
    }
}
