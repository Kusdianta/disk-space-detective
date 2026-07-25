<div align="center">

# 🔍 Disk Space Detective

### Find what is **secretly** eating your disk — and stop it coming back

<br>

![Windows](https://img.shields.io/badge/Windows-10%20%7C%2011-0078D6?style=for-the-badge&logo=windows&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-000000?style=for-the-badge&logo=apple&logoColor=white)
![Linux](https://img.shields.io/badge/Linux-FCC624?style=for-the-badge&logo=linux&logoColor=black)

![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)
![No install](https://img.shields.io/badge/install-none%20needed-success?style=flat-square)
![Offline](https://img.shields.io/badge/100%25%20offline-no%20AI%20·%20no%20account-blueviolet?style=flat-square)
![Safe](https://img.shields.io/badge/dry--run-by%20default-orange?style=flat-square)
![Stars](https://img.shields.io/github/stars/Kusdianta/disk-space-detective?style=flat-square)

<br>

**🏆 Real results**

| | Before | After | Freed |
|:--|:--:|:--:|:--:|
| 💻 PC #1 | `16.7 GB` free | `82.1 GB` free | **`+65 GB`** |
| 💻 PC #2 | `10.8 GB` free | `50.1 GB` free | **`+39 GB`** |

</div>

---

# 🚀 How to use — 3 steps

### 1️⃣ Open PowerShell as Administrator

Press `Win`, type `powershell`, then right-click it and choose **Run as Administrator**.

### 2️⃣ Copy-paste this. Press Enter.

It installs itself and scans your disk. **It deletes nothing.** Takes about 30 seconds.

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; $z="$env:TEMP\dd.zip";$x="$env:TEMP\ddx";irm https://github.com/Kusdianta/disk-space-detective/releases/latest/download/disk-space-detective.zip -OutFile $z;Remove-Item $x -Recurse -Force -EA 0;Expand-Archive $z $x -Force;& "$x\scripts\windows\Install-DiskDetective.ps1" -NoSchedule;& "C:\Tools\DiskDetective\Start-DiskDetective.ps1"
```

### 3️⃣ Preview first, then clean

The first line only *shows* you what it would remove. The second actually does it.

```powershell
& "C:\Tools\DiskDetective\Invoke-DiskReclaim.ps1"              # 👀  preview only
& "C:\Tools\DiskDetective\Invoke-DiskReclaim.ps1" -Execute     # 🧹  clean for real
```

> ### ⚠️ Two things to know
>
> **Close the apps first** — CapCut, Slack, Figma. If they are running, the tool skips them on purpose and you free almost nothing.
>
> **Use the full path** shown above, not `.\Invoke-DiskReclaim.ps1`. Your shell is sitting in `system32`, so the short version fails with *"is not recognized"*.

## 🔁 Keep it clean forever

One command and it runs by itself every Sunday.

```powershell
& "C:\Tools\DiskDetective\Install-DiskDetective.ps1" -DryRunOnly   # 📋  report only first
& "C:\Tools\DiskDetective\Install-DiskDetective.ps1"               # ✅  auto-clean weekly
```

> 💡 Start with `-DryRunOnly` for a few weeks. It writes what it *would* delete to `C:\Tools\DiskDetective\reclaim.log`. Once you agree with it, run the second command.

## 🍎 macOS / Linux

```bash
mkdir -p /tmp/dsd && curl -sL https://github.com/Kusdianta/disk-space-detective/releases/latest/download/disk-space-detective.tar.gz | tar xz -C /tmp/dsd && bash "$(find /tmp/dsd -name disk-detective.sh)" --all
```

<details>
<summary>💡 Prefer git?</summary>

```powershell
Set-ExecutionPolicy Bypass -Scope Process -Force; git clone -q https://github.com/Kusdianta/disk-space-detective "$env:TEMP\dsd"; & "$env:TEMP\dsd\scripts\windows\Install-DiskDetective.ps1" -NoSchedule; & "C:\Tools\DiskDetective\Start-DiskDetective.ps1"
```
</details>

<br>

<div align="center">

## 📖 Everything below is the "why"
### Skip it unless you're curious

</div>

---

**Plain PowerShell and bash scripts. No AI, no account, no network, no install.** They run offline on a stock Windows, macOS, or Linux machine and never phone home.

If you *do* use Claude Code or Claude Desktop, it also works as an [Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview) — but that is entirely optional and nothing here depends on it.


### What you get

```
  free     : 80.75 GB of 475.69 GB  (17% free)
  status   : TIGHT - under 20% free

== 1. KNOWN ACCUMULATORS   (max 8s each, results stream as they finish)

       GB  TYPE     What
    28.90  DATA     Docker WSL disk
    15.07  DATA     Store/MSIX app data
 >=  7.42  CACHE    Chrome profile+cache
     2.92  RATCHET  MSI/MSP cache
     2.15  RATCHET  Playwright browsers

  total in known accumulators        : 81.33 GB
    CACHE   (comes back after clearing): 10.20 GB
    RATCHET (never shrinks on its own) :  5.07 GB
```

Every folder is labelled so you know what you're looking at:

| | |
|---|---|
| **RATCHET** | Grows monthly, never shrinks. **This is what's actually eating your disk.** |
| **CACHE** | Safe to clear, but it comes back. Clearing it is not a fix. |
| **DATA** | Real data. Don't touch. |

`>=` means the probe hit its time cap — that folder is *at least* that big. A floor, never a falsely-small number.

### Requirements

**Windows** — everything needed ships with the OS. Nothing to install:

| | |
|---|---|
| OS | Windows 10 or 11 (Server 2016+ should work, untested) |
| PowerShell | **5.1** — preinstalled on Win10/11. No install, no upgrade. |
| .NET | Framework 4.x — preinstalled. Used for fast directory walking. |
| Admin | Needed **only** for the `C:\Windows\Installer` section |
| git | Optional — use the zip one-liner above instead |
| AI / network | **Not required.** No API key, no account, no internet. Runs fully offline. |

**macOS / Linux:**

| | |
|---|---|
| Shell | **`bash`** (macOS ships 3.2 - fine). Not POSIX `sh`: the script uses herestrings and `local`, so it needs bash, not dash/ash. |
| Tools | `find`, `du`, `df`, `awk`, `sort`, `perl` — all standard on both |
| `sudo` | Needed to scan outside your home directory |
| Optional | `lsof` (finds deleted-but-open files), `tmutil` / `btrfs` / `zfs` (snapshots) |

### Tested on

Being straight about this, since you may be running it somewhere I haven't:

| Platform | Status |
|---|---|
| **Windows 11 + PowerShell 5.1** | ✅ Extensively — this is where the tool was built and the 65 GB case was solved |
| Windows 10 + PowerShell 5.1 | ⚠️ Expected to work, not verified |
| PowerShell 7 (`pwsh`) | ⚠️ Untested. Nothing in the scripts is 5.1-only, but unverified. |
| **macOS / Linux** | ⚠️ Detectors verified individually; **never run end-to-end on real macOS or Linux hardware** |

The bash script is the weaker half and I'd rather say so than have you find out. It was written against the documented behaviour of BSD and GNU userland, and testing turned up three real portability bugs that a syntax check happily passed — `xargs -r` (absent on BSD), an unquoted `stat` format that word-split, and `awk strftime()` which is gawk-only and produced *silently empty output* on BSD awk. All three are fixed and the detectors verified, but treat a first run on macOS as a shakedown. The Windows path is the mature one.

### ⚠ Run it as Administrator / with sudo

Without it, `C:\Windows\Installer` is unreadable — and that's the most common hidden hoard on Windows (it was **41 GB** in the case that produced this tool). The script tells you it skipped it rather than implying all-clear.

### All commands

| Command | What it does |
|---|---|
| `Start-DiskDetective.ps1` | **Start here.** Read-only, ~25s. Probes the ~25 known accumulators. |
| `Start-DiskDetective.ps1 -Full` | Exhaustive: ranks every folder + growth-by-month. Minutes, not seconds. |
| `Invoke-DiskReclaim.ps1` | Cleanup. Dry-run by default; `-Execute` to act. |
| `Invoke-DiskReclaim.ps1 -Quarantine D:\Held` | *Move* files instead of deleting them (reversible). |
| `Install-DiskDetective.ps1` | Install to `C:\Tools\DiskDetective` + schedule weekly. |
| `Install-DiskDetective.ps1 -Weekday Friday -At 18:00` | Different schedule slot. |
| `Install-DiskDetective.ps1 -DryRunOnly` | Scheduled runs report only, never delete. |
| `Install-DiskDetective.ps1 -NoSchedule` | Copy the files, register no task. |
| `Install-DiskDetective.ps1 -Uninstall` | Remove the scheduled task. |

Checking on the scheduled task:

```powershell
Get-ScheduledTaskInfo -TaskName DiskDetective; Get-Content C:\Tools\DiskDetective\reclaim.log
Start-ScheduledTask -TaskName DiskDetective     # run now instead of waiting for Sunday
```

**Using it with Claude Code / Claude Desktop instead?**

```bash
git clone https://github.com/Kusdianta/disk-space-detective ~/.claude/skills/disk-space-detective
```

Then just ask: *"my C: drive keeps filling up, find out why"*

---
## Why this exists

Disk cleaners only remove what they already know about. This skill is for the other case:

> "I clear 40 GB of caches every month and I'm *still* out of space."

That describes two different problems wearing one costume:

| | |
|---|---|
| **Churn** | Caches you clear, that come back. Space *returns* each cycle. Annoying, not the cause. |
| **Ratchet** | Grows every month, never shrinks, survives every cleanup. **This is what's actually killing you.** |

Cleaning harder never fixes a ratchet. You have to find it, and it is almost never where people look.

## The core principle

> **Measure. Never guess. Then verify the measurement itself.**

The most common failure isn't deleting the wrong folder — it's *believing a broken measurement*. Every sizing tool on every OS has silent failure modes that under-report by 10x.

So every scan is followed by a **reconciliation gate**:

```
sum(top-level folders) + sum(root files)  ≈  used space reported by the OS
```

Off by more than ~5%? The scan is wrong. Fix it before concluding anything.

In the investigation that produced this skill, that check caught a scan reporting a **197 GB directory as 10 GB**.

## Real result

The reference case: a Windows workstation losing ~40 GB/month, where the owner had already ruled out Adobe media cache, Docker, hibernation, and the usual dev caches.

```
Before:  16.74 GB free
After:   82.11 GB free          +65.4 GB
```

**Root cause: `C:\Windows\Installer`.** Adobe Acrobat ships a ~1 GB cumulative patch roughly monthly. Windows Installer caches every one *permanently*, the next patch supersedes the last, and **nothing in Windows ever deletes the superseded copy**. 20+ Acrobat versions had stacked up over 15 months — 41 GB orphaned against 2.26 GB actually referenced.

Invisible to Disk Cleanup. Invisible to every third-party cleaner. Which is exactly why it survived every cleanup the owner had ever run.

Also found along the way: 22.4 GB of video-editor cache with nothing newer than three months, and 2.25 GB of stale VM bundles.

And one hypothesis **falsified by measurement** — "old Electron app versions piling up" looked obvious and accounted for only 2.27 GB. Ruling a suspect out is a real result.

## What's in the box

```
SKILL.md                       the 9-phase workflow
references/
  measurement-traps.md         read this regardless of OS
  windows.md                   Windows Installer, WinSxS, shadow copies, VHDX
  macos.md                     Time Machine snapshots, Xcode, iOS backups
  linux.md                     journald, pacman cache, snaps, deleted-but-open
scripts/
  windows/*.ps1                sizing, growth-by-month, version + orphan detection, reclaim
  bash/disk-detective.sh      the same detectors for macOS and Linux
```

## Safety

Everything here is **read-only by default**. Only the reclaim scripts modify anything, and only with an explicit `-Execute` / `--execute` flag.

Rules the scripts enforce, each of which exists because ignoring it caused a real failure:

- **Never delete from a directory a running process is using.** A file lock is the OS telling you it's in use.
- **Sort versions semantically, never by timestamp.** Timestamps tie and lie. An mtime sort once deleted a *live* application and kept a 2 MB stub. (It was restored byte-exact from the updater's own cached package — that recovery path is documented too.)
- **Establish "orphaned" from the package database, never the filename.** Query the installer API / package manager; anything on disk and unreferenced is orphaned.
- **A package database can have blind spots — check what your source *cannot* see.** On Windows the registry hive lists cached product `.msi` files but **no `.msp` patches at all**, so a registry-only pass makes every patch look orphaned. It deleted 3 patches that were still in state APPLIED before the Windows Installer API check caught it. `_MsiReferenced.ps1` now unions the API (which knows patch state: applied vs superseded) with the hive, and refuses to delete if the API is unavailable.
- **If the reference query returns zero, abort.** Zero means the query failed, not that everything is garbage.
- **Prefer quarantine over delete** when the destination has room. Move, verify for a week, then delete.
- **Guard against empty enumeration results.** `Get-ChildItem -Recurse` returned 0 files for a real 39,277-file / 22.4 GB directory. A cleanup script that reports "nothing to reclaim" on 22 GB of garbage is worse than no script at all.

## The permanent fix

A one-time cleanup is a failure — the ratchet just starts over. The skill finishes by installing:

1. A reusable script, dry-run by default
2. A scheduled job (Task Scheduler / launchd / systemd timer / cron)
3. A log, one line per run, so unattended runs are auditable

## Related work

This skill is a **diagnostic methodology**, not a better `du`. Where an existing tool is stronger at one step, use it — several are listed here for exactly that reason.

**Analyzers** — all one-shot snapshot tools; none do growth-over-time:

| Project | Notes |
|---|---|
| [dust](https://github.com/bootandy/dust) | Rust `du` replacement. Hardlink-dedup and symlink-safe by default, cross-platform. **Faster than these scripts** — good measurement backend. |
| [gdu](https://github.com/dundee/gdu) | Go TUI. Hardlinks counted once, JSON/SQLite snapshot export. |
| [WinDirStat](https://github.com/windirstat/windirstat) | Windows-only, revived and active. Hardlink dedup, logical-vs-physical sizing, treemap. |
| [pdu](https://github.com/KSXGitHub/parallel-disk-usage) | Opt-in hardlink dedup; documents its own blind spots (reflinks on BTRFS/ZFS). |
| [ncdu](https://dev.yorhel.nl/ncdu) | The POSIX standard. No native Windows. |
| [duc](https://github.com/zevv/duc) | Indexed DB, scales to 500M+ files. Snapshot diffing is a long-standing TODO. |

**Growth / age analysis** — the closest prior art to this skill's core idea:

- [agedu](https://www.chiark.greenend.org.uk/~sgtatham/agedu/) — Simon Tatham. Same *problem framing* ("`du` tells you what's big, not what's **too** big") but keys on **access** time (staleness), not write-recency. Complementary.
- [ncdu-compare](https://github.com/yaroslaff/ncdu-compare) — diffs two ncdu snapshots. Requires you to have taken one *beforehand*; this skill's mtime bucketing is retrospective.

**Windows Installer orphans** — this niche is **not** empty:

- **[InstallerClean](https://github.com/no-faff/InstallerClean)** — the serious one. Actively developed, queries the Windows Installer API (`MsiEnumProductsEx`/`MsiEnumPatchesEx`), reads patch supersedence, Recycle-Bin-safe deletes, Task Scheduler support. **If you only want the installer-cache problem solved on Windows, use this rather than these scripts.** Its one-way "registry evidence can only mark a file as *needed*, never *removable*" rule is the pattern `_MsiReferenced.ps1` follows.
- [PatchCleanerPS](https://github.com/jackharvest/PatchCleanerPS), [PatchCleanerAI](https://github.com/rondilley/PatchCleanerAI), [Windows-Cleanup](https://github.com/Leproide/Windows-Cleanup) — smaller PowerShell/Python takes on the same problem.
- PatchCleaner (homedev.com.au) — the closed-source original, unmaintained since 2016, excludes Adobe by default.

**Cleaners** — remediation only, no measurement or growth analysis: [BleachBit](https://github.com/bleachbit/bleachbit), [Czkawka](https://github.com/qarmin/czkawka) (duplicates/big-files), [mac-cleanup-py](https://github.com/mac-cleanup/mac-cleanup-py) (~47 per-app macOS cache modules).

**Agent skills** — [gccszs/disk-cleaner](https://github.com/gccszs/disk-cleaner) predates this one: a cross-platform Claude Code skill doing ranked sizing, junk cleanup, dry-run-by-default and scheduling. It does not do growth-by-month bucketing, churn-vs-ratchet classification, or installer-orphan detection.

**What's actually unique here:** retrospective month-by-month growth bucketing from a single scan, the churn-vs-ratchet framing, the documented measurement traps + reconciliation gate, and wiring diagnosis → root cause → scheduled permanent fix into one workflow.

## License

MIT
