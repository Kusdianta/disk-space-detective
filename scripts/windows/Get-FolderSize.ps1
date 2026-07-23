# Get-FolderSize.ps1 - robust directory sizing
#   * uses .NET enumeration (no PowerShell pipeline overhead)
#   * SKIPS reparse points (junctions/symlinks) so nothing is double counted
#   * tolerates access-denied and long paths, and REPORTS how much it could not read
# Usage: .\Get-FolderSize.ps1 -Root C:\  [-Top 30]

param(
    [Parameter(Mandatory = $true)][string]$Root,
    [int]$Top = 30
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

public class FolderSizer
{
    public static long DeniedCount = 0;
    public static long FileCount   = 0;

    // Walk a directory tree iteratively. Reparse points are never descended into,
    // which is what stops junctions (C:\Users\All Users -> C:\ProgramData) from
    // being counted twice.
    public static long SizeOf(string root)
    {
        long total = 0;
        var stack = new Stack<string>();
        stack.Push(root);

        while (stack.Count > 0)
        {
            string dir = stack.Pop();

            try
            {
                foreach (string f in Directory.EnumerateFiles(dir))
                {
                    try
                    {
                        var fi = new FileInfo(f);
                        // A file-level reparse point has no real bytes here.
                        if ((fi.Attributes & FileAttributes.ReparsePoint) != 0) { continue; }
                        total += fi.Length;
                        FileCount++;
                    }
                    catch { DeniedCount++; }
                }
            }
            catch { DeniedCount++; }

            try
            {
                foreach (string d in Directory.EnumerateDirectories(dir))
                {
                    try
                    {
                        var di = new DirectoryInfo(d);
                        if ((di.Attributes & FileAttributes.ReparsePoint) != 0) { continue; }
                        stack.Push(d);
                    }
                    catch { DeniedCount++; }
                }
            }
            catch { DeniedCount++; }
        }

        return total;
    }

    public static void Reset() { DeniedCount = 0; FileCount = 0; }
}
'@

$rows = @()

# Files sitting directly in the root (pagefile.sys and friends).
try {
    $rootFiles = [System.IO.Directory]::EnumerateFiles($Root)
    foreach ($f in $rootFiles) {
        try {
            $fi = New-Object System.IO.FileInfo $f
            if ($fi.Length -ge 100MB) {
                $rows += [PSCustomObject]@{
                    Path    = $fi.FullName
                    GB      = [math]::Round($fi.Length / 1GB, 2)
                    Files   = 1
                    Denied  = 0
                    Kind    = 'file'
                }
            }
        } catch { }
    }
} catch { }

# Immediate subdirectories.
try {
    $dirs = [System.IO.Directory]::EnumerateDirectories($Root)
} catch {
    Write-Error "Cannot enumerate $Root : $_"
    exit 1
}

foreach ($d in $dirs) {
    $di = $null
    try { $di = New-Object System.IO.DirectoryInfo $d } catch { continue }

    # Report junctions but never measure them - the target is measured on its own.
    if (($di.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
        $rows += [PSCustomObject]@{
            Path = $di.FullName; GB = 0; Files = 0; Denied = 0; Kind = 'junction(skipped)'
        }
        continue
    }

    [FolderSizer]::Reset()
    $bytes = [FolderSizer]::SizeOf($d)
    $rows += [PSCustomObject]@{
        Path   = $di.FullName
        GB     = [math]::Round($bytes / 1GB, 2)
        Files  = [FolderSizer]::FileCount
        Denied = [FolderSizer]::DeniedCount
        Kind   = 'dir'
    }
}

$rows | Sort-Object GB -Descending | Select-Object -First $Top |
    Format-Table -AutoSize @{n = 'GB'; e = { '{0,8:N2}' -f $_.GB } }, Path, Files, Denied, Kind

$sum = ($rows | Measure-Object -Property GB -Sum).Sum
Write-Output ''
Write-Output ("MEASURED TOTAL under {0}: {1:N2} GB" -f $Root, $sum)
Write-Output ("Access-denied nodes    : {0}" -f (($rows | Measure-Object -Property Denied -Sum).Sum))
