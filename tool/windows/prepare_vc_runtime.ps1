# Called by ISPP for BOTH brands and local/CI packaging. No application build.
[CmdletBinding()]
param([string]$Root, [string]$Bundle, [switch]$DownloadOnly)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'vc_runtime.ps1')

function Test-XbCompilerPolicy([string]$BuildDirectory, $Config) {
    $files = @(Get-ChildItem -LiteralPath (Join-Path $BuildDirectory 'CMakeFiles') -Filter CMakeCXXCompiler.cmake -Recurse -File)
    if ($files.Count -ne 1) { throw 'Missing or ambiguous CMake compiler inventory; use a clean Windows build directory' }
    $text = Get-Content -LiteralPath $files[0].FullName -Raw
    if ($text -notmatch 'set\(CMAKE_CXX_COMPILER_ID "MSVC"\)' -or
        $text -notmatch 'set\(CMAKE_CXX_COMPILER_VERSION "(\d+\.\d+)\.\d+(?:\.\d+)?"\)') {
        throw 'Unrecognized Windows compiler; review VC runtime policy before packaging'
    }
    if ($Matches[1] -ne $Config.validatedCompilerFamily) {
        throw 'MSVC family changed; review minimumVersion and bundled runtime before packaging'
    }
    if ($text -notmatch 'set\(CMAKE_CXX_COMPILER "([^"\r\n]+)"\)') { throw 'Missing actual compiler path' }
    $compiler = $Matches[1].Replace('\', '/')
    if ($compiler -notmatch '^(.*)/Tools/MSVC/[^/]+/bin/Host[^/]+/x64/cl\.exe$') {
        throw 'Unknown MSVC x64 installation layout'
    }
    Assert-XbToolchainRuntime (Join-Path $Matches[1] 'Redist/MSVC') $Config
}

function Assert-XbToolchainRuntime([string]$Directory, $Config) {
    $family = '14.' + $Config.validatedCompilerFamily.Split('.')[1]
    $dlls = @(Get-ChildItem -Path (Join-Path $Directory ($family + '.*/x64/Microsoft.VC*.CRT/msvcp140.dll')) -File)
    if ($dlls.Count -eq 0) { throw 'Missing MSVC redistributable inventory; cannot validate minimum runtime' }
    foreach ($dll in $dlls) {
        $version = Get-XbFileVersion $dll.FullName
        if ($version.Major -ne 14 -or $version.Minor -ne [int]$family.Split('.')[1] -or
            $version -gt [version]$Config.minimumVersion) {
            throw 'Toolchain redistributable exceeds approved minimum; review policy before packaging'
        }
    }
}

function Test-XbBundleArchitecture([string]$Path) {
    $stream = [IO.File]::OpenRead((Join-Path $Path 'FlClash.exe'))
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { throw 'Not a PE executable' }
        $stream.Position = 0x3c; $offset = $reader.ReadInt32()
        if ($offset -lt 64 -or $offset -gt ($stream.Length - 6)) { throw 'Invalid PE offset' }
        $stream.Position = $offset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
            throw 'VC runtime policy currently covers only Windows x64'
        }
    } finally { $reader.Dispose(); $stream.Dispose() }
}

function Assert-XbMicrosoftPayload([string]$Path, $Config) {
    if (!(Test-XbPayloadHash $Path $Config)) { throw 'VC runtime size/hash mismatch' }
    $signature = Get-AuthenticodeSignature -LiteralPath $Path
    if ($signature.Status -ne 'Valid' -or $null -eq $signature.SignerCertificate -or
        $signature.SignerCertificate.Subject -notmatch '(^|,\s*)O=Microsoft Corporation(,|$)') {
        throw 'VC runtime must have a valid Microsoft Authenticode signature'
    }
    $version = Get-XbFileVersion $Path
    if ($version -ne [version]$Config.bundledVersion) { throw 'VC runtime file version mismatch' }
}

function Save-XbRuntimePayload([string]$Destination, $Config) {
    if (!(Test-XbPayloadHash $Destination $Config)) {
        $partial = $Destination + '.' + [guid]::NewGuid().ToString('N') + '.partial.exe'
        try {
            for ($attempt = 1; $attempt -le 3; $attempt++) {
                try {
                    Invoke-WebRequest -Uri $Config.url -OutFile $partial -UseBasicParsing -TimeoutSec 60 | Out-Null
                    break
                } catch {
                    $responseProperty = $_.Exception.PSObject.Properties['Response']
                    if ($null -ne $responseProperty -and $null -ne $responseProperty.Value) {
                        $status = [int]$responseProperty.Value.StatusCode
                        if ($status -ne 408 -and $status -ne 429 -and ($status -lt 500 -or $status -gt 599)) { throw }
                    }
                    if ($attempt -eq 3) { throw }
                    Start-Sleep -Seconds (5 * $attempt)
                }
            }
            # An invalid download is NOT retried as if it were a network failure.
            Assert-XbMicrosoftPayload $partial $Config
            Move-Item -LiteralPath $partial -Destination $Destination -Force
        } finally { Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue }
    }
    Assert-XbMicrosoftPayload $Destination $Config
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        if ([Environment]::OSVersion.Platform -ne 'Win32NT') { throw 'Packaging requires Windows Authenticode verification' }
        $Root = [IO.Path]::GetFullPath($Root)
        $config = Read-XbRuntimeConfig (Join-Path $Root 'tool/windows/vc_runtime.json')
        if (!$DownloadOnly) {
            Test-XbCompilerPolicy (Join-Path $Root 'build/windows/x64') $config
            Test-XbBundleArchitecture $Bundle
        }
        $directory = Join-Path $Root 'build/windows-prerequisites'
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Save-XbRuntimePayload (Join-Path $directory 'vc_redist.x64.exe') $config
        Write-Output "VC runtime verified: bundled $($config.bundledVersion), minimum $($config.minimumVersion)"
        exit 0
    } catch {
        Write-Error $_ -ErrorAction Continue
        exit 1
    }
}
