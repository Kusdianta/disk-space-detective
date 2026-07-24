# Windows accumulators

Ranked by how often they are the answer *and* how rarely users find them.

---

## 1. `C:\Windows\Installer` — the top hidden accumulator

Windows Installer caches a copy of **every `.msi` and every `.msp` patch ever applied**, permanently. When a new cumulative patch supersedes an old one, the old file becomes orphaned — and **nothing in Windows ever deletes it**. Invisible to Disk Cleanup and to every third-party cleaner.

Worst offenders are apps shipping large monthly cumulative patches — **Adobe Acrobat** especially (~1 GB per update, often cached twice as cumulative + incremental), plus Office MSI, Autodesk, and some enterprise agents.

**Reference case: 44 GB total, 41 GB orphaned, 20+ Acrobat versions stacked over 15 months.**

Expected healthy size is 1–5 GB. Anything over 10 GB warrants investigation.

### Authoritative orphan test

Never judge by filename — the names are opaque hashes.

**Use the Windows Installer API, not the registry alone.** The API is the only source that exposes each patch's **state**, and that distinction is the entire job:

| State | Meaning | Verdict |
|---|---|---|
| `APPLIED` (1) | current patch level | **must keep** |
| `SUPERSEDED` (2) | replaced by a newer patch | safe to remove ← *the bulk* |
| `OBSOLETED` (4) | no longer relevant | safe to remove |
| `REGISTERED` (8) | registered, not applied | keep (conservative) |

Enumerate with `MsiEnumProductsEx` → `MsiGetProductInfoEx(…, "LocalPackage")` and `MsiEnumPatchesEx` → `MsiGetPatchInfoEx(…, "LocalPackage")`. `scripts/windows/_MsiReferenced.ps1` does this via P/Invoke.

> **Do not use the COM object from PowerShell 5.1.** `New-Object -ComObject WindowsInstaller.Installer` works, but `$msi.Products` returns `$null`, `ProductsEx` raises `DISP_E_MEMBERNOTFOUND`, and passing a `BindingFlags` string through a variable silently resolves to the wrong overload. P/Invoke against `msi.dll` has none of these problems.

**The registry is a useful second source, but it has a blind spot that will bite you:**

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\<SID>\Products\<Product>\InstallProperties : LocalPackage
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\UserData\<SID>\Products\<Product>\Patches\<Patch>   : LocalPackage
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Installer\Patches\<Patch>                                     : LocalPackage
```

> **Measured on a real machine:** that hive returned **69 cached product `.msi` files and zero `.msp` patches**. Every patch therefore looked orphaned — including 3 in state `APPLIED`. A registry-only pass deleted them (VC++ 2010 x86/x64 redistributables and an Adobe Acrobat patch). Nothing broke immediately, but a future repair/modify/uninstall of those products can prompt for a missing patch source.

So: **union the two sources into the KEEP set, never intersect them.** Either source can add a file to "still needed"; neither may move one into "removable". A partial failure then degrades toward keeping too much. (Same one-way rule [InstallerClean](https://github.com/no-faff/InstallerClean) uses.)

> **If both sources return zero, ABORT** — that means the query failed, not that everything is orphaned. **If the API specifically is unavailable, do not delete at all**: without it you cannot tell an applied patch from a superseded one.

Requires elevation (unelevated, enumerating all users' installs returns `ERROR_ACCESS_DENIED`; the scripts fall back to the current-user scope and say so). Deleting genuinely superseded patches is low-risk; worst case an app's repair flow re-downloads one.

**Identify the vendor** by reading the `.msp` bytes — patch metadata is near the start:

```powershell
$fs=[IO.File]::OpenRead($f); $buf=New-Object byte[] 300000; $n=$fs.Read($buf,0,$buf.Length); $fs.Close(); [Text.Encoding]::ASCII.GetString($buf[0..($n-1)]) -match 'DisplayName'
```

---

## 2. Component store — `C:\Windows\WinSxS`

Grows with every update. **Do not delete anything by hand.** Its apparent size overstates real cost (it hardlinks into `System32`).

```bat
Dism.exe /Online /Cleanup-Image /AnalyzeComponentStore
Dism.exe /Online /Cleanup-Image /StartComponentCleanup /ResetBase
```

`/ResetBase` blocks uninstalling existing updates. Typical yield 2–6 GB.

---

## 3. Windows Update leftovers

```
C:\Windows\SoftwareDistribution\Download
```

Safe to empty (stop `wuauserv` first). Usually small, occasionally many GB after a feature update.

---

## 4. Retained app versions (Electron / Squirrel)

Auto-updaters keep old versions as sibling `app-x.y.z` folders:

```
%LOCALAPPDATA%\{slack,Discord,Figma,Notion,...}\app-<version>\
%LOCALAPPDATA%\<app>\packages\*.nupkg
```

Usually 0.3–1 GB each. **Frequently over-blamed** — in the reference case this whole category was only 2.27 GB. Measure before accusing.

> **Squirrel keeps a full `.nupkg` in `packages\`** — that is an offline repair source if a version folder is damaged. Extract `lib\net45\*` back into the app folder.

---

## 5. Per-user caches

| Path | Notes |
|---|---|
| `%LOCALAPPDATA%\Temp` | usually small |
| `%LOCALAPPDATA%\CrashDumps`, `%LOCALAPPDATA%\Microsoft\Windows\WER` | can hit GBs |
| `%LOCALAPPDATA%\Google\Chrome\User Data\*\Cache` | large by design |
| `%LOCALAPPDATA%\CapCut\User Data\Cache` | **uncapped, never pruned** — 22.4 GB in the reference case, none newer than 3 months |
| `%LOCALAPPDATA%\Packages\<app>\LocalCache` | Store/MSIX apps |
| `%APPDATA%\<app>\Cache`, `Code Cache`, `GPUCache` | Electron apps |

Video editors are the usual outliers. Adobe media cache is capped in preferences; **CapCut and DaVinci Resolve are not.**

### 5a. Editor scratch disks & disk caches — two kinds, treat them differently

Creative apps spill in two ways, and only one of them can be cleaned automatically:

**Fixed, shared, safe to auto-clean** — the tool handles these:

| Path | What |
|---|---|
| `%APPDATA%\Adobe\Common\Media Cache Files` | Shared by Premiere, After Effects, Media Encoder, Audition. The big one. |
| `%APPDATA%\Adobe\Common\Media Cache` | The sibling database — rebuilds itself if the files are cleared. |
| `%APPDATA%\Adobe\Common\Peak Files` | Audio waveform cache. Regenerates. |
| `Photoshop Temp*` in `%TEMP%` / drive root | Scratch **orphans** left after a Photoshop crash. Cleaned only while Photoshop is closed — a live scratch file *is* the running session. |

**User-configured — the tool cannot find these, and says so instead of guessing:**

- **Photoshop Scratch Disk** — `Edit → Preferences → Scratch Disks`. A live working file on a drive *you* chose. Photoshop normally reclaims it on a clean exit; only crash orphans linger (handled above).
- **After Effects Disk Cache** — `Edit → Preferences → Media & Disk Cache`. Points at a folder you set; there is no fixed default path to probe. It also has a **"Empty Disk Cache"** button right there.
- **Blender temp** — `Preferences → File Paths → Temporary Files`. Configurable; defaults to the OS temp.

The honest rule: if an app lets you *choose* where it caches, only that app knows the path. Check the setting — most of these have a one-click "empty cache" button next to it. (Thanks to the Threads commenter who flagged this.)

---

## 6. Package manager caches

```
%LOCALAPPDATA%\npm-cache      npm cache clean --force
%LOCALAPPDATA%\uv\cache       uv cache clean
%LOCALAPPDATA%\pip\Cache      pip cache purge
%LOCALAPPDATA%\ms-playwright  browser binaries, one set per version
%USERPROFILE%\.cargo\registry
%USERPROFILE%\.gradle\caches
%USERPROFILE%\.nuget\packages
%USERPROFILE%\go\pkg\mod      go clean -modcache
%LOCALAPPDATA%\pnpm-store
```

These are **churn**, not ratchet — they return. Note them, do not chase them.

---

## 7. Big single files

| File | Notes |
|---|---|
| `C:\pagefile.sys` | resize via System Properties, do not delete |
| `C:\hiberfil.sys` | `powercfg -h off` reclaims ~40% of RAM size |
| `C:\swapfile.sys` | tiny, leave alone |
| `C:\Windows\MEMORY.DMP` | full crash dump, can be many GB |

---

## 8. Docker / WSL

```
%LOCALAPPDATA%\Docker\wsl\*.vhdx
```

Grows and **does not shrink** when images are removed. Reclaim with `docker system prune`, then compact the VHDX (`wsl --shutdown`, then `Optimize-VHD` or `diskpart compact vdisk`).

**Never delete the VHDX** — it contains images, volumes, and containers.

---

## 9. Shadow copies / System Restore

```bat
vssadmin list shadowstorage
vssadmin resize shadowstorage /for=C: /on=C: /maxsize=10GB
```

Requires elevation. `C:\System Volume Information` reads as 0 unprivileged — an unprivileged scan cannot see this at all, so check it explicitly.

---

## Scheduling the permanent fix

```powershell
$a=New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\DiskDetective\Invoke-DiskReclaim.ps1" -Execute'; $t=New-ScheduledTaskTrigger -Weekly -DaysOfWeek Sunday -At 9am; $p=New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -RunLevel Highest -LogonType S4U; $s=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries; Register-ScheduledTask -TaskName 'DiskReclaim' -Action $a -Trigger $t -Principal $p -Settings $s -Force
```

`-RunLevel Highest` is required for `C:\Windows\Installer`. If `S4U` is rejected, fall back to `-LogonType Interactive` (runs only while logged in).

## PowerShell 5.1 gotchas

- **Write scripts as ASCII, or UTF-8 *with* BOM.** PS 5.1 reads UTF-8-no-BOM as Windows-1252, turning an em-dash into a smart quote that acts as a **string delimiter** — a dash inside a *comment* breaks parsing with a nonsense error far below.
- **No `` `u{XXXX} `` escape.** `-split "`u{0001}"` splits on the literal letter `u`.
- `powershell -File` passes arguments as **literal strings** — array parameters need `-Command`.
