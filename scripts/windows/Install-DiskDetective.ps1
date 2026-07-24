# Install-DiskDetective.ps1 - put it somewhere permanent + run it on a schedule
#
#   .\Install-DiskDetective.ps1                  # install + weekly Sunday 09:00 cleanup
#   .\Install-DiskDetective.ps1 -NoSchedule      # copy the files only
#   .\Install-DiskDetective.ps1 -Weekday Friday -At 18:00
#   .\Install-DiskDetective.ps1 -DryRunOnly      # scheduled run REPORTS ONLY, never deletes
#   .\Install-DiskDetective.ps1 -Uninstall       # remove the task (leaves files)
#
# WHY THIS EXISTS
# The quickstart clones into %TEMP%, which Windows eventually wipes - fine for a
# one-off look, useless for anything recurring. This copies the scripts to a stable
# location and registers a Scheduled Task so the accumulators never build back up.
#
# Needs an ELEVATED shell: the task runs with highest privileges so it can read
# C:\Windows\Installer, which is where the biggest hoard usually is.
#
# ASCII only + BOM (PowerShell 5.1 misparses UTF-8 no-BOM files).

[CmdletBinding()]
param(
    [string]$InstallPath = 'C:\Tools\DiskDetective',
    [string]$TaskName    = 'DiskDetective',
    [ValidateSet('Sunday','Monday','Tuesday','Wednesday','Thursday','Friday','Saturday')]
    [string]$Weekday     = 'Sunday',
    [string]$At          = '09:00',
    [switch]$NoSchedule,
    [switch]$DryRunOnly,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot

function Test-Elevated {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

Write-Host ''
Write-Host ('-' * 70)
Write-Host ' DISK DETECTIVE - install / schedule' -ForegroundColor Green
Write-Host ('-' * 70)

# ------------------------------------------------------------------- uninstall
if ($Uninstall) {
    $t = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $t) {
        Write-Host ("  no scheduled task named '{0}' - nothing to remove" -f $TaskName)
    } elseif (-not (Test-Elevated)) {
        Write-Warning "  removing a task needs an elevated shell."
        exit 1
    } else {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host ("  removed scheduled task '{0}'" -f $TaskName)
    }
    Write-Host ("  files left in place at {0} - delete that folder by hand if you want them gone." -f $InstallPath)
    Write-Host ''
    exit 0
}

# ---------------------------------------------------------------------- copy
# Every script is required: Start-DiskDetective and Invoke-DiskReclaim both
# dot-source _MsiReferenced.ps1, and a partial copy silently loses whole detectors.
# Includes THIS script: without it the installed copy has no way to re-schedule or
# uninstall itself, and Start-DiskDetective's "schedule it" hint points at nothing.
$files = @('Start-DiskDetective.ps1','Invoke-DiskReclaim.ps1','_MsiReferenced.ps1',
           'Find-OrphanedInstallerFiles.ps1','Find-VersionFolders.ps1',
           'Get-FolderSize.ps1','Get-GrowthByMonth.ps1','Install-DiskDetective.ps1')

$missing = @($files | Where-Object { -not (Test-Path (Join-Path $here $_)) })
if ($missing.Count -gt 0) {
    Write-Error ("Missing from {0}: {1}" -f $here, ($missing -join ', '))
    exit 3
}

if ($here -ieq $InstallPath) {
    Write-Host ("  already installed at {0} - skipping copy" -f $InstallPath)
} else {
    New-Item -ItemType Directory -Force -Path $InstallPath | Out-Null
    foreach ($f in $files) { Copy-Item (Join-Path $here $f) (Join-Path $InstallPath $f) -Force }
    Write-Host ("  installed {0} scripts -> {1}" -f $files.Count, $InstallPath)
}

# Bring the reference docs along if they are present - the reports point at them.
$refSrc = Join-Path (Split-Path (Split-Path $here -Parent) -Parent) 'references'
if (Test-Path $refSrc) {
    $refDst = Join-Path $InstallPath 'references'
    New-Item -ItemType Directory -Force -Path $refDst | Out-Null
    Copy-Item "$refSrc\*.md" $refDst -Force
    Write-Host ("  copied reference docs -> {0}" -f $refDst)
}

$target = Join-Path $InstallPath 'Start-DiskDetective.ps1'
$reclaim = Join-Path $InstallPath 'Invoke-DiskReclaim.ps1'

if ($NoSchedule) {
    Write-Host ''
    Write-Host '  -NoSchedule given, so no task was registered. Run it by hand with:'
    Write-Host ''
    Write-Host ("     & `"{0}`"" -f $target) -ForegroundColor Yellow
    Write-Host ''
    exit 0
}

# ------------------------------------------------------------------- schedule
if (-not (Test-Elevated)) {
    Write-Host ''
    Write-Warning "  Not elevated - files are installed, but the task was NOT registered."
    Write-Host '  The scheduled run needs admin to read C:\Windows\Installer, so re-run this'
    Write-Host '  from an Administrator PowerShell:'
    Write-Host ''
    Write-Host ("     Start-Process powershell -Verb RunAs -ArgumentList '-NoExit','-ExecutionPolicy','Bypass','-File','{0}'" -f (Join-Path $InstallPath 'Install-DiskDetective.ps1')) -ForegroundColor Yellow
    Write-Host ''
    exit 1
}

# -Execute unless the caller explicitly wants a report-only schedule.
$argLine = '-NoProfile -ExecutionPolicy Bypass -File "{0}"{1}' -f $reclaim, $(if ($DryRunOnly) { '' } else { ' -Execute' })

$action    = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument $argLine
$trigger   = New-ScheduledTaskTrigger -Weekly -DaysOfWeek $Weekday -At $At
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType S4U
$settings  = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries

try {
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description 'Reclaims orphaned installer patches, stale caches and old app versions' | Out-Null
} catch {
    # S4U needs the "log on as batch job" right; Interactive always works but only
    # fires while the user is signed in. Falling back beats failing outright.
    Write-Warning ("  S4U logon rejected ({0}) - falling back to Interactive (runs only while you are signed in)." -f $_.Exception.Message)
    $principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType Interactive
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Force `
        -Description 'Reclaims orphaned installer patches, stale caches and old app versions' | Out-Null
}

$info = Get-ScheduledTaskInfo -TaskName $TaskName
Write-Host ''
Write-Host ("  scheduled task '{0}' registered" -f $TaskName) -ForegroundColor Green
Write-Host ("     runs      : every {0} at {1}" -f $Weekday, $At)
Write-Host ("     mode      : {0}" -f $(if ($DryRunOnly) { 'REPORT ONLY (never deletes)' } else { 'EXECUTE (reclaims space)' }))
Write-Host ("     next run  : {0}" -f $info.NextRunTime)
Write-Host ("     log       : {0}" -f (Join-Path $InstallPath 'reclaim.log'))
Write-Host ''
Write-Host '  Check on it any time:'
Write-Host ''
Write-Host ("     Get-ScheduledTaskInfo -TaskName '{0}'" -f $TaskName) -ForegroundColor Yellow
Write-Host ("     Get-Content `"{0}`"" -f (Join-Path $InstallPath 'reclaim.log')) -ForegroundColor Yellow
Write-Host ''
Write-Host '  Run it right now instead of waiting:'
Write-Host ''
Write-Host ("     Start-ScheduledTask -TaskName '{0}'" -f $TaskName) -ForegroundColor Yellow
Write-Host ''
Write-Host ("  Undo:  & `"{0}`" -Uninstall" -f (Join-Path $InstallPath 'Install-DiskDetective.ps1'))
Write-Host ''
