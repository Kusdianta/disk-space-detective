# Find-OrphanedInstallerFiles.ps1 - classify C:\Windows\Installer cache as REFERENCED vs ORPHANED
#
# C:\Windows\Installer holds a cached copy of every .msi and every .msp patch Windows
# Installer has ever applied. Referenced ones are required for uninstall / repair /
# future patching. Orphaned ones belong to products that are GONE or to superseded
# patches, and are pure dead weight - but Windows never removes them.
#
# Authority for "referenced" is the Windows Installer database, NEVER the filename
# (the names are opaque hashes). Detection lives in _MsiReferenced.ps1 and unions two
# independent sources - the COM API and the registry hive - so that a failure of
# either degrades toward keeping too much, never toward deleting something live.
#
# READ-ONLY. Prints a report and writes the orphan list to a file. Deletes nothing.
#
# ASCII only + BOM (PowerShell 5.1 misparses UTF-8 no-BOM files).

param(
    [string]$InstallerDir = 'C:\Windows\Installer',
    [string]$OutFile      = "$env:TEMP\installer-orphans.txt"
)

$ErrorActionPreference = 'SilentlyContinue'

# Fail LOUDLY if the shared detector is missing rather than silently falling back to
# a weaker inline check - a quiet downgrade here is how you delete a live package.
$helper = Join-Path $PSScriptRoot '_MsiReferenced.ps1'
if (-not (Test-Path $helper)) {
    Write-Error "Required helper not found: $helper (copy the whole scripts\windows folder, not one file)"
    exit 3
}
. $helper

Write-Output 'Collecting REFERENCED packages (Windows Installer API + registry hive)...'
$ref = Get-MsiReferencedPackages

Write-Output ("   Installer API : {0}   [scope: {1}]" -f `
              $(if ($ref.ApiOk) { "{0} packages" -f $ref.ApiCount } else { 'UNAVAILABLE' }), $ref.Scope)
Write-Output ("   Registry hive : {0}" -f $(if ($ref.RegOk) { "{0} packages" -f $ref.RegCount } else { 'UNAVAILABLE' }))
Write-Output ("   KEEP union    : {0} packages" -f $ref.Paths.Count)
Write-Output ("   Superseded    : {0} patch(es) - reclaimable, excluded from KEEP" -f $ref.Superseded.Count)

if (-not $ref.ApiOk) {
    Write-Output ''
    Write-Output '   !! Installer API did not answer - running on registry evidence alone.'
    Write-Output '   !! That cannot see patch state, so APPLIED patches may look orphaned. Do not delete.'
}

# The number that matters: packages only the API knew about. Each one is a file a
# registry-only tool (PatchCleaner, or an earlier version of this script) would have
# called an orphan and offered to delete.
if ($ref.ApiOnly.Count -gt 0) {
    Write-Output ''
    Write-Output ("   !! {0} package(s) known ONLY to the Installer API - a registry-only tool" -f $ref.ApiOnly.Count)
    Write-Output '   !! would mis-classify these as orphans:'
    $ref.ApiOnly | Select-Object -First 10 | ForEach-Object {
        $tag = if (Test-Path -LiteralPath $_) { 'present' } else { 'ALREADY GONE' }
        Write-Output ("        [{0,-12}] {1}  {2}" -f $tag, (Split-Path $_ -Leaf), $ref.Detail[$_])
    }
}
if ($ref.RegOnly.Count -gt 0) {
    Write-Output ''
    Write-Output ("   ({0} package(s) known only to the registry - kept by the union rule)" -f $ref.RegOnly.Count)
}

if (-not $ref.Trustworthy) {
    Write-Output ''
    Write-Output '!! BOTH sources returned ZERO referenced packages.'
    Write-Output '!! Refusing to classify anything as orphaned - this run is NOT trustworthy.'
    Write-Output '!! (Usually means the Installer database was unreadable at this privilege level.'
    Write-Output '!!  Re-run from an ELEVATED PowerShell.)'
    exit 2
}

Write-Output ''
Write-Output 'Scanning disk...'

$files = Get-ChildItem $InstallerDir -File -Force -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -in '.msi', '.msp' }

if (-not $files) {
    Write-Output ''
    Write-Output ("No .msi/.msp files readable under {0}." -f $InstallerDir)
    Write-Output '(That directory is ACL-protected - if you are not elevated, this is a'
    Write-Output ' permissions failure, NOT proof that the cache is clean.)'
    exit 1
}

$orphans = @()
$keepers = @()

foreach ($f in $files) {
    if ($ref.Paths.Contains($f.FullName)) {
        $keepers += [PSCustomObject]@{ Path = $f.FullName; GB = $f.Length / 1GB; Why = $ref.Detail[$f.FullName] }
    } else {
        $orphans += [PSCustomObject]@{ Path = $f.FullName; GB = $f.Length / 1GB; MTime = $f.LastWriteTime }
    }
}

$keepGB   = [math]::Round((($keepers | Measure-Object GB -Sum).Sum), 2)
$orphanGB = [math]::Round((($orphans | Measure-Object GB -Sum).Sum), 2)

Write-Output ''
Write-Output '================ RESULT ================'
Write-Output ("REFERENCED (must keep)  : {0,4} files  {1,8:N2} GB" -f $keepers.Count, $keepGB)
Write-Output ("ORPHANED   (reclaimable): {0,4} files  {1,8:N2} GB" -f $orphans.Count, $orphanGB)
Write-Output '========================================'

if ($orphans.Count -gt 0) {
    Write-Output ''
    Write-Output 'Largest ORPHANS:'
    $orphans | Sort-Object GB -Descending | Select-Object -First 25 |
        Format-Table -AutoSize @{n='GB';e={'{0,7:N2}' -f $_.GB}}, @{n='Modified';e={'{0:yyyy-MM-dd}' -f $_.MTime}}, Path
}

Write-Output ''
Write-Output 'Largest REFERENCED (these stay):'
$keepers | Sort-Object GB -Descending | Select-Object -First 10 |
    Format-Table -AutoSize @{n='GB';e={'{0,7:N2}' -f $_.GB}}, Why, Path

$orphans | Sort-Object GB -Descending | Select-Object -ExpandProperty Path | Set-Content -Path $OutFile -Encoding ASCII
Write-Output ''
Write-Output ("Orphan list written to: {0}" -f $OutFile)
