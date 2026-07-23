# Find-VersionFolders.ps1 - detect RETAINED OLD VERSIONS (the monthly-accumulator tell)
#
# Looks for sibling directories whose names are version numbers (app-1.2.3, 1.2.3,
# v1.2.3, 1.2.3-build4) and reports every parent that holds MORE THAN ONE of them,
# newest first, with sizes. A parent holding 5 versions of an Electron app is 4
# versions of pure waste that comes back every auto-update.
#
# ASCII only + BOM: PowerShell 5.1 reads a UTF-8 no-BOM file as Windows-1252, which
# turns an em-dash into a smart quote and breaks string parsing.
#
# Usage: .\Find-VersionFolders.ps1 -Roots 'C:\Users\X\AppData\Local','C:\ProgramData'

param(
    [Parameter(Mandatory = $true)][string[]]$Roots,
    [int]$MaxDepth = 5,
    [double]$MinTotalGB = 0.05
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

public class VerScan
{
    public static long SizeOf(string root)
    {
        long total = 0;
        var stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            string dir = stack.Pop();
            try { foreach (string f in Directory.EnumerateFiles(dir)) {
                    try { var fi = new FileInfo(f);
                          if ((fi.Attributes & FileAttributes.ReparsePoint) == 0) total += fi.Length;
                    } catch { } } } catch { }
            try { foreach (string d in Directory.EnumerateDirectories(dir)) {
                    try { var di = new DirectoryInfo(d);
                          if ((di.Attributes & FileAttributes.ReparsePoint) == 0) stack.Push(d);
                    } catch { } } } catch { }
        }
        return total;
    }

    // Breadth-limited directory listing so we do not walk the whole disk.
    public static List<string> DirsToDepth(string root, int maxDepth)
    {
        var result = new List<string>();
        var cur = new List<string>(); cur.Add(root);
        for (int depth = 0; depth < maxDepth && cur.Count > 0; depth++)
        {
            var next = new List<string>();
            foreach (string dir in cur)
            {
                try { foreach (string d in Directory.EnumerateDirectories(dir)) {
                        try { var di = new DirectoryInfo(d);
                              if ((di.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                              result.Add(d); next.Add(d);
                        } catch { } } } catch { }
            }
            cur = next;
        }
        return result;
    }
}
'@

# app-1.2.3 / 1.2.3 / v1.2.3 / 1.2.3.4 / 1.2.3-beta.1 / Update-1.2.3
$verPattern = '^(app-|v|V|Update-|release-)?\d+\.\d+(\.\d+)*([-.+][A-Za-z0-9.]+)?$'

$found = @()

foreach ($root in $Roots) {
    if (-not (Test-Path -LiteralPath $root)) { Write-Output "SKIP (missing): $root"; continue }
    Write-Output "scanning: $root"

    $dirs = [VerScan]::DirsToDepth($root, $MaxDepth)

    # Group candidate version dirs by their parent.
    $byParent = @{}
    foreach ($d in $dirs) {
        $leaf = Split-Path $d -Leaf
        if ($leaf -match $verPattern) {
            $parent = Split-Path $d -Parent
            if (-not $byParent.ContainsKey($parent)) { $byParent[$parent] = New-Object System.Collections.ArrayList }
            [void]$byParent[$parent].Add($d)
        }
    }

    foreach ($parent in $byParent.Keys) {
        $kids = $byParent[$parent]
        if ($kids.Count -lt 2) { continue }   # one version = normal, not an accumulator

        $kidRows = foreach ($k in $kids) {
            $bytes = [VerScan]::SizeOf($k)
            [PSCustomObject]@{
                Name = (Split-Path $k -Leaf)
                GB   = [math]::Round($bytes / 1GB, 3)
                MTime = (Get-Item -LiteralPath $k -Force).LastWriteTime
            }
        }
        $tot = ($kidRows | Measure-Object GB -Sum).Sum
        if ($tot -lt $MinTotalGB) { continue }

        $found += [PSCustomObject]@{
            Parent   = $parent
            Count    = $kids.Count
            TotalGB  = [math]::Round($tot, 2)
            Kids     = ($kidRows | Sort-Object MTime -Descending)
        }
    }
}

Write-Output ''
Write-Output '=== PARENTS HOLDING MULTIPLE VERSION FOLDERS ==='
Write-Output ''

$reclaimTotal = 0
foreach ($f in ($found | Sort-Object TotalGB -Descending)) {
    Write-Output ("{0}" -f $f.Parent)
    Write-Output ("   {0} versions, {1} GB total" -f $f.Count, $f.TotalGB)
    $i = 0
    foreach ($k in $f.Kids) {
        $tag = if ($i -eq 0) { 'KEEP (newest)' } else { 'stale' }
        if ($i -gt 0) { $reclaimTotal += $k.GB }
        Write-Output ("      {0,-28} {1,8:N3} GB   {2:yyyy-MM-dd}   {3}" -f $k.Name, $k.GB, $k.MTime, $tag)
        $i++
    }
    Write-Output ''
}

Write-Output ("RECLAIMABLE if only the newest version of each is kept: {0:N2} GB" -f $reclaimTotal)
