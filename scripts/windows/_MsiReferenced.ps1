# _MsiReferenced.ps1 - SHARED: which C:\Windows\Installer packages are LIVE
#
# Dot-sourced by Find-OrphanedInstallerFiles.ps1 (report) and Invoke-DiskReclaim.ps1
# (delete). It lives in one file ON PURPOSE: an earlier version duplicated this logic,
# and the copy inside the script that actually DELETES was the weaker one. Detection
# used by a reporter and detection used by a deleter must never drift apart.
#
# ===========================================================================
# WHY THE WINDOWS INSTALLER API AND NOT JUST THE REGISTRY
#
# An earlier version of this script derived "referenced" purely from
#   HKLM\...\Installer\UserData\<SID>\Products\<P>\InstallProperties:LocalPackage
# On a real machine that hive listed the 69 cached product .msi files and NOT ONE of
# the .msp patch files. Every patch therefore looked orphaned - including 3 that
# Windows Installer still had in state APPLIED (current patch level, not superseded).
# A registry-only pass deleted them. Nothing broke immediately, but a future repair /
# modify / uninstall of those products can now prompt for a missing patch source.
#
# The Windows Installer API knows each patch's STATE, which the hive does not expose:
#
#     APPLIED    (1)  current patch level          -> MUST KEEP
#     SUPERSEDED (2)  replaced by a newer patch    -> safe to remove  <-- the 41 GB
#     OBSOLETED  (4)  no longer relevant           -> safe to remove
#     REGISTERED  (8) registered, not yet applied  -> keep (conservative)
#
# That distinction is the whole ballgame: it is what lets this remove a stack of
# superseded Adobe cumulative patches while keeping the one that is actually in force.
# ===========================================================================
#
# TWO INDEPENDENT SOURCES, UNIONED into the KEEP set - never intersected:
#   1. Windows Installer API via msi.dll P/Invoke (authoritative; knows patch state)
#   2. Registry UserData hive (catches rows the API may not surface)
#
# UNION, NOT INTERSECTION, is the fail-safe direction. A package named by EITHER
# source is KEPT. A source can only ever ADD to "still needed" - it can never move
# something into "removable". A partial failure of either degrades toward keeping too
# much, never toward deleting something live. (Same one-way rule no-faff/InstallerClean
# applies - see README "Related work".)
#
# P/Invoke rather than the WindowsInstaller.Installer COM object on purpose:
# PowerShell 5.1's COM late-binding cannot reliably reach these members - $msi.Products
# returns $null, ProductsEx raises DISP_E_MEMBERNOTFOUND, and a BindingFlags string
# passed through a variable silently resolves to the wrong overload. None of that is
# acceptable on a code path that deletes files.
#
# ASCII only + BOM (PowerShell 5.1 misparses UTF-8 no-BOM files).

Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using System.Text;

public static class MsiRef
{
    const uint ERROR_SUCCESS       = 0;
    const uint ERROR_ACCESS_DENIED = 5;
    const uint ERROR_MORE_DATA     = 234;
    const uint ERROR_NO_MORE_ITEMS = 259;

    const uint CTX_ALL = 7;   // machine + user-managed + user-unmanaged

    public const uint STATE_APPLIED    = 1;
    public const uint STATE_SUPERSEDED = 2;
    public const uint STATE_OBSOLETED  = 4;
    public const uint STATE_REGISTERED = 8;

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    static extern uint MsiEnumProductsEx(string szProductCode, string szUserSid, uint dwContext,
        uint dwIndex, StringBuilder szInstalledProductCode, out uint pdwInstalledContext,
        StringBuilder szSid, ref uint pcchSid);

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    static extern uint MsiGetProductInfoEx(string szProductCode, string szUserSid, uint dwContext,
        string szProperty, StringBuilder szValue, ref uint pcchValue);

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    static extern uint MsiEnumPatchesEx(string szProductCode, string szUserSid, uint dwContext,
        uint dwFilter, uint dwIndex, StringBuilder szPatchCode, StringBuilder szTargetProductCode,
        out uint pdwTargetProductContext, StringBuilder szTargetUserSid, ref uint pcchTargetUserSid);

    [DllImport("msi.dll", CharSet = CharSet.Unicode)]
    static extern uint MsiGetPatchInfoEx(string szPatchCode, string szProductCode, string szUserSid,
        uint dwContext, string szProperty, StringBuilder lpValue, ref uint pcchValue);

    public static string Scope = "";
    public static bool   Ok    = false;

    static string ProductProp(string product, string sid, uint ctx, string prop)
    {
        uint len = 1024; var sb = new StringBuilder(1024);
        uint r = MsiGetProductInfoEx(product, sid, ctx, prop, sb, ref len);
        if (r == ERROR_MORE_DATA) { sb = new StringBuilder((int)++len); r = MsiGetProductInfoEx(product, sid, ctx, prop, sb, ref len); }
        return (r == ERROR_SUCCESS) ? sb.ToString() : null;
    }

    static string PatchProp(string patch, string product, string sid, uint ctx, string prop)
    {
        uint len = 1024; var sb = new StringBuilder(1024);
        uint r = MsiGetPatchInfoEx(patch, product, sid, ctx, prop, sb, ref len);
        if (r == ERROR_MORE_DATA) { sb = new StringBuilder((int)++len); r = MsiGetPatchInfoEx(patch, product, sid, ctx, prop, sb, ref len); }
        return (r == ERROR_SUCCESS) ? sb.ToString() : null;
    }

    // Rows are "path|why". keepFilter selects which patch states count as KEEP.
    // Superseded/obsoleted patches are deliberately excluded from the keep set - they
    // are the reclaimable bulk - but are reported separately via SupersededPaths.
    public static List<string> KeepRows  = new List<string>();
    public static List<string> SupersededPaths = new List<string>();

    public static void Scan()
    {
        KeepRows.Clear();
        SupersededPaths.Clear();

        // "S-1-1-0" (Everyone) sees per-user installs of OTHER users but needs elevation;
        // unelevated it returns ERROR_ACCESS_DENIED. Fall back to the current user so an
        // unelevated run still yields a usable answer instead of an empty one that would
        // read as "nothing is referenced".
        var probe = new StringBuilder(39); var probeSid = new StringBuilder(256);
        uint probeLen = 256; uint probeCtx;
        uint probeR = MsiEnumProductsEx(null, "S-1-1-0", CTX_ALL, 0, probe, out probeCtx, probeSid, ref probeLen);
        string sidScope = (probeR == ERROR_ACCESS_DENIED) ? null : "S-1-1-0";
        Scope = (sidScope == null) ? "current user (not elevated)" : "all users";

        for (uint i = 0; ; i++)
        {
            var prd = new StringBuilder(39); var sidb = new StringBuilder(256);
            uint sl = 256; uint ctx;

            uint r = MsiEnumProductsEx(null, sidScope, CTX_ALL, i, prd, out ctx, sidb, ref sl);
            if (r == ERROR_MORE_DATA)
            {
                sidb = new StringBuilder((int)++sl);
                r = MsiEnumProductsEx(null, sidScope, CTX_ALL, i, prd, out ctx, sidb, ref sl);
            }
            if (r == ERROR_NO_MORE_ITEMS) { Ok = true; break; }
            if (r != ERROR_SUCCESS) { break; }

            string pcode = prd.ToString();
            string psid  = sidb.Length > 0 ? sidb.ToString() : null;
            string name  = ProductProp(pcode, psid, ctx, "ProductName") ?? "(unknown product)";

            string lp = ProductProp(pcode, psid, ctx, "LocalPackage");
            if (!String.IsNullOrEmpty(lp)) KeepRows.Add(lp + "|" + name + " (product msi)");

            EnumPatches(pcode, psid, ctx, name, STATE_APPLIED,    KeepRows, " (patch, APPLIED)");
            EnumPatches(pcode, psid, ctx, name, STATE_REGISTERED, KeepRows, " (patch, REGISTERED)");

            // Informational only - these are what makes the cache huge.
            var sup = new List<string>();
            EnumPatches(pcode, psid, ctx, name, STATE_SUPERSEDED, sup, "");
            EnumPatches(pcode, psid, ctx, name, STATE_OBSOLETED,  sup, "");
            foreach (string s in sup) SupersededPaths.Add(s.Split('|')[0]);
        }
    }

    static void EnumPatches(string pcode, string psid, uint ctx, string name, uint filter,
                            List<string> sink, string suffix)
    {
        for (uint j = 0; ; j++)
        {
            var pat = new StringBuilder(39); var tp = new StringBuilder(39);
            var ts  = new StringBuilder(256); uint tl = 256; uint tc;

            uint pr = MsiEnumPatchesEx(pcode, psid, ctx, filter, j, pat, tp, out tc, ts, ref tl);
            if (pr == ERROR_MORE_DATA)
            {
                ts = new StringBuilder((int)++tl);
                pr = MsiEnumPatchesEx(pcode, psid, ctx, filter, j, pat, tp, out tc, ts, ref tl);
            }
            if (pr != ERROR_SUCCESS) break;

            string plp = PatchProp(pat.ToString(), pcode, psid, ctx, "LocalPackage");
            if (!String.IsNullOrEmpty(plp)) sink.Add(plp + "|" + name + suffix);
        }
    }
}
'@ -ErrorAction SilentlyContinue

function Get-MsiReferencedPackages {
    <#
    .SYNOPSIS
    Returns every .msi/.msp path Windows Installer still needs (the KEEP set).

    .DESCRIPTION
    Keep set = cached product .msi files
             + patches in state APPLIED or REGISTERED
             + anything named by the registry UserData hive
    Superseded/obsoleted patches are deliberately NOT in the keep set: they are the
    reclaimable bulk this whole skill exists to find.

    .OUTPUTS
    PSCustomObject:
      Paths       [HashSet[string]] case-insensitive KEEP set
      Detail      [hashtable]       path -> why it is kept
      ApiOk/RegOk [bool]            did each source answer
      ApiOnly     [string[]]        paths ONLY the API knew - a registry-only tool
                                    would have deleted these
      Superseded  [string[]]        superseded/obsoleted patch paths (reclaimable)
      Scope       [string]          all users vs current user
      Trustworthy [bool]            false => caller MUST NOT delete anything
    #>
    [CmdletBinding()]
    param()

    $ErrorActionPreference = 'SilentlyContinue'

    $cmp    = [StringComparer]::OrdinalIgnoreCase
    $apiSet = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
    $regSet = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
    $detail = @{}
    $apiOk  = $false
    $scope  = 'unavailable'
    $superseded = @()

    # ------------------------------------------------- source 1: Windows Installer API
    try {
        [MsiRef]::Scan()
        $apiOk = $true
        $scope = [MsiRef]::Scope
        foreach ($row in [MsiRef]::KeepRows) {
            $i = $row.LastIndexOf('|')
            if ($i -lt 1) { continue }
            $path = $row.Substring(0, $i)
            [void]$apiSet.Add($path)
            if (-not $detail.ContainsKey($path)) { $detail[$path] = $row.Substring($i + 1) }
        }
        $superseded = @([MsiRef]::SupersededPaths | Sort-Object -Unique)
    } catch {
        Write-Warning ("   Windows Installer API unavailable: {0}" -f $_.Exception.Message)
    }

    # ----------------------------------------------------------- source 2: registry
    $regOk = $false
    try {
        $userDataRoot = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData'
        foreach ($sid in (Get-ChildItem $userDataRoot)) {
            foreach ($product in (Get-ChildItem "$($sid.PSPath)\Products")) {
                $ip   = Get-ItemProperty "$($product.PSPath)\InstallProperties"
                $name = $ip.DisplayName
                if (-not $name) { $name = '(unknown product)' }

                if ($ip.LocalPackage) {
                    [void]$regSet.Add($ip.LocalPackage)
                    if (-not $detail.ContainsKey($ip.LocalPackage)) { $detail[$ip.LocalPackage] = "$name (product msi)" }
                }
                foreach ($patch in (Get-ChildItem "$($product.PSPath)\Patches")) {
                    $pp = Get-ItemProperty $patch.PSPath
                    if ($pp.LocalPackage) {
                        [void]$regSet.Add($pp.LocalPackage)
                        if (-not $detail.ContainsKey($pp.LocalPackage)) { $detail[$pp.LocalPackage] = "$name (patch, registry)" }
                    }
                }
            }
        }
        foreach ($patch in (Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Patches')) {
            $pp = Get-ItemProperty $patch.PSPath
            if ($pp.LocalPackage) {
                [void]$regSet.Add($pp.LocalPackage)
                if (-not $detail.ContainsKey($pp.LocalPackage)) { $detail[$pp.LocalPackage] = '(global patch hive)' }
            }
        }
        $regOk = $true
    } catch {
        Write-Warning ("   Registry hive unreadable: {0}" -f $_.Exception.Message)
    }

    # --------------------------------------------------------------- union = KEEP set
    $union = New-Object 'System.Collections.Generic.HashSet[string]' $cmp
    foreach ($p in $apiSet) { [void]$union.Add($p) }
    foreach ($p in $regSet) { [void]$union.Add($p) }

    $apiOnly = @($apiSet | Where-Object { -not $regSet.Contains($_) })
    $regOnly = @($regSet | Where-Object { -not $apiSet.Contains($_) })

    [PSCustomObject]@{
        Paths       = $union
        Detail      = $detail
        ApiOk       = $apiOk
        RegOk       = $regOk
        ApiCount    = $apiSet.Count
        RegCount    = $regSet.Count
        ApiOnly     = $apiOnly
        RegOnly     = $regOnly
        Superseded  = $superseded
        Scope       = $scope
        Trustworthy = ($union.Count -gt 0)
    }
}
