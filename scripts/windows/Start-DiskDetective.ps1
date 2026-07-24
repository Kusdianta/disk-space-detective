# Start-DiskDetective.ps1 - ONE COMMAND to diagnose a disk. READ-ONLY, always.
#
# This is the front door. It NEVER deletes, moves, or modifies anything.
# Reclaiming is a separate explicit step (Invoke-DiskReclaim.ps1).
#
#   .\Start-DiskDetective.ps1          # QUICK: known accumulators, ~1 min   <- start here
#   .\Start-DiskDetective.ps1 -Full    # exhaustive: ranks everything, MINUTES
#   .\Start-DiskDetective.ps1 -Full -Drive D:\
#
# WHY QUICK IS THE DEFAULT
# Ranking a whole drive by size means walking every file - unavoidable, and on a
# 190 GB profile with ~1.2M files that is several minutes PER PASS. The first
# version of this script did three such passes back-to-back and looked hung.
# Quick mode instead probes a curated list of the ~25 folders that actually cause
# this problem (documented in references\windows.md). It finds the culprit most of
# the time in a fraction of the work. -Full is there for when it does not.
#
# Run ELEVATED to include the Windows Installer cache - the most common hidden
# hoard on Windows. Unelevated it says so rather than implying a clean result.
#
# ASCII only + BOM (PowerShell 5.1 misparses UTF-8 no-BOM files).

[CmdletBinding()]
param(
    [string]$Drive = 'C:\',
    [switch]$Full,
    [int]$Top = 15,
    [double]$MinGB = 0.5,
    [double]$ProbeSeconds = 8     # per-folder time cap in QUICK mode
)

$ErrorActionPreference = 'SilentlyContinue'
$here = $PSScriptRoot
$sw   = [System.Diagnostics.Stopwatch]::StartNew()

function Rule { Write-Host ('-' * 74) }
function Head($t) { Write-Host ''; Write-Host ("== $t") -ForegroundColor Cyan; Write-Host '' }

$elevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
            ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$need = @('Get-FolderSize.ps1','Get-GrowthByMonth.ps1','Find-VersionFolders.ps1',
          'Find-OrphanedInstallerFiles.ps1','_MsiReferenced.ps1')
$missing = @($need | Where-Object { -not (Test-Path (Join-Path $here $_)) })
if ($missing.Count -gt 0) {
    Write-Warning ("Missing from {0}: {1}" -f $here, ($missing -join ', '))
    Write-Warning "Copy the WHOLE scripts\windows folder, not individual files."
    exit 3
}

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
public class QuickSize {
    public static long Skipped = 0;
    public static bool Partial = false;   // true => we ran out of time, total is a FLOOR

    // TIME-BOXED size. Sizing a folder means walking every file in it; a Chrome
    // profile or a Store-app data dir can be 60,000+ files and take minutes on its
    // own. Quick mode bounds each probe so the whole run stays predictable, and
    // marks any capped result as a floor (">= X GB") instead of reporting a number
    // that is silently too small - a wrong small number is worse than "at least".
    public static long Of(string root, int maxMs) {
        long total = 0; Skipped = 0; Partial = false;
        var sw = Stopwatch.StartNew();
        var stack = new Stack<string>(); stack.Push(root);
        while (stack.Count > 0) {
            if (sw.ElapsedMilliseconds > maxMs) { Partial = true; break; }
            string dir = stack.Pop();
            try { foreach (string f in Directory.EnumerateFiles(dir)) {
                    try { var fi = new FileInfo(f);
                          if ((fi.Attributes & FileAttributes.ReparsePoint) == 0) total += fi.Length;
                    } catch { Skipped++; } } } catch { Skipped++; }
            try { foreach (string d in Directory.EnumerateDirectories(dir)) {
                    try { var di = new DirectoryInfo(d);
                          if ((di.Attributes & FileAttributes.ReparsePoint) == 0) stack.Push(d);
                    } catch { Skipped++; } } } catch { Skipped++; }
        }
        return total;
    }
}
'@ -ErrorAction SilentlyContinue

Rule
Write-Host ' DISK SPACE DETECTIVE - read-only diagnosis' -ForegroundColor Green
Rule
$d = Get-PSDrive ($Drive.TrimEnd(':\'))
$freeGB  = [math]::Round($d.Free/1GB,2)
$totalGB = [math]::Round(($d.Used+$d.Free)/1GB,2)
$pct     = if ($totalGB -gt 0) { [math]::Round($freeGB/$totalGB*100,1) } else { 0 }
Write-Host ("  drive    : {0}" -f $Drive)
Write-Host ("  free     : {0} GB of {1} GB  ({2}% free)" -f $freeGB, $totalGB, $pct)
Write-Host ("  elevated : {0}{1}" -f $elevated, $(if(-not $elevated){'   <- re-run as Admin for the Installer cache'}else{''}))
Write-Host ("  mode     : {0}" -f $(if($Full){'FULL - walks the whole drive, takes MINUTES'}else{'QUICK - known accumulators only'}))
if ($pct -lt 10)     { Write-Host '  status   : CRITICAL - under 10% free' -ForegroundColor Red }
elseif ($pct -lt 20) { Write-Host '  status   : TIGHT - under 20% free'   -ForegroundColor Yellow }

# ======================================================================= QUICK
if (-not $Full) {

    # The curated suspect list. Each entry: what it is, and whether it comes back.
    #   CACHE  = regenerates, safe to clear, will refill (churn)
    #   RATCHET= grows and never shrinks on its own - the real target
    #   DATA   = real data, never auto-delete
    $suspects = @(
        @{ P="$env:LOCALAPPDATA\CapCut\User Data\Cache";        N='CapCut cache';          T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\Blackmagic Design";             N='DaVinci Resolve cache'; T='CACHE'   }
        @{ P="$env:APPDATA\Adobe\Common\Media Cache Files";     N='Adobe media cache (Pr/AE)'; T='CACHE' }
        @{ P="$env:APPDATA\Adobe\Common\Peak Files";            N='Adobe audio peaks';     T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\Google\Chrome\User Data";       N='Chrome profile+cache';  T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\Microsoft\Edge\User Data";      N='Edge profile+cache';    T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\npm-cache";                     N='npm cache';             T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\pip\Cache";                     N='pip cache';             T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\uv\cache";                      N='uv cache';              T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\Yarn\Cache";                    N='yarn cache';            T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\pnpm-store";                    N='pnpm store';            T='CACHE'   }
        @{ P="$env:USERPROFILE\.cargo\registry";                N='cargo registry';        T='CACHE'   }
        @{ P="$env:USERPROFILE\.gradle\caches";                 N='gradle caches';         T='CACHE'   }
        @{ P="$env:USERPROFILE\.nuget\packages";                N='NuGet packages';        T='CACHE'   }
        @{ P="$env:USERPROFILE\go\pkg\mod";                     N='Go module cache';       T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\ms-playwright";                 N='Playwright browsers';   T='RATCHET' }
        @{ P="$env:USERPROFILE\.cache\puppeteer";               N='Puppeteer browsers';    T='RATCHET' }
        @{ P="$env:LOCALAPPDATA\Temp";                          N='user TEMP';             T='CACHE'   }
        @{ P='C:\Windows\Temp';                                 N='Windows TEMP';          T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\CrashDumps";                    N='crash dumps';           T='CACHE'   }
        @{ P="$env:LOCALAPPDATA\Microsoft\Windows\WER";         N='error reports';         T='CACHE'   }
        @{ P='C:\Windows\SoftwareDistribution\Download';        N='Windows Update cache';  T='CACHE'   }
        @{ P='C:\Windows\Installer';                            N='MSI/MSP cache';         T='RATCHET' }
        @{ P="$env:LOCALAPPDATA\Docker\wsl";                    N='Docker WSL disk';       T='DATA'    }
        @{ P="$env:LOCALAPPDATA\Packages";                      N='Store/MSIX app data';   T='DATA'    }
        @{ P="$env:USERPROFILE\Downloads";                      N='Downloads';             T='DATA'    }
        @{ P="$env:USERPROFILE\.claude";                        N='Claude Code data';      T='DATA'    }
        @{ P="$env:APPDATA\Claude";                             N='Claude desktop data';   T='DATA'    }
    )

    Head ("1. KNOWN ACCUMULATORS   (max {0}s each, results stream as they finish)" -f [math]::Round($ProbeSeconds,0))
    $rows = @()
    $i = 0
    foreach ($s in $suspects) {
        $i++
        Write-Progress -Activity 'Probing known accumulators' -Status $s.N -PercentComplete (100*$i/$suspects.Count)
        if (-not (Test-Path -LiteralPath $s.P)) { continue }

        $bytes   = [QuickSize]::Of($s.P, [int]($ProbeSeconds*1000))
        $partial = [QuickSize]::Partial
        $gb      = [math]::Round($bytes/1GB, 2)
        if ($gb -lt 0.05) { continue }

        # Stream each hit immediately - a diagnostic that prints nothing for minutes
        # is indistinguishable from one that has hung.
        Write-Host ("   {0,8} GB  {1,-8} {2}" -f $(if($partial){">=$gb"}else{"$gb"}), $s.T, $s.N)
        $rows += [PSCustomObject]@{ GB=$gb; Kind=$s.T; What=$s.N; Path=$s.P; Partial=$partial }
    }
    Write-Progress -Activity 'Probing known accumulators' -Completed

    Write-Host ''
    if ($rows.Count -eq 0) {
        Write-Host 'None of the usual suspects are large on this machine.'
        Write-Host 'Run with -Full to rank everything instead.'
    } else {
        $rows | Sort-Object GB -Descending | Format-Table -AutoSize `
            @{n='GB';e={$(if($_.Partial){'>= '}else{'   '}) + ('{0,7:N2}' -f $_.GB)}},
            @{n='TYPE';e={$_.Kind}}, What, Path

        $sum     = [math]::Round((($rows | Measure-Object GB -Sum).Sum),2)
        $ratchet = [math]::Round((($rows | Where-Object {$_.Kind -eq 'RATCHET'} | Measure-Object GB -Sum).Sum),2)
        $cache   = [math]::Round((($rows | Where-Object {$_.Kind -eq 'CACHE'}   | Measure-Object GB -Sum).Sum),2)
        Write-Host ("  total in known accumulators        : {0} GB" -f $sum)
        Write-Host ("    CACHE   (comes back after clearing): {0} GB" -f $cache)
        Write-Host ("    RATCHET (never shrinks on its own) : {0} GB" -f $ratchet) -ForegroundColor Yellow
        if ($rows | Where-Object { $_.Partial }) {
            Write-Host ''
            Write-Host ('  ">=" means the probe hit its {0}s cap - that folder is AT LEAST that big.' -f [math]::Round($ProbeSeconds,0))
            Write-Host '  Raise it with -ProbeSeconds 30, or use -Full for exact numbers.'
        }
    }

    Head '2. RETAINED OLD APP VERSIONS'
    & (Join-Path $here 'Find-VersionFolders.ps1') -Roots "$env:LOCALAPPDATA","$env:APPDATA" -MaxDepth 3

} else {
# ======================================================================== FULL
    Head ("1. RANKED SIZES - top level of $Drive")
    Write-Host 'Walking every file. This is the slow part; a few minutes is normal.'
    Write-Host ''
    & (Join-Path $here 'Get-FolderSize.ps1') -Root $Drive -Top $Top

    Head '2. WHAT IS ACCUMULATING (bytes on disk, by month last written)'
    Write-Host 'Similar GB month after month = a RATCHET. Large files rewritten in place'
    Write-Host '(VM disks, databases) always show the current month - not real growth.'
    Write-Host ''
    & (Join-Path $here 'Get-GrowthByMonth.ps1') -Root $env:USERPROFILE -Depth 3 -Months 8 -MinGB $MinGB

    Head '3. RETAINED OLD APP VERSIONS'
    & (Join-Path $here 'Find-VersionFolders.ps1') `
        -Roots "$env:LOCALAPPDATA","$env:APPDATA","$env:ProgramFiles","${env:ProgramFiles(x86)}" -MaxDepth 4
}

# ------------------------------------------------------- installer (both modes)
Head '3. WINDOWS INSTALLER CACHE (the usual hidden hoard)'
if (-not $elevated) {
    Write-Host 'SKIPPED - C:\Windows\Installer is ACL-protected and needs an elevated shell.'
    Write-Host 'This is the most common hidden accumulator on Windows. Being unable to read'
    Write-Host 'it is NOT a clean bill of health - re-run as Administrator.'
} else {
    & (Join-Path $here 'Find-OrphanedInstallerFiles.ps1')
}

$sw.Stop()

# Emit FULL paths, never ".\something". The quickstart one-liner runs this script by
# absolute path, which leaves the shell sitting in C:\WINDOWS\system32 - so a relative
# command printed here resolves against system32 and fails with "not recognized".
$reclaim = Join-Path $here 'Invoke-DiskReclaim.ps1'
$selfPath = $PSCommandPath
$installer = Join-Path $here 'Install-DiskDetective.ps1'
$inTemp = $here -like "$env:TEMP*"

Write-Host ''
Rule
Write-Host (' WHAT TO DO NEXT       (scan took {0:N0}s)' -f $sw.Elapsed.TotalSeconds) -ForegroundColor Green
Rule
Write-Host ''
Write-Host '  1) PREVIEW a cleanup - still safe, changes nothing:'
Write-Host ''
Write-Host ("     & `"{0}`"" -f $reclaim) -ForegroundColor Yellow
Write-Host ''
Write-Host '  2) Then actually reclaim the space:'
Write-Host ''
Write-Host ("     & `"{0}`" -Execute" -f $reclaim) -ForegroundColor Yellow
Write-Host ''
Write-Host '     (or -Quarantine D:\Held to MOVE files instead of deleting them)'
Write-Host ''

if (-not $Full) {
    Write-Host '  Nothing obvious above? Rank every folder instead (slower):'
    Write-Host ''
    Write-Host ("     & `"{0}`" -Full" -f $selfPath) -ForegroundColor Yellow
    Write-Host ''
}
if (-not $elevated) {
    Write-Host '  Re-run elevated to include the Installer cache (often the big one):'
    Write-Host ''
    Write-Host ("     Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','{0}'" -f $selfPath) -ForegroundColor Yellow
    Write-Host ''
}

Rule
Write-Host ' KEEP IT CLEAN AUTOMATICALLY' -ForegroundColor Green
Rule
Write-Host ''
if ($inTemp) {
    Write-Host '  You are running from a TEMP folder - Windows will delete it eventually.' -ForegroundColor Yellow
    Write-Host '  Install it somewhere permanent and schedule a weekly cleanup (one command,'
    Write-Host '  run as Administrator):'
} else {
    Write-Host '  Schedule a weekly cleanup so this never builds up again (run as Admin):'
}
Write-Host ''
if (Test-Path $installer) {
    Write-Host ("     & `"{0}`"" -f $installer) -ForegroundColor Yellow
    Write-Host ''
    Write-Host '     Installs to C:\Tools\DiskDetective and registers a weekly task.'
    Write-Host '     Undo any time with:  -Uninstall'
} else {
    Write-Host '     (Install-DiskDetective.ps1 not found next to this script)'
}
Write-Host ''
Write-Host '  Large is not the same as wasted. See references\windows.md for what each'
Write-Host '  folder is before removing anything.'
Write-Host ''
