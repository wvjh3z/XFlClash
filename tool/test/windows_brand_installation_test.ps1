param([string]$Root = (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)))
$ErrorActionPreference = 'Stop'
. (Join-Path $Root 'tool/windows/stop_brand_installation.ps1') -LibraryOnly
$readProxy = ${function:Get-XbOwnedProxySnapshot}
$clearProxy = ${function:Clear-XbOwnedProxy}
$stopProcess = ${function:Stop-XbOwnedProcess}
function Assert($condition, $message) { if (-not $condition) { throw $message } }
$fixture = Join-Path ([IO.Path]::GetTempPath()) ('brand-stop-' + [guid]::NewGuid())
New-Item -ItemType Directory -Path $fixture | Out-Null
try {
    $script:stopped=@(); $script:removed=@(); $script:proxyCleared=@()
    function Get-XbInstallProcesses { $script:processes }
    function Get-XbOwnedProxySnapshot($Processes,[string]$Root) { return $null }
    function Clear-XbOwnedProxy($Snapshot) { $script:proxyCleared += $Snapshot }
    function Stop-XbOwnedProcess($Process,[string]$Root) { $script:stopped += $Process.ProcessId }
    function Get-XbInstallService([string]$Name) { return $script:service }
    function Remove-XbInstallService($Service) { $script:removed += $Service.Name }
    foreach($brand in @('OmoFly','Daishu')) {
        $rootDir=Join-Path $fixture $brand;New-Item -ItemType Directory -Path $rootDir | Out-Null
        $script:service=[pscustomobject]@{Name=($brand+'HelperService');State='Running';PathName=('"'+(Join-Path $rootDir ($brand+'HelperService.exe'))+'" run')}
        $script:processes=@(
            [pscustomobject]@{ProcessId=1;ExecutablePath=(Join-Path $rootDir ($brand+'.exe'))},
            [pscustomobject]@{ProcessId=2;ExecutablePath=(Join-Path $fixture 'Other/FlClash.exe')},
            [pscustomobject]@{ProcessId=3;ExecutablePath=$null},
            [pscustomobject]@{ProcessId=4;ExecutablePath=(Join-Path $fixture 'Other/OmoFly.exe')})
        $script:stopped=@();$script:removed=@()
        Stop-XbOwnedInstallation $rootDir ($brand+'HelperService')
        Assert ($script:stopped.Count -eq 1 -and $script:stopped[0] -eq 1) 'Another installation was stopped'
        Assert ($script:removed.Count -eq 1 -and $script:removed[0] -eq ($brand+'HelperService')) 'Wrong service removed'
        $script:service.PathName='"'+(Join-Path $fixture ('Other/'+$brand+'HelperService.exe'))+'"'
        $script:stopped=@();$script:removed=@();$failed=$false
        try { Stop-XbOwnedInstallation $rootDir ($brand+'HelperService') } catch { $failed=$true }
        Assert ($failed -and $script:stopped.Count -eq 0 -and $script:removed.Count -eq 0) 'Foreign helper must block cleanup'
        $script:service=$null
        [IO.File]::WriteAllText((Join-Path $rootDir 'FlClash.exe'),'upstream fixture')
        $failed=$false
        try { Stop-XbOwnedInstallation $rootDir ($brand+'HelperService') } catch { $failed=$true }
        Assert $failed 'Upstream installation directory was accepted'
    }
    Assert (-not (Test-XbOwnedImage (Join-Path $fixture 'FlClash.exe') $fixture)) 'Legacy upstream image was accepted'
    Assert (-not (Test-XbOwnedImage (Join-Path $fixture 'nested/OmoFly.exe') $fixture)) 'Nested foreign image was accepted'
    function Get-ItemProperty { [CmdletBinding()]param([string]$LiteralPath) return $script:settings }
    function Get-NetTCPConnection { [CmdletBinding()]param([string]$State,[int]$LocalPort) return $script:listeners }
    function Set-ItemProperty { [CmdletBinding()]param([string]$LiteralPath,[string]$Name,$Value) $script:writes++ }
    Add-Type -TypeDefinition 'public static class XbProxyNotification { public static int Writes=0; public static bool DisableProxy() { Writes++; return true; } public static bool InternetSetOption(System.IntPtr h,int o,System.IntPtr b,int l) { return true; } }'
    $script:settings=[pscustomobject]@{ProxyEnable=1;ProxyServer='127.0.0.1:17890'}
    $script:listeners=@([pscustomobject]@{OwningProcess=99});$script:writes=0
    $rootDir=Join-Path $fixture 'OmoFly'
    $ours=@([pscustomobject]@{ProcessId=1;ExecutablePath=(Join-Path $rootDir 'OmoFlyCore.exe')})
    Assert ($null -eq (& $readProxy $ours $rootDir)) 'Another process proxy was claimed'
    $script:listeners=@([pscustomobject]@{OwningProcess=1})
    $snapshot=& $readProxy $ours $rootDir
    Assert ($null -ne $snapshot) 'Owned proxy was not recognized'
    & $clearProxy $snapshot
    Assert ([XbProxyNotification]::Writes -eq 0) 'Live listener proxy was disabled'
    $script:listeners=@();$script:settings.ProxyServer='127.0.0.1:27890'
    & $clearProxy $snapshot
    Assert ([XbProxyNotification]::Writes -eq 0) 'Replacement proxy was disabled'
    $script:settings.ProxyServer='127.0.0.1:17890'
    & $clearProxy $snapshot
    Assert ([XbProxyNotification]::Writes -eq 1) 'Owned stopped proxy was not cleared'
    function Get-CimInstance { param($ClassName,$Filter) [pscustomobject]@{ProcessId=1;ExecutablePath=(Join-Path $fixture 'Other/Daishu.exe')} }
    function Stop-Process { [CmdletBinding()]param($Id,[switch]$Force) throw 'Foreign PID must not be stopped' }
    & $stopProcess $ours[0] $rootDir
    # Compile the actual WinINet interop without calling it; test setters above are fakes.
    $source=[IO.File]::ReadAllText((Join-Path $Root 'tool/windows/stop_brand_installation.ps1'),[Text.Encoding]::UTF8)
    $interop=[regex]::Match($source,"(?s)using System;.*?\r?\n'@").Value
    $interop=$interop.Substring(0,$interop.LastIndexOf("'@"))
    Add-Type -TypeDefinition $interop.Replace('XbProxyNotification','XbProxyNotificationCompileOnly')
    'PASS: both brands ownership, foreign service/directory refusal, PID recheck and proxy replacement guards'

} finally { Remove-Item -LiteralPath $fixture -Recurse -Force }
