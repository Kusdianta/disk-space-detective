# Find-OrphanedInstallerFiles.ps1 - classify C:\Windows\Installer cache as REFERENCED vs ORPHANED
#
# C:\Windows\Installer holds a cached copy of every .msi and every .msp patch Windows
# Installer has ever applied. Referenced ones are required for uninstall / repair /
# future patching. Orphaned ones belong to products that are GONE or to superseded
# patches, and are pure dead weight - but Windows never removes them.
#
# Authority for "referenced" is the registry, NOT the filename:
#   HKLM\...\Installer\UserData\<SID>\Products\<Product>\InstallProperties : LocalPackage
#   HKLM\...\Installer\UserData\<SID>\Products\<Product>\Patches\<Patch>   : LocalPackage
# This is the same rule PatchCleaner uses. Anything on disk and not in that set is orphaned.
#
# READ-ONLY. Prints a report and writes the orphan list to a file. Deletes nothing.
#
# ASCII only + BOM (PowerShell 5.1 misparses UTF-8 no-BOM files).

param(
    [string]$InstallerDir = 'C:\Windows\Installer',
    [string]$OutFile      = "$env:TEMP\installer-orphans.txt"
)

$ErrorActionPreference = 'SilentlyContinue'

Write-Output 'Collecting REFERENCED packages from the registry...'

$referenced = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$refDetail  = @{}

$userDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'

foreach ($sid in (Get-ChildItem $userDataRoot -ErrorAction SilentlyContinue)) {
    foreach ($product in (Get-ChildItem "$($sid.PSPath)\Products" -ErrorAction SilentlyContinue)) {

        $ip   = Get-ItemProperty "$($product.PSPath)\InstallProperties" -ErrorAction SilentlyContinue
        $name = $ip.DisplayName
        if (-not $name) { $name = '(unknown product)' }

        if ($ip.LocalPackage) {
            [void]$referenced.Add($ip.LocalPackage)
            $refDetail[$ip.LocalPackage] = "$name (product msi)"
        }

        foreach ($patch in (Get-ChildItem "$($product.PSPath)\Patches" -ErrorAction SilentlyContinue)) {
            $pp = Get-ItemProperty $patch.PSPath -ErrorAction SilentlyContinue
            if ($pp.LocalPackage) {
                [void]$referenced.Add($pp.LocalPackage)
                $refDetail[$pp.LocalPackage] = "$name (patch)"
            }
        }
    }
}

# Patches also appear under the global Patches hive.
foreach ($patch in (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Patches' -ErrorAction SilentlyContinue)) {
    $pp = Get-ItemProperty $patch.PSPath -ErrorAction SilentlyContinue
    if ($pp.LocalPackage) {
        [void]$referenced.Add($pp.LocalPackage)
        if (-not $refDetail.ContainsKey($pp.LocalPackage)) { $refDetail[$pp.LocalPackage] = '(global patch hive)' }
    }
}

Write-Output ("Referenced package paths found in registry: {0}" -f $referenced.Count)

if ($referenced.Count -eq 0) {
    Write-Output ''
    Write-Output '!! Registry returned ZERO referenced packages.'
    Write-Output '!! Refusing to classify anything as orphaned - this run is NOT trustworthy.'
    Write-Output '!! (Usually means the Installer registry hive was unreadable at this privilege level.)'
    exit 2
}

Write-Output ''
Write-Output 'Scanning disk...'

$files = Get-ChildItem $InstallerDir -File -Force -Include *.msi, *.msp -ErrorAction SilentlyContinue
if (-not $files) {
    $files = Get-ChildItem $InstallerDir -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -in '.msi', '.msp' }
}

$orphans   = @()
$keepers   = @()

foreach ($f in $files) {
    if ($referenced.Contains($f.FullName)) {
        $keepers += [PSCustomObject]@{ Path = $f.FullName; GB = $f.Length / 1GB; Why = $refDetail[$f.FullName] }
    } else {
        $orphans += [PSCustomObject]@{ Path = $f.FullName; GB = $f.Length / 1GB; MTime = $f.LastWriteTime }
    }
}

$keepGB   = [math]::Round((($keepers | Measure-Object GB -Sum).Sum), 2)
$orphanGB = [math]::Round((($orphans | Measure-Object GB -Sum).Sum), 2)

Write-Output ''
Write-Output '================ RESULT ================'
Write-Output ("REFERENCED (must keep) : {0,4} files  {1,8:N2} GB" -f $keepers.Count, $keepGB)
Write-Output ("ORPHANED   (reclaimable): {0,4} files  {1,8:N2} GB" -f $orphans.Count, $orphanGB)
Write-Output '========================================'
Write-Output ''
Write-Output 'Largest ORPHANS:'
$orphans | Sort-Object GB -Descending | Select-Object -First 25 |
    Format-Table -AutoSize @{n='GB';e={'{0,7:N2}' -f $_.GB}}, @{n='Modified';e={'{0:yyyy-MM-dd}' -f $_.MTime}}, Path

Write-Output ''
Write-Output 'Largest REFERENCED (these stay):'
$keepers | Sort-Object GB -Descending | Select-Object -First 10 |
    Format-Table -AutoSize @{n='GB';e={'{0,7:N2}' -f $_.GB}}, Why, Path

$orphans | Sort-Object GB -Descending | Select-Object -ExpandProperty Path | Set-Content -Path $OutFile -Encoding ASCII
Write-Output ''
Write-Output ("Orphan list written to: {0}" -f $OutFile)
