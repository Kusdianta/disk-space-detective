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
#
# Native = a tool's own cache cleaner. ALWAYS prefer it where one exists: it is
# orders of magnitude faster and the tool knows its own invariants. Deleting an
# npm cache file-by-file took ~17 minutes for 277,000 files on a real machine;
# `npm cache clean --force` is effectively instant. Native cleaners purge the
# WHOLE cache (KeepDays does not apply) - fine for pure churn caches that the
# tool re-populates on demand, wrong for anything you want partially retained.
$CacheTargets = @(
    @{ Label='CapCutCache';    Path="$env:LOCALAPPDATA\CapCut\User Data\Cache"; KeepDays=30 }
    @{ Label='ResolveCache';   Path="$env:LOCALAPPDATA\Blackmagic Design\DaVinci Resolve\CacheClip"; KeepDays=30 }
    # Adobe's SHARED media cache - Premiere, After Effects, Media Encoder and Audition
    # all pile into this one folder. The scanner already flagged it; until now the
    # reclaimer could not touch it (the same scanned-but-not-cleanable gap that hid
    # 36 GB of CapCut). KeepDays=30 so a current project's cache is not wiped - re-
    # caching footage is slow. (The tiny sibling "Media Cache" DB rebuilds itself.)
    @{ Label='AdobeMediaCache';Path="$env:APPDATA\Adobe\Common\Media Cache Files"; KeepDays=30 }
    @{ Label='PlaywrightOld';  Path="$env:LOCALAPPDATA\ms-playwright";          KeepDays=90 }
    @{ Label='NpmCache';       Path="$env:LOCALAPPDATA\npm-cache";              KeepDays=60; Native='npm cache clean --force'; AlsoPurge=@('_npx') }
    @{ Label='PipCache';       Path="$env:LOCALAPPDATA\pip\Cache";              KeepDays=60; Native='pip cache purge' }
)

# Editor scratch files that live at a FIXED, knowable path AND are only safe to
# remove while the app is closed. Kept separate from CacheTargets because each needs
# a "is the app running?" guard - deleting a live scratch file corrupts the session.
# NOTE what is deliberately NOT here: Photoshop's configured Scratch Disk and After
# Effects' Disk Cache both live at a USER-CHOSEN path the tool cannot read from
# outside the app. Those are a settings check, not an auto-clean - see references\windows.md.
$ScratchTargets = @(
    @{ Label='PhotoshopScratch'; Proc='Photoshop'; Pattern='Photoshop Temp*';
       Dirs=@("$env:TEMP", 'C:\') }
)

# Where to hunt for auto-updaters that retain old version folders.
#
# This used to be a hardcoded list of four apps (slack/Discord/Figma/Notion). On a
# real machine the DETECTOR found 36.6 GB of stale CapCut versions - 23 of them,
# C:\Users\<you>\AppData\Local\CapCut\Apps\8.7.0.3685 and friends - and the
# RECLAIMER ignored every one, because CapCut was not on the list. A cleanup tool
# that cannot act on what its own scanner reports is worse than useless.
#
# Now it discovers them: any folder holding 2+ version-named subdirectories is a
# candidate. Safety does not come from the whitelist, it comes from the guards -
# keep the highest SEMANTIC version, never touch one with a running process, and
# dry-run by default.
$VersionScanRoots = @(
    "$env:LOCALAPPDATA"
    "$env:APPDATA"
)
$VersionScanDepth = 3        # how deep under each root to look for version parents
$VersionMinGB     = 0.05     # ignore trivially small version stacks

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

    // Number of directories the LAST Files() call could not read (access denied,
    // path too long, ...). This is the DIRECT signal of an incomplete walk - read it
    // immediately after Files(), before the next Files() call overwrites it. It is
    // what lets the caller tell "correctly found nothing" (Skipped==0) from "the walk
    // was cut short" (Skipped>0) without guessing from file counts.
    public static long LastSkipped = 0;

    public static List<Entry> Files(string root)
    {
        var outp = new List<Entry>();
        long skipped = 0;
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
                    } catch { skipped++; }
                }
            } catch { skipped++; }
            try {
                foreach (string d in Directory.EnumerateDirectories(dir)) {
                    try {
                        var di = new DirectoryInfo(d);
                        if ((di.Attributes & FileAttributes.ReparsePoint) != 0) continue;
                        stack.Push(d);
                    } catch { skipped++; }
                }
            } catch { skipped++; }
        }
        LastSkipped = skipped;
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
    param([string]$Label, [object[]]$Files, [int]$RawCount = -1, [long]$Skipped = 0)

    if (-not $Files -or $Files.Count -eq 0) {
        # An empty delete list has three causes; only the first is a fault. We use the
        # walk's OWN report of how many entries it could not read (Skipped), not a guess
        # from file counts - that is what previously false-alarmed on "all files recent"
        # and again on "folder of empty subdirs".
        #   Skipped > 0            -> the walk was cut short (denied / long path) - the
        #                             Get-ChildItem-returned-0-on-22GB trap, made visible
        #   RawCount > 0           -> walk found files, none matched the age filter - fine
        #   RawCount = 0, Skipped 0 -> genuinely nothing to reclaim
        if ($Skipped -gt 0) {
            Write-Warning ("   walk could not read {0} entr(ies) (access denied / path too long) - result may be INCOMPLETE, not clean" -f $Skipped)
        } elseif ($RawCount -gt 0) {
            Write-Host "   nothing old enough to reclaim (all files newer than the cutoff)"
        } else {
            Write-Host "   nothing to reclaim"
        }
        return
    }

    $gb = [math]::Round((($Files | Measure-Object Length -Sum).Sum / 1GB), 2)
    Write-Host ("   {0} items, {1} GB" -f $Files.Count, $gb)

    # Accumulate what a dry run WOULD reclaim. Without this the log line is useless in
    # -DryRunOnly mode: nothing is deleted, so before/after are identical and reclaimed
    # is always 0 - i.e. the one number you need in order to decide whether to trust it
    # unattended was the one number the log did not record.
    $script:WouldReclaimGB += $gb
    $script:WouldReclaimN  += $Files.Count

    if (-not $Execute) { Write-Host "   DRY RUN - pass -Execute to act"; return }

    $dest = $null
    if ($Quarantine) {
        $dest = Join-Path $Quarantine $Label
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        if (-not (Test-Path $dest)) { Write-Warning "   cannot create $dest - skipping"; return }
    }

    $ok = 0

    # FAST PATH: collapse whole directories.
    # Per-file Remove-Item costs ~4ms; on a 277,000-file npm cache that is ~17 minutes.
    # Where every file under a directory is doomed, one recursive .NET delete replaces
    # thousands of calls. Only applies to deletes - quarantine still moves file by file
    # so the mapping back to original paths stays inspectable.
    if (-not $dest) {
        $doomed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
        foreach ($f in $Files) { [void]$doomed.Add($f.Path) }

        # A directory is fully doomed when nothing inside it survives.
        $dirs = $Files | ForEach-Object { Split-Path $_.Path -Parent } | Sort-Object -Unique
        $collapsible = @()
        foreach ($d in $dirs) {
            $survivor = $false
            foreach ($live in [Walker]::Files($d)) {
                if (-not $doomed.Contains($live.Path)) { $survivor = $true; break }
            }
            if (-not $survivor) { $collapsible += $d }
        }

        # Keep only top-most directories - deleting a parent removes its children.
        $tops = @()
        foreach ($d in ($collapsible | Sort-Object Length)) {
            $covered = $false
            foreach ($t in $tops) { if ($d.StartsWith($t + '\', [StringComparison]::OrdinalIgnoreCase)) { $covered = $true; break } }
            if (-not $covered) { $tops += $d }
        }

        # Count what ACTUALLY disappeared, not what we intended to remove. The old
        # version counted before deleting and only tallied on a clean return, so a
        # successful collapse could still report "0 of 28677 processed" while having
        # freed the space - alarming, and it makes the log untrustworthy.
        # before-minus-after is also correct when Delete throws part way through.
        foreach ($t in $tops) {
            $n = @([Walker]::Files($t)).Count
            try { [System.IO.Directory]::Delete($t, $true) } catch { }
            $left = if (Test-Path -LiteralPath $t) { @([Walker]::Files($t)).Count } else { 0 }
            $ok += [Math]::Max(0, $n - $left)
        }
        if ($tops.Count -gt 0) {
            Write-Host ("   collapsed {0} fully-doomed director(ies) into single deletes" -f $tops.Count)
        }
    }

    # Remainder: anything the fast path did not cover.
    foreach ($f in $Files) {
        if (-not (Test-Path -LiteralPath $f.Path)) { continue }   # already gone via collapse
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

$script:WouldReclaimGB = 0.0   # what a DRY RUN would have removed (see Remove-Set)
$script:WouldReclaimN  = 0

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
        $skipped = [Walker]::LastSkipped   # read immediately - the next Files() call overwrites it
        $totalGB = [math]::Round((($all | Measure-Object Length -Sum).Sum / 1GB), 2)
        $cut = (Get-Date).AddDays(-$t.KeepDays)

        # Native cleaner: whole-cache purge, but seconds instead of many minutes.
        if ($t.Native -and (Get-Command ($t.Native -split ' ')[0] -ErrorAction SilentlyContinue)) {
            Write-Host ("   {0} files / {1} GB  ->  native: {2}" -f $all.Count, $totalGB, $t.Native)
            if (-not $Execute) {
                Write-Host "   DRY RUN - pass -Execute to act"
            } else {
                $freeBefore = Get-FreeGB
                try {
                    cmd /c "$($t.Native) >nul 2>&1"
                    # A native cleaner may only touch PART of its cache dir. npm's
                    # `cache clean` clears _cacache but never _npx, so anything listed
                    # in AlsoPurge is nuked wholesale here (all regenerable churn).
                    foreach ($sub in @($t.AlsoPurge)) {
                        if (-not $sub) { continue }
                        $subPath = Join-Path $t.Path $sub
                        if (Test-Path -LiteralPath $subPath) {
                            try { [System.IO.Directory]::Delete($subPath, $true) }
                            catch { Write-Warning ("   could not purge {0}: {1}" -f $subPath, $_.Exception.Message) }
                        }
                    }
                    $freed = [math]::Round((Get-FreeGB) - $freeBefore, 2)
                    Write-Host ("   done - {0} GB freed{1}" -f $freed, $(if ($t.AlsoPurge) { " (incl. $($t.AlsoPurge -join ', '))" } else { '' }))
                } catch {
                    Write-Warning ("   native cleaner failed ({0}) - falling back to file-by-file" -f $_.Exception.Message)
                    Remove-Set -Label $t.Label -Files ($all | Where-Object { $_.MTime -lt $cut }) -RawCount $all.Count -Skipped $skipped
                }
            }
            continue
        }

        Write-Host ("   {0} files / {1} GB; keeping newer than {2:yyyy-MM-dd}" -f $all.Count, $totalGB, $cut)
        Remove-Set -Label $t.Label -Files ($all | Where-Object { $_.MTime -lt $cut }) -RawCount $all.Count -Skipped $skipped
    }

    # Editor scratch orphans. Photoshop cleans up its own scratch on a clean exit but
    # leaves "Photoshop Temp*" behind after a crash - those can reach tens of GB. Only
    # ever touched while the app is CLOSED: a live scratch file IS the running session.
    foreach ($s in $ScratchTargets) {
        if (Get-Process -Name $s.Proc -ErrorAction SilentlyContinue) {
            Write-Host ("-- {0}: {1} is running - skipping (its scratch file is live)" -f $s.Label, $s.Proc)
            continue
        }
        $orphans = @()
        foreach ($dir in $s.Dirs) {
            if (-not (Test-Path -LiteralPath $dir)) { continue }
            # Non-recursive on purpose: scratch files sit directly in TEMP or a drive root.
            $orphans += Get-ChildItem -LiteralPath $dir -Filter $s.Pattern -File -Force -ErrorAction SilentlyContinue |
                        ForEach-Object { [PSCustomObject]@{ Path=$_.FullName; Length=$_.Length } }
        }
        if ($orphans.Count -eq 0) { continue }
        $gb = [math]::Round((($orphans | Measure-Object Length -Sum).Sum / 1GB), 2)
        Write-Host ("-- {0}: {1} orphan(s), {2} GB  ({3} closed)" -f $s.Label, $orphans.Count, $gb, $s.Proc)
        Remove-Set -Label $s.Label -Files $orphans
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

    # Discover every parent holding 2+ version-named subdirs. Matches bare versions
    # (CapCut "8.7.0.3685", Blender "4.4") as well as the Squirrel "app-1.2.3" form -
    # the old code only matched app-*, which is why CapCut's 36 GB slipped through.
    $verRx = '^(app-|v|V|Update-|release-)?\d+\.\d+(\.\d+)*([-.+][A-Za-z0-9.]+)?$'
    $parents = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)

    foreach ($root in $VersionScanRoots) {
        if (-not (Test-Path $root)) { continue }
        $cur = @($root)
        for ($d = 0; $d -lt $VersionScanDepth -and $cur.Count -gt 0; $d++) {
            $next = @()
            foreach ($dir in $cur) {
                foreach ($sub in (Get-ChildItem -LiteralPath $dir -Directory -Force -ErrorAction SilentlyContinue)) {
                    if ($sub.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    if ($sub.Name -match $verRx) { [void]$parents.Add($dir) } else { $next += $sub.FullName }
                }
            }
            $cur = $next
        }
    }

    $stale = @()
    foreach ($p in $parents) {
        if (-not (Test-Path $p)) { continue }
        $vers = Get-ChildItem $p -Directory -Force | Where-Object { $_.Name -match $verRx }
        if ($vers.Count -lt 2) { continue }

        # Sort by SEMANTIC VERSION, never LastWriteTime. Timestamps tie, and a tie
        # once deleted the LIVE application while keeping a 2 MB stub.
        # Strip EVERY prefix the regex accepts - stripping only "app-" left "v1.2.3"
        # and "Update-1.2.3" unparseable, so those stacks were silently skipped.
        $ranked = $vers | ForEach-Object {
            $v = $null
            [void][version]::TryParse(($_.Name -replace '^(app-|v|V|Update-|release-)',''), [ref]$v)
            [PSCustomObject]@{ Dir=$_; Ver=$v }
        } | Where-Object { $_.Ver } | Sort-Object Ver -Descending

        if ($ranked.Count -lt 2) { continue }

        $parentStale = @()
        foreach ($old in ($ranked | Select-Object -Skip 1)) {
            # Hard guard: a running process means IN USE, whatever the version says.
            if ($runningDirs | Where-Object { $_ -like ($old.Dir.FullName + '*') }) {
                Write-Host ("   {0}\{1}: IN USE by a running process - skipping" -f (Split-Path $p -Leaf), $old.Dir.Name)
                continue
            }
            $parentStale += [Walker]::Files($old.Dir.FullName)
        }

        $pGB = [math]::Round((($parentStale | Measure-Object Length -Sum).Sum / 1GB), 2)
        if ($pGB -lt $VersionMinGB) { continue }

        Write-Host ("   {0,-28} keep {1,-16} prune {2,2} older = {3} GB" -f `
                    (Split-Path $p -Leaf), $ranked[0].Dir.Name, ($ranked.Count-1), $pGB)
        $stale += $parentStale
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
    # In EXECUTE the meaningful number is what was actually freed (drive delta). In
    # DRYRUN nothing moves, so report what WOULD be reclaimed instead - otherwise the
    # line reads "reclaimed 0 GB" and tells the operator nothing they can act on.
    $scope = $(if ($Only) { $Only -join '+' } else { 'all' })
    $line = if ($Execute) {
        '{0}  EXECUTE  before={1,8} GB  after={2,8} GB  reclaimed={3,7} GB  scope={4}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm'), $before, $after, $delta, $scope
    } else {
        '{0}  DRYRUN   free={1,8} GB  WOULD reclaim {2,7} GB in {3} item(s)  scope={4}' -f `
            (Get-Date -Format 'yyyy-MM-dd HH:mm'), $before,
            [math]::Round($script:WouldReclaimGB,2), $script:WouldReclaimN, $scope
    }
    Add-Content -Path (Join-Path $PSScriptRoot 'reclaim.log') -Value $line -Encoding ASCII
} catch { }
