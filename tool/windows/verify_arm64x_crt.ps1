# Inspect the app-local CRT as data. Do not load or execute the DLL.
param([Parameter(Mandatory=$true)][string]$Path)
$ErrorActionPreference = 'Stop'
$file = Get-Item -LiteralPath $Path
$sig = Get-AuthenticodeSignature -LiteralPath $file.FullName
if ($sig.Status -ne 'Valid' -or $sig.SignerCertificate.Subject -notmatch '(?:^|,\s*)O=Microsoft Corporation(?:,|$)' -or
    $file.VersionInfo.OriginalFilename -ne 'vcruntime140_1.dll') {
    throw 'Not an authenticated Microsoft vcruntime140_1.dll'
}
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
$dumpbin = $null
foreach ($hostTools in 'Hostarm64\arm64','Hostx64\x64') {
    $dumpbin = & $vswhere -latest -products '*' -find "VC\Tools\MSVC\**\bin\$hostTools\dumpbin.exe" | Select-Object -First 1
    if ($dumpbin) { break }
}
if (!$dumpbin) { throw 'Cannot inspect ARM64X: dumpbin not found' }
$env:VSLANG = '1033'
$report = & $dumpbin /headers /loadconfig $file.FullName
if ($LASTEXITCODE -ne 0 -or !($report -match '^\s*8664 machine \(x64\) \(ARM64X\)\s*$') -or
    !($report -match '^\s*0*[1-9A-F][0-9A-F]* Offset of Arm64X arm64x redirection metadata table\s*$')) {
    throw 'Missing ARM64X machine identity or redirection metadata'
}
