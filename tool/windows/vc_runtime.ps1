# Windows PowerShell 5.1 compatible. Dot-sourcing only defines functions for tests.
# No downloads or shared-runtime uninstall on the end user's machine.
[CmdletBinding()]
param([string]$ConfigPath, [string]$PayloadPath, [string]$LogPath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Diagnostic writes must never alter readiness results or a child exit code.
$script:XbRuntimeLog = $null
$script:XbRuntimeStage = 'initialization'
$script:XbRuntimeProtocol = $false
$script:XbRuntimeResultKind = 'checker'
$script:XbRuntimeRedistExit = $null
$script:XbRuntimeArchitecture = 'x64'

# Use Console rather than Write-Output: diagnostics must not join a function's
# return pipeline and turn an integer readiness/exit result into an array.
function Write-XbRuntimeProtocol([string]$Name, [string]$Value) {
    if (!$script:XbRuntimeProtocol) { return }
    try { [Console]::Out.WriteLine("XBVC_$Name=" + ($Value -replace '[\r\n]+', ' ')) }
    catch { } # A broken output pipe cannot change the prerequisite decision.
}

function Set-XbRuntimeStage([string]$Stage) {
    $script:XbRuntimeStage = $Stage
    Write-XbRuntimeProtocol 'STAGE' $Stage
}

function Write-XbRuntimeCompletion([int]$Code) {
    Write-XbRuntimeLog "Result=$Code"
    Write-XbRuntimeProtocol 'KIND' $script:XbRuntimeResultKind
    if ($null -ne $script:XbRuntimeRedistExit) {
        Write-XbRuntimeProtocol 'REDIST_EXIT' ([string]$script:XbRuntimeRedistExit)
    }
    Write-XbRuntimeProtocol 'RESULT' ([string]$Code)
}

function Write-XbRuntimeLog([string]$Message) {
    if ([string]::IsNullOrWhiteSpace($script:XbRuntimeLog)) { return }
    try {
        [IO.File]::AppendAllText($script:XbRuntimeLog,
            "stage=$script:XbRuntimeStage $Message" + [Environment]::NewLine,
            (New-Object Text.UTF8Encoding($false)))
    } catch { } # Logging failures cannot turn an installed runtime into failure.
}

function Write-XbRuntimeException($Exception) {
    try {
        $e = $Exception
        while ($null -ne $e.InnerException) { $e = $e.InnerException }
        $native = 'n/a'
        if ($e -is [ComponentModel.Win32Exception]) { $native = [string]$e.NativeErrorCode }
        $detail = "exception=$($e.GetType().FullName); nativeError=$native; message=" +
            ($e.Message -replace '[\r\n]+', ' ')
        Write-XbRuntimeLog $detail
        Write-XbRuntimeProtocol 'ERROR' $detail
    } catch {
        Write-XbRuntimeProtocol 'ERROR' 'Exception details unavailable'
    }
}

function ConvertTo-XbVersion([string]$Value) {
    if ($Value -notmatch '^v?(\d+\.\d+\.\d+\.\d+)$') { return $null }
    try { return [version]$Matches[1] } catch { return $null }
}

function Read-XbRuntimeConfig([string]$Path, [string]$Architecture = '') {
    $c = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($Architecture) {
        if ($Architecture -notin @('x64', 'arm64')) { throw 'Unsupported VC runtime target' }
        $c.architecture = $Architecture
        if ($Architecture -eq 'arm64') {
            $c.minimumVersion = $c.arm64Policy.minimumVersion
            $c.validatedCompilerFamily = $c.arm64Policy.validatedCompilerFamily
        }
    }
    $minimum = ConvertTo-XbVersion $c.minimumVersion
    $bundled = ConvertTo-XbVersion $c.bundledVersion
    if ($null -eq $minimum -or $null -eq $bundled -or $minimum.Major -ne 14 -or
        $bundled.Major -ne 14 -or $bundled -lt $minimum -or $c.architecture -notin @('x64', 'arm64') -or
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
            $key = $base.OpenSubKey('SOFTWARE\Microsoft\VisualStudio\14.0\VC\Runtimes\' + $script:XbRuntimeArchitecture)
            $installed = 0; $rawVersion = ''
            if ($null -ne $key) {
                $installed = $key.GetValue('Installed', 0)
                $rawVersion = [string]$key.GetValue('Version', '')
            }
            Write-XbRuntimeLog "registry=$view; architecture=$script:XbRuntimeArchitecture; installed=$installed; version=$rawVersion"
            if ($null -ne $key -and $installed -eq 1) {
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
        if (!(Test-Path -LiteralPath $path -PathType Leaf)) {
            Write-XbRuntimeLog "dll=$name; state=missing"
            continue
        }
        $version = Get-XbFileVersion $path
        Write-XbRuntimeLog "dll=$name; version=$version"
        $version
    }
}

function Test-XbRuntimeReady([version]$Minimum) {
    $registered = @(Get-XbRegisteredVersions)
    $dlls = @(Get-XbSystemDllVersions)
    $registryReady = @($registered | Where-Object { $_ -ge $Minimum }).Count -gt 0
    $filesReady = $dlls.Count -eq 3 -and @($dlls | Where-Object { $_ -lt $Minimum }).Count -eq 0
    Write-XbRuntimeLog ("readiness: minimum=$Minimum; registered=" + ($registered -join ',') +
        "; dllVersions=" + ($dlls -join ',') + "; registryReady=$registryReady; filesReady=$filesReady")
    return $registryReady -and $filesReady
}

function Invoke-XbRedist([string]$Path, [string]$Action, [string]$Log) {
    Set-XbRuntimeStage 'redist-launch'
    $script:XbRuntimeResultKind = 'redist-launch'
    $script:XbRuntimeRedistExit = $null
    $start = New-Object Diagnostics.ProcessStartInfo
    # Never inherit Sysnative (32-bit-only alias) or a deleted parent directory.
    # Production payload has already passed the mandatory size/hash check.
    $start.FileName = [IO.Path]::GetFullPath($Path)
    $start.WorkingDirectory = [IO.Path]::GetDirectoryName($start.FileName)
    $start.Arguments = "$Action /quiet /norestart /log `"$Log`""
    $start.UseShellExecute = $false
    $start.CreateNoWindow = $true
    Write-XbRuntimeLog "action=$Action; executable=$($start.FileName); workingDirectory=$($start.WorkingDirectory)"
    try { $process = [Diagnostics.Process]::Start($start) }
    catch {
        Write-XbRuntimeException $_.Exception
        return 4007
    }
    Set-XbRuntimeStage 'redist-wait'
    try {
        if (!$process.WaitForExit(600000)) {
            # Do not kill Windows Installer halfway through a system update.
            # Stop this app installation and tell the user to wait/retry.
            Write-XbRuntimeLog 'result=timeout; child not terminated'
            $script:XbRuntimeResultKind = 'redist-timeout'
            return 4004
        }
        Write-XbRuntimeLog "redistExitCode=$($process.ExitCode)"
        $script:XbRuntimeRedistExit = $process.ExitCode
        $script:XbRuntimeResultKind = 'redist-exit'
        return $process.ExitCode
    } finally { $process.Dispose() }
}

function Install-XbRuntime($Config, [string]$Payload, [string]$Log) {
    $script:XbRuntimeArchitecture = $Config.architecture
    $script:XbRuntimeRedistExit = $null
    $minimum = [version]$Config.minimumVersion
    $bundled = [version]$Config.bundledVersion
    Set-XbRuntimeStage 'readiness-before'
    $script:XbRuntimeResultKind = 'checker'
    if (Test-XbRuntimeReady $minimum) {
        Write-XbRuntimeLog 'decision=skip; existing runtime meets minimum'
        $script:XbRuntimeResultKind = 'ready'
        return 0
    }
    Set-XbRuntimeStage 'payload-validation'
    $script:XbRuntimeResultKind = 'payload'
    if (!(Test-XbPayloadHash $Payload $Config)) {
        Write-XbRuntimeLog 'decision=stop; payload size/hash mismatch'
        return 4002
    }
    $registered = @(Get-XbRegisteredVersions)
    # A damaged newer system runtime cannot be repaired by our older payload.
    if (@($registered | Where-Object { $_ -gt $bundled }).Count -gt 0) {
        Write-XbRuntimeLog 'decision=stop; newer registered runtime needs repair; no downgrade'
        $script:XbRuntimeResultKind = 'newer-runtime'
        return 4006
    }
    $action = '/install'
    if (@($registered | Where-Object { $_ -eq $bundled }).Count -gt 0) { $action = '/repair' }
    Write-XbRuntimeLog "decision=$action"
    $code = Invoke-XbRedist $Payload $action $Log
    # Never silently continue before reboot, even if the registry already changed.
    if ($code -eq 3010 -or $code -eq 1641) {
        $script:XbRuntimeResultKind = 'reboot'
        return 3010
    }
    # 1638 / HRESULT_FROM_WIN32(ERROR_PRODUCT_VERSION): another/newer installer
    # may have raced us. Only a fresh registry AND DLL check can accept it.
    if ($code -eq 0 -or $code -eq 1638 -or $code -eq -2147023258) {
        Set-XbRuntimeStage 'readiness-after'
        $script:XbRuntimeResultKind = 'verification'
        if (Test-XbRuntimeReady $minimum) {
            $script:XbRuntimeResultKind = 'ready'
            return 0
        }
        return 4003
    }
    return $code
}

if ($MyInvocation.InvocationName -ne '.') {
    $script:XbRuntimeProtocol = $true
    $script:XbRuntimeLog = $LogPath + '.wrapper.txt'
    try {
        Set-XbRuntimeStage 'initialization'
        Write-XbRuntimeLog "process64=$([Environment]::Is64BitProcess); os=$([Environment]::OSVersion.Version)"
        Write-XbRuntimeProtocol 'HOST' "process64=$([Environment]::Is64BitProcess); os=$([Environment]::OSVersion.Version); powershell=$($PSVersionTable.PSVersion); languageMode=$($ExecutionContext.SessionState.LanguageMode)"
        if (![Environment]::Is64BitProcess -or [Environment]::OSVersion.Platform -ne 'Win32NT' -or
            [Environment]::OSVersion.Version.Major -lt 10) {
            $script:XbRuntimeResultKind = 'platform'
            Write-XbRuntimeCompletion 4001
            exit 4001
        }
        Set-XbRuntimeStage 'policy-read'
        $script:XbRuntimeResultKind = 'checker'
        $config = Read-XbRuntimeConfig $ConfigPath
        $nativeArchitecture = $env:PROCESSOR_ARCHITEW6432
        if ([string]::IsNullOrEmpty($nativeArchitecture)) { $nativeArchitecture = $env:PROCESSOR_ARCHITECTURE }
        if ($config.architecture -eq 'arm64' -and $nativeArchitecture -ne 'ARM64') {
            $script:XbRuntimeResultKind = 'platform'
            Write-XbRuntimeCompletion 4001
            exit 4001
        }
        Write-XbRuntimeLog "VC prerequisite: minimum=$($config.minimumVersion); bundled=$($config.bundledVersion)"
        $code = Install-XbRuntime $config $PayloadPath $LogPath
        Write-XbRuntimeCompletion $code
        exit $code
    } catch {
        Write-XbRuntimeException $_.Exception
        $script:XbRuntimeResultKind = 'checker'
        Write-XbRuntimeCompletion 4008
        exit 4008
    }
}
