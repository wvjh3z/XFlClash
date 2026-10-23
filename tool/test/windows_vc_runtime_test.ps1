# Executes production policy with OS/process boundaries replaced by fixtures.
# Runs on Windows PowerShell 5.1 and portable PowerShell on Linux. Never installs VC.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $repoRoot 'tool/windows/prepare_vc_runtime.ps1')
$config = Read-XbRuntimeConfig (Join-Path $repoRoot 'tool/windows/vc_runtime.json')
$minimum = [version]$config.minimumVersion
$bundled = [version]$config.bundledVersion
$passed = 0
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('xb-vc-test-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($fixture) | Out-Null
function Assert-Equal($Actual, $Expected) {
    if ($Actual -ne $Expected) { throw "Expected [$Expected], got [$Actual]" }
}
function Assert-Throws([scriptblock]$Body) {
    $threw = $false
    try { & $Body } catch { $threw = $true }
    if (!$threw) { throw 'Expected failure' }
}
function Case([string]$Name, [scriptblock]$Body) {
    & $Body
    $script:passed++
    Write-Output "PASS $Name"
}
try {
    Case 'numeric version comparison and optional v prefix' {
        Assert-Equal (ConvertTo-XbVersion 'v14.44.35211.0') $minimum
        Assert-Equal ((ConvertTo-XbVersion '14.9.99999.0') -lt $minimum) $true
        foreach ($bad in @('', '14.44', 'x14.44.35211.0', '14.44.35211.0extra', '-1.2.3.4', '99999999999.1.1.1')) {
            Assert-Equal ($null -eq (ConvertTo-XbVersion $bad)) $true
        }
    }
    Case 'invalid policy and inverted minimum fail closed' {
        $copy = $config | ConvertTo-Json | ConvertFrom-Json
        $copy.minimumVersion = '14.99.0.0'
        $path = Join-Path $fixture 'bad.json'
        $copy | ConvertTo-Json | Set-Content $path -Encoding UTF8
        Assert-Throws { Read-XbRuntimeConfig $path }
        $copy.minimumVersion = $config.minimumVersion
        $copy.url = 'http://example.com/VC_redist.x64.exe'
        $copy | ConvertTo-Json | Set-Content $path -Encoding UTF8
        Assert-Throws { Read-XbRuntimeConfig $path }
    }
    Case 'payload integrity includes exact size and hash' {
        $path = Join-Path $fixture 'payload'
        [IO.File]::WriteAllBytes($path, [byte[]](1,2,3))
        $copy = $config | ConvertTo-Json | ConvertFrom-Json
        $copy.size = 3; $copy.sha256 = (Get-FileHash $path).Hash
        Assert-Equal (Test-XbPayloadHash $path $copy) $true
        [IO.File]::WriteAllBytes($path, [byte[]](1,2,4))
        Assert-Equal (Test-XbPayloadHash $path $copy) $false
        [IO.File]::WriteAllBytes($path, [byte[]](1,2))
        Assert-Equal (Test-XbPayloadHash $path $copy) $false
        Assert-Equal (Test-XbPayloadHash ($path + '.missing') $copy) $false
    }
    # Exercise real readiness logic; never access host registry/System32.
    function Get-XbRegisteredVersions { $script:registry }
    function Get-XbSystemDllVersions { $script:dlls }
    Case 'missing registry or only x86 is not sufficient' {
        $script:registry = @(); $script:dlls = @($minimum, $minimum, $minimum)
        Assert-Equal (Test-XbRuntimeReady $minimum) $false
    }
    Case 'old registry is not sufficient' {
        $script:registry = @([version]'14.28.29913.0')
        Assert-Equal (Test-XbRuntimeReady $minimum) $false
    }
    Case 'minimum runtime is accepted though older than embedded payload' {
        $script:registry = @($minimum)
        Assert-Equal ($minimum -lt $bundled) $true
        Assert-Equal (Test-XbRuntimeReady $minimum) $true
    }
    Case 'newer runtime and either x64 registry view accepted' {
        $script:registry = @([version]'14.28.29913.0', [version]'14.60.1.0')
        $script:dlls = @([version]'14.60.1.0', [version]'14.60.1.0', [version]'14.60.1.0')
        Assert-Equal (Test-XbRuntimeReady $minimum) $true
    }
    Case 'registry alone cannot hide missing or outdated DLLs' {
        $script:registry = @($minimum); $script:dlls = @($minimum, $minimum)
        Assert-Equal (Test-XbRuntimeReady $minimum) $false
        $script:dlls = @($minimum, [version]'14.28.29913.0', $minimum)
        Assert-Equal (Test-XbRuntimeReady $minimum) $false
    }
    $realHashCheck = ${function:Test-XbPayloadHash}
    function Test-XbPayloadHash { $script:validHash }
    function Invoke-XbRedist($Path, $Action, $Log) {
        $script:invocations++; $script:actionSeen = $Action
        $script:registry = $script:afterRegistry; $script:dlls = $script:afterDlls
        return $script:installerCode
    }
    function Reset-Install {
        $script:registry = @(); $script:dlls = @(); $script:validHash = $true
        $script:afterRegistry = @($minimum); $script:afterDlls = @($minimum, $minimum, $minimum)
        $script:installerCode = 0; $script:invocations = 0; $script:actionSeen = ''
    }
    Case 'sufficient older runtime skips payload check and installer' {
        Reset-Install
        $script:registry = @($minimum); $script:dlls = @($minimum, $minimum, $minimum)
        $script:validHash = $false
        Assert-Equal (Install-XbRuntime $config 'unused' 'log') 0
        Assert-Equal $script:invocations 0
    }
    Case 'missing runtime installs and checks result' {
        Reset-Install
        Assert-Equal (Install-XbRuntime $config 'payload' 'log') 0
        Assert-Equal $script:invocations 1; Assert-Equal $script:actionSeen '/install'
    }
    Case 'old runtime upgrades' {
        Reset-Install; $script:registry = @([version]'14.28.29913.0')
        Assert-Equal (Install-XbRuntime $config 'payload' 'log') 0
        Assert-Equal $script:actionSeen '/install'
    }
    Case 'damaged equal embedded version repairs' {
        Reset-Install; $script:registry = @($bundled)
        Assert-Equal (Install-XbRuntime $config 'payload' 'log') 0
        Assert-Equal $script:actionSeen '/repair'
    }
    Case 'damaged newer runtime never downgrades' {
        Reset-Install; $script:registry = @([version]'14.60.1.0')
        Assert-Equal (Install-XbRuntime $config 'payload' 'log') 4006
        Assert-Equal $script:invocations 0
    }
    Case 'corrupt payload is never executed' {
        Reset-Install; $script:validHash = $false
        Assert-Equal (Install-XbRuntime $config 'payload' 'log') 4002
        Assert-Equal $script:invocations 0
    }
    Case 'success code without usable files is failure' {
        Reset-Install; $script:afterDlls = @()
        Assert-Equal (Install-XbRuntime $config 'payload' 'log') 4003
    }
    foreach ($code in @(1638, -2147023258)) {
        Case "already installed code $code requires successful recheck" {
            Reset-Install; $script:installerCode = $code
            Assert-Equal (Install-XbRuntime $config 'payload' 'log') 0
            Reset-Install; $script:installerCode = $code; $script:afterRegistry = @()
            Assert-Equal (Install-XbRuntime $config 'payload' 'log') 4003
        }
    }
    foreach ($code in @(3010, 1641)) {
        Case "reboot code $code blocks even with usable registry and files" {
            Reset-Install; $script:installerCode = $code
            Assert-Equal (Install-XbRuntime $config 'payload' 'log') 3010
        }
    }
    foreach ($code in @(1602,1603,1618,-2147023278,5,4004,777)) {
        Case "cancel/failure/busy/timeout $code is never swallowed" {
            Reset-Install; $script:installerCode = $code
            Assert-Equal (Install-XbRuntime $config 'payload' 'log') $code
        }
    }
    Case 'process launch exception propagates to wrapper failure' {
        Reset-Install
        function Invoke-XbRedist { throw 'blocked by policy' }
        Assert-Throws { Install-XbRuntime $config 'payload' 'log' }
    }
    # Packaging tests use a synthetic compiler inventory, never invoke a compiler.
    Case 'real compiler inventory selects approved family and redist directory' {
        $dir = Join-Path $fixture 'build with spaces/CMakeFiles/3.31'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $inventory = Join-Path $dir 'CMakeCXXCompiler.cmake'
        @"
set(CMAKE_CXX_COMPILER_ID "MSVC")
set(CMAKE_CXX_COMPILER_VERSION "19.44.35222.0")
set(CMAKE_CXX_COMPILER "$($fixture.Replace('\','/'))/VS/VC/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe")
"@ | Set-Content $inventory
        function Assert-XbToolchainRuntime($Directory, $Config) {
            if ($Directory.Replace('\','/') -ne ($fixture.Replace('\','/') + '/VS/VC/Redist/MSVC')) { throw 'wrong redist root' }
        }
        Test-XbCompilerPolicy (Split-Path (Split-Path $dir -Parent) -Parent) $config
        (Get-Content $inventory -Raw).Replace('19.44.35222.0','19.50.10000.0') | Set-Content $inventory
        Assert-Throws { Test-XbCompilerPolicy (Split-Path (Split-Path $dir -Parent) -Parent) $config }
    }
    Case 'missing compiler inventory blocks packaging' {
        Assert-Throws { Test-XbCompilerPolicy $fixture $config }
    }
    Case 'UTF8 CMake inventory preserves Chinese paths with BOM and LF or CRLF' {
        # Keep this .ps1 ASCII for Windows PowerShell 5.1 source decoding.
        $label = -join ([char[]]@(0x6d4b, 0x8bd5, 0x5de5, 0x5177))
        $buildDir = Join-Path $fixture ($label + ' build')
        $dir = Join-Path $buildDir 'CMakeFiles/3.31'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        $inventory = Join-Path $dir 'CMakeCXXCompiler.cmake'
        $vcRoot = Join-Path $fixture ($label + ' Visual Studio/VC')
        $redist = Join-Path $vcRoot 'Redist/MSVC/14.44.35211/x64/Microsoft.VC143.CRT'
        [IO.Directory]::CreateDirectory($redist) | Out-Null
        $expectedEncodingDll = Join-Path $redist 'msvcp140.dll'
        [IO.File]::WriteAllText($expectedEncodingDll, 'fixture')
        # Traverse the real derived directory; only file-version lookup is fake.
        function Get-XbFileVersion([string]$Path) {
            Assert-Equal ([IO.Path]::GetFullPath($Path)) ([IO.Path]::GetFullPath($expectedEncodingDll))
            return $minimum
        }
        $compilerPath = $vcRoot.Replace('\','/') + '/Tools/MSVC/14.44.35207/bin/Hostx64/x64/cl.exe'
        foreach ($bom in @($false, $true)) {
            foreach ($newline in @("`n", "`r`n")) {
                $text = @('set(CMAKE_CXX_COMPILER_ID "MSVC")',
                    'set(CMAKE_CXX_COMPILER_VERSION "19.44.35222.0")',
                    ('set(CMAKE_CXX_COMPILER "' + $compilerPath + '")')) -join $newline
                [IO.File]::WriteAllText($inventory, $text, (New-Object Text.UTF8Encoding($bom)))
                Test-XbCompilerPolicy $buildDir $config
            }
        }
        # Simulate the old ANSI misread even on hosts where Default is UTF-8.
        $utf8 = New-Object Text.UTF8Encoding($false)
        $wrong = [Text.Encoding]::GetEncoding(1252).GetString($utf8.GetBytes($text))
        if ($wrong -ceq $text) { throw 'negative control did not corrupt the Chinese path' }
        [IO.File]::WriteAllText($inventory, $wrong, $utf8)
        Assert-Throws { Test-XbCompilerPolicy $buildDir $config }
        # Compiler policy is still enforced after an encoding-correct read.
        [IO.File]::WriteAllText($inventory, $text.Replace('19.44.35222.0','19.50.10000.0'), $utf8)
        Assert-Throws { Test-XbCompilerPolicy $buildDir $config }
    }
    Case 'PE architecture guard accepts x64 and rejects x86 ARM64 and corrupt files' {
        $data = New-Object byte[] 128
        $data[0] = 0x4d; $data[1] = 0x5a; $data[60] = 64
        $data[64] = 0x50; $data[65] = 0x45; $data[68] = 0x64; $data[69] = 0x86
        $path = Join-Path $fixture 'FlClash.exe'
        [IO.File]::WriteAllBytes($path,$data); Test-XbBundleArchitecture $fixture
        foreach ($name in @('OmoFly.exe','Daishu.exe')) {
            $brandPath=Join-Path $fixture $name
            Move-Item -LiteralPath $path -Destination $brandPath
            Test-XbBundleArchitecture $fixture
            [IO.File]::WriteAllBytes($path,$data)
            Assert-Throws { Test-XbBundleArchitecture $fixture }
            Remove-Item -LiteralPath $brandPath
        }

        $data[68] = 0x4c; $data[69] = 0x01
        [IO.File]::WriteAllBytes($path,$data); Assert-Throws { Test-XbBundleArchitecture $fixture }
        $data[68] = 0x64; $data[69] = 0xaa
        [IO.File]::WriteAllBytes($path,$data); Assert-Throws { Test-XbBundleArchitecture $fixture }
        [IO.File]::WriteAllBytes($path,[byte[]](1,2,3)); Assert-Throws { Test-XbBundleArchitecture $fixture }
    }
    Case 'toolchain patch upgrade cannot silently keep an older minimum' {
        $dir = Join-Path $fixture 'redist/14.44.35211/x64/Microsoft.VC143.CRT'
        [IO.Directory]::CreateDirectory($dir) | Out-Null
        Set-Content (Join-Path $dir 'msvcp140.dll') 'fixture'
        function Get-XbFileVersion { $script:crtVersion }
        $script:crtVersion = $minimum
        Assert-XbToolchainRuntime (Join-Path $fixture 'redist') $config
        $script:crtVersion = [version]'14.44.99999.0'
        Assert-Throws { Assert-XbToolchainRuntime (Join-Path $fixture 'redist') $config }
        $script:crtVersion = [version]'14.43.1.0'
        Assert-Throws { Assert-XbToolchainRuntime (Join-Path $fixture 'redist') $config }
    }
    Case 'unsigned non-Microsoft and version-mismatched payloads are rejected' {
        $script:validHash = $true
        function Get-AuthenticodeSignature {
            [pscustomobject]@{ Status=$script:sigStatus; SignerCertificate=[pscustomobject]@{Subject=$script:sigSubject} }
        }
        function Get-XbFileVersion { $script:payloadVersion }
        $script:sigStatus = 'Valid'; $script:sigSubject = 'CN=Microsoft Corporation, O=Microsoft Corporation, C=US'
        $script:payloadVersion = $bundled
        Assert-XbMicrosoftPayload 'fixture' $config
        $script:sigStatus = 'NotSigned'
        Assert-Throws { Assert-XbMicrosoftPayload 'fixture' $config }
        $script:sigStatus = 'Valid'; $script:sigSubject = 'O=Other Corporation'
        Assert-Throws { Assert-XbMicrosoftPayload 'fixture' $config }
        $script:sigSubject = 'O=Microsoft Corporation'
        $script:payloadVersion = $minimum
        Assert-Throws { Assert-XbMicrosoftPayload 'fixture' $config }
    }
    Case 'download retries bounded network failures then verifies and caches' {
        $script:downloads = 0; $script:verifications = 0
        function Test-XbPayloadHash($Path, $Config) { Test-Path -LiteralPath $Path }
        function Invoke-WebRequest($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec) {
            Assert-Equal $TimeoutSec 60
            $script:downloads++
            if ($script:downloads -lt 3) { throw 'simulated timeout' }
            Set-Content -LiteralPath $OutFile 'fixture'
        }
        function Assert-XbMicrosoftPayload { $script:verifications++ }
        function Start-Sleep { }
        $path = Join-Path $fixture 'cached.exe'
        Save-XbRuntimePayload $path $config
        Assert-Equal $script:downloads 3
        Assert-Equal $script:verifications 2
        Save-XbRuntimePayload $path $config
        Assert-Equal $script:downloads 3
        Assert-Equal $script:verifications 3
    }
    Case 'persistent download failure cleans temporary file and stops after three' {
        $script:downloads = 0
        function Test-XbPayloadHash { $false }
        function Invoke-WebRequest($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec) {
            $script:downloads++; Set-Content -LiteralPath $OutFile 'partial'; throw 'simulated disconnect'
        }
        function Start-Sleep { }
        $path = Join-Path $fixture 'failed.exe'
        Assert-Throws { Save-XbRuntimePayload $path $config }
        Assert-Equal $script:downloads 3
        Assert-Equal (Test-Path $path) $false
        Assert-Equal @(Get-ChildItem $fixture -Filter 'failed.exe.*.partial.exe').Count 0
    }
    Case 'bad download signature or hash is not retried or published' {
        $script:downloads = 0
        function Test-XbPayloadHash { $false }
        function Invoke-WebRequest($Uri, $OutFile, [switch]$UseBasicParsing, $TimeoutSec) {
            $script:downloads++; Set-Content -LiteralPath $OutFile 'untrusted'
        }
        function Assert-XbMicrosoftPayload { throw 'integrity failure' }
        function Start-Sleep { throw 'must not retry' }
        $path = Join-Path $fixture 'invalid.exe'
        Assert-Throws { Save-XbRuntimePayload $path $config }
        Assert-Equal $script:downloads 1
        Assert-Equal (Test-Path $path) $false
        Assert-Equal @(Get-ChildItem $fixture -Filter 'invalid.exe.*.partial.exe').Count 0
    }
    Write-Output "Passed $passed VC runtime policy cases (no real registry writes or installers)."
} finally {
    Remove-Item -LiteralPath $fixture -Recurse -Force
}
exit 0
