# Invoke-DiskReclaim.ps1 - reclaim the accumulators that never self-clean (Windows)
#
# SAFE BY DEFAULT: reports only. Nothing is removed unless you pass -Execute.
#
#   .\Invoke-DiskReclaim.ps1                                      # dry run
#   .\Invoke-DiskReclaim.ps1 -Execute                             # act
#   .\Invoke-DiskReclaim.ps1 -Execute -Quarantine D:\Quarantine   # MOVE, reversible
#   .\Invoke-DiskReclaim.ps1 -Only Installer                      # subset
#
# ---------------------------------------------------------------------------
# EDIT THE CONFIG BLOCK BELOW to match the machine. Defaults cover the common
# Windows offenders; add your own uncapped caches and auto-updating apps.
# ---------------------------------------------------------------------------
#
# WHY .NET ENUMERATION AND NOT Get-ChildItem -Recurse:
#   Get-ChildItem -Recurse silently returns ZERO files when any path in the tree
#   exceeds MAX_PATH - observed returning 0 for a real 39,277-file / 22.4 GB
#   cache. A cleanup script that reports "nothing to reclaim" on 22 GB of
#   garbage is worse than no script, so every walk here uses .NET with an
#   explicit empty-result guard.
#
# ENCODING: keep this file ASCII, or UTF-8 WITH BOM. PowerShell 5.1 reads a
#   UTF-8 no-BOM file as Windows-1252, turning an em-dash into a smart quote
#   that acts as a string delimiter - a dash in a COMMENT breaks parsing.

[CmdletBinding()]
param(
    [switch]$Execute,
    [string]$Quarantine = '',
    [ValidateSet('Installer','Caches','VersionFolders','CrashDumps')]
    [string[]]$Only
)

# ============================== CONFIG =====================================

# Uncapped caches. KeepDays = retain anything newer than this many days.
$CacheTargets = @(
    @{ Label='CapCutCache';   Path="$env:LOCALAPPDATA\CapCut\User Data\Cache"; KeepDays=30 }
    @{ Label='ResolveCache';  Path="$env:LOCALAPPDATA\Blackmagic Design\DaVinci Resolve\CacheClip"; KeepDays=30 }
    @{ Label='PlaywrightOld'; Path="$env:LOCALAPPDATA\ms-playwright";          KeepDays=90 }
    @{ Label='NpmCache';      Path="$env:LOCALAPPDATA\npm-cache";              KeepDays=60 }
    @{ Label='PipCache';      Path="$env:LOCALAPPDATA\pip\Cache";              KeepDays=60 }
)

# Apps whose auto-updater retains old app-x.y.z folders.
$VersionParents = @(
    "$env:LOCALAPPDATA\slack"
    "$env:LOCALAPPDATA\Discord"
    "$env:LOCALAPPDATA\Figma"
    "$env:LOCALAPPDATA\Notion"
)

# Crash dumps / error reports.
$DumpTargets = @(
    @{ Label='CrashDumps'; Path="$env:LOCALAPPDATA\CrashDumps";            KeepDays=14 }
    @{ Label='WER';        Path="$env:LOCALAPPDATA\Microsoft\Windows\WER"; KeepDays=14 }
)

# ===========================================================================

$ErrorActionPreference = 'SilentlyContinue'

# Shared Windows Installer detection (COM API + registry union). Fail LOUDLY if it is
# missing rather than silently falling back to a weaker inline check - a quiet
# downgrade in the script that DELETES is how you destroy a live package.
$helper = Join-Path $PSScriptRoot '_MsiReferenced.ps1'
if (-not (Test-Path $helper)) {
    Write-Error "Required helper not found: $helper (copy the whole scripts\windows folder, not one file)"
    exit 3
}
. $helper

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.IO;

public class Walker
{
    public class Entry { public string Path; public long Length; public DateTime MTime; }

    public static List<Entry> Files(string root)
    {
        var outp = new List<Entry>();
        var stack = new Stack<string>();
        stack.Push(root);
        while (stack.Count > 0)
        {
            string dir = stack.Pop();
            try {
                foreach (string f in Directory.EnumerateFiles(dir)) {
                    try {
                        var fi = new FileInfo(f);
                        if ((fi.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                        var e = new Entry();
                        e.Path = fi.FullName; e.Length = fi.Length; e.MTime = fi.LastWriteTime;
                        outp.Add(e);
                    } catch { }
                }
            } catch { }
            try {
                foreach (string d in Directory.EnumerateDirectories(dir)) {
                    try {
                        var di = new DirectoryInfo(d);
                        if ((di.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                        stack.Push(d);
                    } catch { }
                }
            } catch { }
        }
        return outp;
    }
}
'@

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
function Get-FreeGB { [math]::Round((Get-PSDrive C).Free / 1GB, 2) }
function Want($n) { return (-not $Only) -or ($Only -contains $n) }

function Remove-Set {
    param([string]$Label, [object[]]$Files, [double]$FolderTotalGB = -1)

    if (-not $Files -or $Files.Count -eq 0) {
        # Distinguish "genuinely clean" from "the walk failed".
        if ($FolderTotalGB -gt 1) {
            Write-Warning ("   0 files matched but folder holds {0} GB - enumeration is SUSPECT, not clean" -f $FolderTotalGB)
        } else { Write-Host "   nothing to reclaim" }
        return
    }

    $gb = [math]::Round((($Files | Measure-Object Length -Sum).Sum / 1GB), 2)
    Write-Host ("   {0} items, {1} GB" -f $Files.Count, $gb)
    if (-not $Execute) { Write-Host "   DRY RUN - pass -Execute to act"; return }

    $dest = $null
    if ($Quarantine) {
        $dest = Join-Path $Quarantine $Label
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        if (-not (Test-Path $dest)) { Write-Warning "   cannot create $dest - skipping"; return }
    }

    $ok = 0
    foreach ($f in $Files) {
        try {
            if ($dest) {
                $leaf = Split-Path $f.Path -Leaf
                $target = Join-Path $dest $leaf
                $n = 1
                while (Test-Path -LiteralPath $target) { $target = Join-Path $dest ("{0}_{1}" -f $n, $leaf); $n++ }
                Move-Item -LiteralPath $f.Path -Destination $target -Force -ErrorAction Stop
            } else {
                Remove-Item -LiteralPath $f.Path -Force -ErrorAction Stop
            }
            $ok++
        } catch { Write-Warning ("   could not remove {0}" -f $f.Path) }
    }
    Write-Host ("   {0} of {1} processed{2}" -f $ok, $Files.Count, $(if ($dest) { " -> $dest" } else { " (deleted)" }))
}

$before = Get-FreeGB
Write-Host ""
Write-Host ("C: free before: {0} GB" -f $before)
Write-Host ("mode: {0}{1}" -f $(if ($Execute) {'EXECUTE'} else {'DRY RUN'}), $(if ($Quarantine) {" (quarantine to $Quarantine)"} else {''}))

# ------------------------------------------------- 1. Windows Installer orphans
if (Want 'Installer') {
    Write-Host ""
    Write-Host "== Windows Installer orphans (superseded .msi/.msp patches) =="
    if (-not (Test-Elevated)) {
        Write-Host "   SKIPPED - needs an elevated session (C:\Windows\Installer is ACL-protected)."
    } else {
        # Detection is SHARED with Find-OrphanedInstallerFiles.ps1 (see _MsiReferenced.ps1):
        # Windows Installer COM API unioned with the registry hive. This script is the one
        # that DELETES, so it must never use weaker detection than the reporter.
        $ref = Get-MsiReferencedPackages

        Write-Host ("   Installer API {0} / registry {1} -> {2} packages in KEEP set  [scope: {3}]" -f `
                    $(if ($ref.ApiOk) { "$($ref.ApiCount)" } else { 'n/a' }),
                    $(if ($ref.RegOk) { "$($ref.RegCount)" } else { 'n/a' }),
                    $ref.Paths.Count, $ref.Scope)

        if ($ref.ApiOnly.Count -gt 0) {
            Write-Host ("   {0} package(s) known only to the Installer API - a registry-only tool would delete these" -f $ref.ApiOnly.Count)
        }

        # Without the API we cannot tell an APPLIED patch from a superseded one, and
        # deleting on registry evidence alone is exactly how live patches get removed.
        if (-not $ref.ApiOk) {
            Write-Warning "   Installer API unavailable - refusing to delete on registry evidence alone (cannot see patch state)"
        }
        # An empty union means BOTH sources failed, NOT that everything is orphaned.
        elseif (-not $ref.Trustworthy) {
            Write-Warning "   0 referenced packages from BOTH sources - REFUSING to classify anything as orphaned"
        } else {
            $orphans = [Walker]::Files('C:\Windows\Installer') |
                Where-Object { ($_.Path -match '\.(msi|msp)$') -and (-not $ref.Paths.Contains($_.Path)) }
            Remove-Set -Label 'WindowsInstaller' -Files $orphans
        }
    }
}

# ------------------------------------------------------------------ 2. Caches
if (Want 'Caches') {
    Write-Host ""
    Write-Host "== Uncapped caches =="
    foreach ($t in $CacheTargets) {
        if (-not (Test-Path $t.Path)) { continue }
        Write-Host ("-- {0}  ({1})" -f $t.Label, $t.Path)
        $all = [Walker]::Files($t.Path)
        $totalGB = [math]::Round((($all | Measure-Object Length -Sum).Sum / 1GB), 2)
        $cut = (Get-Date).AddDays(-$t.KeepDays)
        Write-Host ("   {0} files / {1} GB; keeping newer than {2:yyyy-MM-dd}" -f $all.Count, $totalGB, $cut)
        Remove-Set -Label $t.Label -Files ($all | Where-Object { $_.MTime -lt $cut }) -FolderTotalGB $totalGB
    }
}

# ---------------------------------------------------------- 3. Version folders
if (Want 'VersionFolders') {
    Write-Host ""
    Write-Host "== Retained old app versions =="

    # Every running process's directory - we never prune something in use.
    $runningDirs = @()
    foreach ($proc in (Get-Process)) {
        try { if ($proc.Path) { $runningDirs += (Split-Path $proc.Path -Parent) } } catch { }
    }
    $runningDirs = $runningDirs | Sort-Object -Unique

    $stale = @()
    foreach ($p in $VersionParents) {
        if (-not (Test-Path $p)) { continue }
        $vers = Get-ChildItem $p -Directory -Force | Where-Object { $_.Name -match '^app-\d' }
        if ($vers.Count -lt 2) { continue }

        # Sort by SEMANTIC VERSION, never LastWriteTime. Timestamps tie, and a tie
        # once deleted the LIVE application while keeping a 2 MB stub.
        $ranked = $vers | ForEach-Object {
            $v = $null
            [void][version]::TryParse(($_.Name -replace '^app-',''), [ref]$v)
            [PSCustomObject]@{ Dir=$_; Ver=$v }
        } | Where-Object { $_.Ver } | Sort-Object Ver -Descending

        if ($ranked.Count -lt 2) { continue }
        Write-Host ("   {0}: keeping {1}" -f (Split-Path $p -Leaf), $ranked[0].Dir.Name)

        foreach ($old in ($ranked | Select-Object -Skip 1)) {
            # Hard guard: a running process means IN USE, whatever the version says.
            if ($runningDirs | Where-Object { $_ -like ($old.Dir.FullName + '*') }) {
                Write-Host ("   {0}: IN USE by a running process - skipping" -f $old.Dir.Name)
                continue
            }
            $stale += [Walker]::Files($old.Dir.FullName)
        }
    }
    Remove-Set -Label 'OldAppVersions' -Files $stale
}

# ------------------------------------------------------------- 4. Crash dumps
if (Want 'CrashDumps') {
    Write-Host ""
    Write-Host "== Crash dumps / error reports =="
    foreach ($t in $DumpTargets) {
        if (-not (Test-Path $t.Path)) { continue }
        $all = [Walker]::Files($t.Path)
        $cut = (Get-Date).AddDays(-$t.KeepDays)
        Write-Host ("-- {0}: {1} files" -f $t.Label, $all.Count)
        Remove-Set -Label $t.Label -Files ($all | Where-Object { $_.MTime -lt $cut })
    }
}

$after = Get-FreeGB
$delta = [math]::Round($after - $before, 2)
Write-Host ""
Write-Host "======================================="
Write-Host ("C: free before : {0} GB" -f $before)
Write-Host ("C: free after  : {0} GB" -f $after)
Write-Host ("delta          : {0} GB" -f $delta)
Write-Host "======================================="

# One line per run so unattended scheduled runs stay auditable.
try {
    $line = '{0}  {1,-7}  before={2,8} GB  after={3,8} GB  reclaimed={4,7} GB  scope={5}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm'), $(if($Execute){'EXECUTE'}else{'DRYRUN'}),
            $before, $after, $delta, $(if ($Only) { $Only -join '+' } else { 'all' })
    Add-Content -Path (Join-Path $PSScriptRoot 'reclaim.log') -Value $line -Encoding ASCII
} catch { }
