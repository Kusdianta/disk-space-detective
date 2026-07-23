# Get-GrowthByMonth.ps1 - find MONTHLY ACCUMULATORS
# Buckets every file under -Root by (owning folder at -Depth levels, LastWriteTime month)
# and reports GB per month. A folder with a steady GB figure month after month is the
# thing that refills the disk. Reparse points are skipped.
#
# Usage: .\Get-GrowthByMonth.ps1 -Root 'C:\Users\<you>' -Depth 3
#
# NOTE: '|' is the key delimiter - it is illegal in Windows paths, so it can never
# collide with a folder name. (An earlier version used a `u{0001} escape, which
# PowerShell 5.1 does not understand; it split folder names on the letter "u".)

param(
    [Parameter(Mandatory = $true)][string]$Root,
    [int]$Depth = 3,
    [int]$Months = 10,
    [double]$MinGB = 0.4
)

$ErrorActionPreference = 'Stop'

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

public class GrowthScanner2
{
    public static Dictionary<string, long> Buckets     = new Dictionary<string, long>();
    public static Dictionary<string, long> MonthTotals = new Dictionary<string, long>();

    public static void Scan(string root, int depth)
    {
        int rootLen = root.TrimEnd('\\').Length;
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
                        if ((fi.Attributes & FileAttributes.ReparsePoint) != 0) { continue; }

                        string rel = fi.DirectoryName;
                        if (rel.Length > rootLen) { rel = rel.Substring(rootLen).TrimStart('\\'); }
                        else { rel = ""; }

                        string[] parts = rel.Split('\\');
                        int take = Math.Min(depth, parts.Length);
                        string owner = string.Join("\\", parts, 0, take);
                        if (owner.Length == 0) { owner = "(root files)"; }

                        string month = fi.LastWriteTime.ToString("yyyy-MM");
                        string key   = owner + "|" + month;

                        long cur;
                        Buckets.TryGetValue(key, out cur);
                        Buckets[key] = cur + fi.Length;

                        long mcur;
                        MonthTotals.TryGetValue(month, out mcur);
                        MonthTotals[month] = mcur + fi.Length;
                    }
                    catch { }
                }
            }
            catch { }

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
                    catch { }
                }
            }
            catch { }
        }
    }
}
'@

[GrowthScanner2]::Scan($Root, $Depth)

Write-Output "=== BYTES STILL ON DISK, BY MONTH LAST WRITTEN - under $Root ==="
Write-Output ''

$monthRows = foreach ($k in [GrowthScanner2]::MonthTotals.Keys) {
    [PSCustomObject]@{ Month = $k; GB = [math]::Round([GrowthScanner2]::MonthTotals[$k] / 1GB, 2) }
}
$monthRows | Sort-Object Month -Descending | Select-Object -First $Months | Format-Table -AutoSize

Write-Output ''
Write-Output "=== PER-FOLDER x MONTH (rows >= $MinGB GB) ==="
Write-Output ''

$cutoff = (Get-Date).AddMonths(-$Months).ToString('yyyy-MM')

$rows = foreach ($k in [GrowthScanner2]::Buckets.Keys) {
    $i = $k.LastIndexOf('|')
    $folder = $k.Substring(0, $i)
    $month  = $k.Substring($i + 1)
    $gb     = [GrowthScanner2]::Buckets[$k] / 1GB
    if ($gb -ge $MinGB -and $month -ge $cutoff) {
        [PSCustomObject]@{ Folder = $folder; Month = $month; GB = [math]::Round($gb, 2) }
    }
}

$byFolder = $rows | Group-Object Folder |
    Sort-Object { ($_.Group | Measure-Object GB -Sum).Sum } -Descending

foreach ($g in $byFolder) {
    $tot = [math]::Round((($g.Group | Measure-Object GB -Sum).Sum), 2)
    Write-Output ("--- {0}   [{1} GB in window]" -f $g.Name, $tot)
    $g.Group | Sort-Object Month -Descending | ForEach-Object {
        Write-Output ("       {0}   {1,8:N2} GB" -f $_.Month, $_.GB)
    }
    Write-Output ''
}
