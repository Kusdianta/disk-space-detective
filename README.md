# Disk Space Detective

Finds what is **silently** filling a disk, proves it by measurement, and installs a permanent fix.

**Plain PowerShell and bash scripts. No AI, no account, no network, no install.** They run offline on a stock Windows, macOS, or Linux machine and never phone home.

If you *do* use Claude Code or Claude Desktop, it also works as an [Agent Skill](https://docs.claude.com/en/docs/agents-and-tools/agent-skills/overview) — but that is entirely optional and nothing here depends on it.

---

# ▶ Run it

One paste. Read-only — **it does not delete anything**. Takes about 25 seconds.

**Windows** (PowerShell):

```bash
git clone -q https://github.com/Kusdianta/disk-space-detective "$env:TEMP\dsd"; powershell -ExecutionPolicy Bypass -File "$env:TEMP\dsd\scripts\windows\Start-DiskDetective.ps1"
```

**macOS / Linux:**

```bash
git clone -q https://github.com/Kusdianta/disk-space-detective /tmp/dsd && bash /tmp/dsd/scripts/posix/disk-detective.sh --all
```

<details>
<summary>No git installed? (Windows zip version)</summary>

```bash
irm https://github.com/Kusdianta/disk-space-detective/archive/refs/heads/main.zip -OutFile "$env:TEMP\dsd.zip"; Expand-Archive "$env:TEMP\dsd.zip" "$env:TEMP\dsd" -Force; powershell -ExecutionPolicy Bypass -File "$env:TEMP\dsd\disk-space-detective-main\scripts\windows\Start-DiskDetective.ps1"
```
</details>

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
| Shell | `bash` (macOS ships 3.2; that's fine) |
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

The POSIX script is the weaker half and I'd rather say so than have you find out. It was written against the documented behaviour of BSD and GNU userland, and testing turned up three real portability bugs that a syntax check happily passed — `xargs -r` (absent on BSD), an unquoted `stat` format that word-split, and `awk strftime()` which is gawk-only and produced *silently empty output* on BSD awk. All three are fixed and the detectors verified, but treat a first run on macOS as a shakedown. The Windows path is the mature one.

### ⚠ Run it as Administrator / with sudo

Without it, `C:\Windows\Installer` is unreadable — and that's the most common hidden hoard on Windows (it was **41 GB** in the case that produced this tool). The script tells you it skipped it rather than implying all-clear.

### Then what? — actually reclaiming the space

The scan ends by printing your exact next commands **as full paths**, so you can paste them straight back in. Cleanup is always separate and explicit:

```bash
& "$env:TEMP\dsd\scripts\windows\Invoke-DiskReclaim.ps1"
```

That **previews** what it would remove and changes nothing. Then:

```bash
& "$env:TEMP\dsd\scripts\windows\Invoke-DiskReclaim.ps1" -Execute
```

Or `-Quarantine D:\Held` to *move* files instead of deleting them.

> **Use the full path, not `.\Invoke-DiskReclaim.ps1`.** The quickstart runs the scanner by absolute path, which leaves your shell in `C:\WINDOWS\system32` — a relative path there resolves against system32 and fails with *"is not recognized"*. The scan output gives you the full path; paste that.

| Command | What it does |
|---|---|
| `Start-DiskDetective.ps1` | **Start here.** Read-only, ~25s. Probes the ~25 known accumulators. |
| `Start-DiskDetective.ps1 -Full` | Exhaustive: ranks every folder + growth-by-month. Minutes, not seconds. |
| `Invoke-DiskReclaim.ps1` | Cleanup. Dry-run by default; `-Execute` to act. |
| `Install-DiskDetective.ps1` | Install permanently + schedule it. See below. |

### Keeping it clean automatically

The quickstart clones into `%TEMP%`, which Windows eventually wipes — fine for a look, useless for anything recurring. One command installs it somewhere permanent and schedules a weekly cleanup. **Run as Administrator:**

```bash
& "$env:TEMP\dsd\scripts\windows\Install-DiskDetective.ps1"
```

That copies everything to `C:\Tools\DiskDetective`, registers a **weekly Sunday 09:00** task running with the privileges needed to reach `C:\Windows\Installer`, and writes one line per run to `reclaim.log`.

```bash
& "C:\Tools\DiskDetective\Install-DiskDetective.ps1" -Weekday Friday -At 18:00   # different slot
& "C:\Tools\DiskDetective\Install-DiskDetective.ps1" -DryRunOnly                 # report only, never deletes
& "C:\Tools\DiskDetective\Install-DiskDetective.ps1" -NoSchedule                 # install files only
& "C:\Tools\DiskDetective\Install-DiskDetective.ps1" -Uninstall                  # remove the task
```

Checking on it:

```bash
Get-ScheduledTaskInfo -TaskName DiskDetective; Get-Content C:\Tools\DiskDetective\reclaim.log
```

Run it now rather than waiting for Sunday: `Start-ScheduledTask -TaskName DiskDetective`

> Prefer `-DryRunOnly` for the first couple of weeks if you'd rather read the log before letting it delete anything unattended.

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
  posix/disk-detective.sh      the same detectors for macOS and Linux
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
