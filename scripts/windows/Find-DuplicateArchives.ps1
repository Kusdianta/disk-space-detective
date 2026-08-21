# Find-DuplicateArchives.ps1 - archives whose contents are ALREADY on disk, or that
# are byte-identical to another archive. READ-ONLY: reports, never deletes.
#
#   .\Find-DuplicateArchives.ps1                       # scans Downloads
#   .\Find-DuplicateArchives.ps1 -Dir D:\Incoming
#   .\Find-DuplicateArchives.ps1 -OutFile list.txt     # safe list, one path per line
#
# WHY THIS EXISTS
# Downloading a folder from Google Drive gives you a .zip; extracting it leaves BOTH
# on disk forever. On a real machine this was 3.25 GB of already-extracted archives
# plus a 1.06 GB file downloaded twice nine days apart - 4.31 GB total, none of which
# any cache cleaner would ever look at, because a .zip in Downloads is "user data".
#
# TWO INDEPENDENT CHECKS
#   1. EXTRACTED - every entry in the archive exists on disk at the same uncompressed
#      size. Only then is the archive redundant.
#   2. IDENTICAL - two archives with the same size AND the same SHA-256. Same file
#      downloaded twice; one copy is waste.
#
# SAFETY: an archive is reported safe only when EVERY entry is accounted for. One
# missing or size-mismatched entry disqualifies the whole archive, because a
# partially-extracted archive is exactly the case where deleting loses data.
# Only the central directory is read (entry names + sizes), never the compressed
# bytes, so a 3 GB archive costs milliseconds.
#
# ASCII only + BOM (PowerShell 5.1 misparses UTF-8 no-BOM files).

[CmdletBinding()]
param(
    [string]$Dir = (Join-Path $env:USERPROFILE 'Downloads'),
    [string]$OutFile = '',
    [switch]$SkipHash          # skip the identical-archive pass (hashing is I/O heavy)
)

$ErrorActionPreference = 'SilentlyContinue'
Add-Type -AssemblyName System.IO.Compression.FileSystem

if (-not (Test-Path -LiteralPath $Dir)) { Write-Warning "not found: $Dir"; exit 1 }

$zips = Get-ChildItem -LiteralPath $Dir -Filter *.zip -File -Force
if (-not $zips) { Write-Host "No .zip archives in $Dir"; exit 0 }

Write-Host ("Checking {0} archive(s) in {1}" -f $zips.Count, $Dir)
Write-Host ''

$safe = @(); $keep = @()

# ---------------------------------------------------------------- 1. extracted?
foreach ($z in $zips) {
    # Google Drive / Takeout style: "<name>-20260731T155152Z-1-002.zip" -> "<name>"
    $base = [IO.Path]::GetFileNameWithoutExtension($z.Name)
    $base = $base -replace '-\d{8}T\d{6}Z-\d+-\d+$',''
    $base = $base -replace '\s*\(\d+\)$',''

    # An archive may extract into a wrapper folder OR flat into the same directory.
    # Checking only the wrapper would wrongly spare archives already unpacked beside it.
    $target     = Join-Path $Dir $base
    $haveFolder = Test-Path -LiteralPath $target
    if (-not $haveFolder) { $target = $Dir }

    $missing = 0; $mismatch = 0; $checked = 0
    try {
        $arch = [IO.Compression.ZipFile]::OpenRead($z.FullName)
        foreach ($e in $arch.Entries) {
            if ($e.FullName.EndsWith('/')) { continue }      # directory entry
            $checked++
            $rel = $e.FullName -replace '/','\'
            $hit = $null
            foreach ($cand in @((Join-Path $target $rel), (Join-Path $Dir $rel))) {
                if (Test-Path -LiteralPath $cand) { $hit = $cand; break }
            }
            if (-not $hit) { $missing++; continue }
            if ((Get-Item -LiteralPath $hit).Length -ne $e.Length) { $mismatch++ }
        }
        $arch.Dispose()
    } catch {
        $keep += [PSCustomObject]@{ GB=[math]::Round($z.Length/1GB,2); Archive=$z.Name; Reason='unreadable archive'; Path=$z.FullName }
        continue
    }

    if ($checked -eq 0) {
        $keep += [PSCustomObject]@{ GB=[math]::Round($z.Length/1GB,2); Archive=$z.Name; Reason='empty archive'; Path=$z.FullName }
    } elseif ($missing -eq 0 -and $mismatch -eq 0) {
        $where = if ($haveFolder) { $base } else { '(flat)' }
        $safe += [PSCustomObject]@{ GB=[math]::Round($z.Length/1GB,2); Archive=$z.Name; Why="extracted -> $where ($checked files)"; Path=$z.FullName }
    } else {
        $r = if (-not $haveFolder -and $missing -eq $checked) { "not extracted ($checked files)" }
             else { "$missing missing / $mismatch size-mismatch of $checked" }
        $keep += [PSCustomObject]@{ GB=[math]::Round($z.Length/1GB,2); Archive=$z.Name; Reason=$r; Path=$z.FullName }
    }
}

# --------------------------------------------------------------- 2. identical?
# Only archives not already condemned above, and only within same-size groups -
# different sizes cannot be identical, so this hashes the bare minimum.
if (-not $SkipHash) {
    $safePaths = @($safe | ForEach-Object { $_.Path })
    $cand = $zips | Where-Object { $safePaths -notcontains $_.FullName }
    foreach ($grp in ($cand | Group-Object Length | Where-Object { $_.Count -gt 1 })) {
        Write-Host ("  hashing {0} same-size archives ({1:N2} GB each)..." -f $grp.Count, ($grp.Group[0].Length/1GB))
        $byHash = @{}
        foreach ($f in $grp.Group) {
            $h = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash
            if ($byHash.ContainsKey($h)) {
                # Keep the NEWEST copy; the older duplicate is the redundant one.
                $prev = $byHash[$h]
                $older = if ($f.LastWriteTime -lt $prev.LastWriteTime) { $f } else { $prev }
                $newer = if ($older -eq $f) { $prev } else { $f }
                $byHash[$h] = $newer
                $safe += [PSCustomObject]@{ GB=[math]::Round($older.Length/1GB,2); Archive=$older.Name
                                            Why="byte-identical to $($newer.Name)"; Path=$older.FullName }
            } else { $byHash[$h] = $f }
        }
    }
    Write-Host ''
}

# ---------------------------------------------------------------------- report
Write-Host '=== REDUNDANT - contents verified present elsewhere ===' -ForegroundColor Green
if ($safe) {
    $safe | Sort-Object GB -Descending | Format-Table -AutoSize @{n='GB';e={'{0,7:N2}' -f $_.GB}}, Archive, Why
    Write-Host ('  reclaimable: {0:N2} GB across {1} archive(s)' -f (($safe | Measure-Object GB -Sum).Sum), $safe.Count) -ForegroundColor Green
} else { Write-Host '  none' }

Write-Host ''
Write-Host '=== KEEP ===' -ForegroundColor Yellow
if ($keep) { $keep | Sort-Object GB -Descending | Format-Table -AutoSize @{n='GB';e={'{0,7:N2}' -f $_.GB}}, Archive, Reason }
else { Write-Host '  none' }

if ($OutFile -and $safe) {
    $safe | ForEach-Object { $_.Path } | Set-Content -Path $OutFile -Encoding ASCII
    Write-Host ''
    Write-Host ("Safe list written to {0} - review it, then delete with:" -f $OutFile)
    Write-Host ('  Get-Content "{0}" | ForEach-Object {{ [System.IO.File]::Delete($_) }}' -f $OutFile) -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'Nothing was deleted. This script only reports.'
