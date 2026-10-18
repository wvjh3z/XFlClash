# Real process boundary tests. No registry writes, VC installation or networking.
# Windows CI runs in Windows PowerShell 5.1; local Linux uses portable pwsh.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tool/windows/vc_runtime.ps1')
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('xb process ' + [guid]::NewGuid().ToString('N'))
$payloadDir = Join-Path $fixture ([string][char]0x6d4b + [char]0x8bd5 + ' payload')
[IO.Directory]::CreateDirectory($payloadDir) | Out-Null
$originalCwd = [Environment]::CurrentDirectory
$isWin = [Environment]::OSVersion.Platform -eq 'Win32NT'
$passed = 0
function Assert-Equal($Actual, $Expected) {
    if ($Actual -cne $Expected) { throw "Expected [$Expected], got [$Actual]" }
}
function Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
try {
    $helper = Join-Path $payloadDir 'harmless-child.exe'
    if ($isWin) {
        # Compiles only a tiny test fixture, never client/native product code.
        Add-Type -OutputAssembly $helper -OutputType ConsoleApplication -TypeDefinition @'
using System;
using System.IO;
public class XbChild {
    public static int Main(string[] args) {
        if (args.Length != 5) return 91;
        File.WriteAllLines(args[4], new string[] {
            Environment.CurrentDirectory, args[0], args[1], args[2], args[3], args[4]
        });
        return args[0] == "/repair" ? 37 : 0;
    }
}
'@
    } else {
        # Same argument contract as the Windows fixture, with a real OS child.
        [IO.File]::WriteAllText($helper, @'
#!/bin/sh
[ "$#" = 5 ] || exit 91
printf '%s\n' "$PWD" "$1" "$2" "$3" "$4" "$5" > "$5"
[ "$1" = /repair ] && exit 37
exit 0
'@ + "`n", (New-Object Text.UTF8Encoding($false)))
        & chmod 700 $helper
        if ($LASTEXITCODE -ne 0) { throw 'fixture chmod failed' }
    }
    $record = Join-Path $fixture 'child report.txt'
    $script:XbRuntimeLog = Join-Path $fixture 'wrapper.txt'
    [Environment]::CurrentDirectory = $fixture
    Case 'real child receives payload directory and quoted Unicode/space arguments' {
        Assert-Equal (Invoke-XbRedist $helper '/install' $record) 0
        $lines = [IO.File]::ReadAllLines($record)
        Assert-Equal $lines.Length 6
        Assert-Equal $lines[0] $payloadDir
        Assert-Equal $lines[1] '/install'
        Assert-Equal $lines[2] '/quiet'
        Assert-Equal $lines[3] '/norestart'
        Assert-Equal $lines[4] '/log'
        Assert-Equal $lines[5] $record
        Assert-Equal ([Environment]::CurrentDirectory) $fixture
    }
    Case 'real child nonzero code survives launch and disposal' {
        Assert-Equal (Invoke-XbRedist $helper '/repair' $record) 37
    }
    Case 'invalid working directory negative control actually prevents child creation' {
        Remove-Item -LiteralPath $record
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = $helper
        $start.Arguments = "/install /quiet /norestart /log `"$record`""
        $start.UseShellExecute = $false
        $start.WorkingDirectory = Join-Path $fixture 'does not exist'
        if ($isWin) {
            # The exact alias from the bug is invalid for this x64 process.
            $start.WorkingDirectory = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0"
        }
        $failed = $false
        try {
            $p = [Diagnostics.Process]::Start($start)
            try { if (!$p.WaitForExit(30000)) { $p.Kill(); throw 'fixture timeout' } }
            finally { $p.Dispose() }
        } catch {
            $e = $_.Exception
            while ($null -ne $e.InnerException) { $e = $e.InnerException }
            if ($e -isnot [ComponentModel.Win32Exception]) { throw }
            if ($isWin) { Assert-Equal $e.NativeErrorCode 267 }
            else { Assert-Equal $e.NativeErrorCode 2 }
            $failed = $true
        }
        Assert-Equal $failed $true
        Assert-Equal (Test-Path -LiteralPath $record) $false
    }
    Case 'missing executable returns launch-specific code with native diagnostics' {
        Assert-Equal (Invoke-XbRedist (Join-Path $payloadDir 'missing.exe') '/install' $record) 4007
        $log = [IO.File]::ReadAllText($script:XbRuntimeLog)
        foreach ($pattern in @('stage=redist-launch', 'workingDirectory=', 'nativeError=', 'Win32Exception')) {
            if (!$log.Contains($pattern)) { throw "Missing diagnostic $pattern" }
        }
    }
    Case 'unwritable diagnostic target cannot replace a real child result' {
        $script:XbRuntimeLog = $fixture # Existing directory cannot be appended to.
        Assert-Equal (Invoke-XbRedist $helper '/repair' $record) 37
        $script:XbRuntimeLog = Join-Path $fixture 'wrapper.txt'
    }
    Case 'readiness logs both registry and DLL failures and preserves skip policy' {
        function Get-XbRegisteredVersions { [version]'14.28.29913.0' }
        function Get-XbSystemDllVersions { [version]'14.28.29913.0' }
        Assert-Equal (Test-XbRuntimeReady ([version]'14.44.35211.0')) $false
        $log = [IO.File]::ReadAllText($script:XbRuntimeLog)
        if (!$log.Contains('registryReady=False; filesReady=False')) { throw 'missing readiness reasons' }
        function Get-XbRegisteredVersions { [version]'14.44.35211.0' }
        function Get-XbSystemDllVersions { @([version]'14.44.35211.0') * 3 }
        $config = Read-XbRuntimeConfig (Join-Path $repoRoot 'tool/windows/vc_runtime.json')
        Assert-Equal (Install-XbRuntime $config 'must not be executed' $record) 0
        if (![IO.File]::ReadAllText($script:XbRuntimeLog).Contains('decision=skip')) { throw 'missing skip diagnostic' }
    }
    if ($isWin) {
        Case 'real wrapper reports policy-read exception separately from launch failure' {
            $badConfig = Join-Path $fixture 'invalid.json'
            [IO.File]::WriteAllText($badConfig, '{broken json')
            $wrapperLog = Join-Path $fixture 'bad-policy.log'
            $runtime = Join-Path $repoRoot 'tool/windows/vc_runtime.ps1'
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
            $start.WorkingDirectory = $fixture
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$runtime`" -ConfigPath `"$badConfig`" -PayloadPath `"$helper`" -LogPath `"$wrapperLog`""
            $p = [Diagnostics.Process]::Start($start)
            try {
                if (!$p.WaitForExit(30000)) { $p.Kill(); throw 'wrapper fixture timeout' }
                Assert-Equal $p.ExitCode 4008
            } finally { $p.Dispose() }
            $log = [IO.File]::ReadAllText($wrapperLog + '.wrapper.txt')
            if (!$log.Contains('stage=policy-read') -or !$log.Contains('Result=4008')) {
                throw 'missing wrapper exception diagnosis'
            }
        }
        Case 'x86 PowerShell launches x64 checker with real temp working directory' {
            if (![Environment]::Is64BitProcess) { throw 'CI test must start in x64 PowerShell' }
            # Exercise the WOW64 boundary with a harmless child. The production
            # Inno entry has the same explicit directory and real ISCC checks.
            $driver64 = Join-Path $fixture 'driver64.ps1'
            $driver32 = Join-Path $fixture 'driver32.ps1'
            $runtime = Join-Path $repoRoot 'tool/windows/vc_runtime.ps1'
            # Avoid interpolation of fixture paths into executable PowerShell code.
            @'
param($Runtime, $Helper, $Record)
$ErrorActionPreference = 'Stop'
if (![Environment]::Is64BitProcess) { exit 93 }
. $Runtime
exit (Invoke-XbRedist $Helper '/install' $Record)
'@ | Set-Content -LiteralPath $driver64 -Encoding UTF8
            @'
param($Driver, $Runtime, $Helper, $Record, $Work)
$ErrorActionPreference = 'Stop'
if ([Environment]::Is64BitProcess) { exit 94 }
$start = New-Object Diagnostics.ProcessStartInfo
$start.FileName = "$env:SystemRoot\Sysnative\WindowsPowerShell\v1.0\powershell.exe"
$start.WorkingDirectory = $Work
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$Driver`" -Runtime `"$Runtime`" -Helper `"$Helper`" -Record `"$Record`""
$p = [Diagnostics.Process]::Start($start)
try { if (!$p.WaitForExit(30000)) { $p.Kill(); exit 95 }; exit $p.ExitCode }
finally { $p.Dispose() }
'@ | Set-Content -LiteralPath $driver32 -Encoding UTF8
            Remove-Item -LiteralPath $record
            $start = New-Object Diagnostics.ProcessStartInfo
            $start.FileName = "$env:SystemRoot\SysWOW64\WindowsPowerShell\v1.0\powershell.exe"
            $start.WorkingDirectory = $fixture
            $start.UseShellExecute = $false
            $start.CreateNoWindow = $true
            $start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$driver32`" -Driver `"$driver64`" -Runtime `"$runtime`" -Helper `"$helper`" -Record `"$record`" -Work `"$fixture`""
            $p = [Diagnostics.Process]::Start($start)
            try {
                if (!$p.WaitForExit(45000)) { $p.Kill(); throw 'x86 driver timeout' }
                Assert-Equal $p.ExitCode 0
            } finally { $p.Dispose() }
            Assert-Equal ([IO.File]::ReadAllLines($record)[0]) $payloadDir
        }
    } else { Write-Output 'NOT RUN: native Windows wrapper and WOW64 hop (run in Windows CI).' }
    Write-Output "Passed $passed real-process/diagnostic cases; no VC installation."
} finally {
    [Environment]::CurrentDirectory = $originalCwd
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
exit 0
