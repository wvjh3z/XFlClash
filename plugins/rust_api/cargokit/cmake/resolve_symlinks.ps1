# Machine output consumed by CMake; works with Windows PowerShell 5.1 too.
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
function Resolve-Symlinks([string] $Path, [int] $Depth = 0) {
    if ($Depth -gt 40) { throw 'Too many symbolic links' }
    $full = [IO.Path]::GetFullPath($Path)
    $root = [IO.Path]::GetPathRoot($full)
    $real = $root
    $parts = $full.Substring($root.Length).Split([char[]]@('/', '\'), [StringSplitOptions]::RemoveEmptyEntries)
    foreach ($part in $parts) {
        $real = [IO.Path]::Combine($real, $part)
        $item = Get-Item -LiteralPath $real -Force -ErrorAction Stop
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            # Target is the PowerShell provider property available in 5.1;
            # LinkTarget is the newer .NET property. Do not use wildcard lookup.
            $targets = @($item.Target)
            if ($targets.Count -eq 0 -or !$targets[0]) { $targets = @($item.LinkTarget) }
            if ($targets.Count -ne 1 -or !$targets[0]) { throw 'Unsupported reparse point' }
            $target = [string]$targets[0]
            if (![IO.Path]::IsPathRooted($target)) {
                $target = [IO.Path]::Combine([IO.Path]::GetDirectoryName($real), $target)
            }
            $real = Resolve-Symlinks $target ($Depth + 1)
        }
    }
    return $real
}
try {
    if ($args.Count -ne 1 -or !$args[0]) { throw 'Expected exactly one path' }
    $resolved = Resolve-Symlinks $args[0]
    [Console]::Out.Write($resolved.Replace('\', '/'))
} catch {
    [Console]::Error.WriteLine("Cargokit path resolution failed: " + $_.Exception.Message)
    exit 1
}
