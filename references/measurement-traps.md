# Measurement traps — read this regardless of OS

Every one of these produces a **confident wrong number** rather than an error. They are the reason the reconciliation gate exists.

---

## 1. Link traversal double-counts (all platforms)

Recursive sizing tools follow symlinks, junctions, and directory reparse points, counting the same bytes under several parents.

**Symptom:** identical sizes appearing for unrelated directories; total far exceeding disk capacity.

**Real example (Windows):** `C:\Users\All Users` is a junction to `C:\ProgramData`. A naive scan reported both at 28.07 GB and the same bytes again under the profile.

**Fix:** skip any entry whose attributes include a reparse point / symlink. Never descend into one — size its target separately.

- Windows/.NET: `(attributes & FileAttributes.ReparsePoint) != 0`
- POSIX: `find -P` (default, does not follow), and `du -x` to stay on one filesystem

---

## 2. Silent enumeration failure on long paths (Windows especially)

A path exceeding `MAX_PATH` (260 chars) aborts the walk. With errors suppressed you get an **empty result that looks like a clean folder**.

**Real example:** `Get-ChildItem -Recurse` returned **0 files** for a directory actually holding **39,277 files / 22.4 GB**. A cleanup script built on it reported "nothing to reclaim" on 22 GB of garbage.

**Fix:** use .NET `Directory.EnumerateFiles`/`EnumerateDirectories` in an explicit stack, and **guard against empty results**: if a directory is known to be large but enumeration returns nothing, warn loudly instead of reporting "clean."

```powershell
if (-not $files -and $folderTotalGB -gt 1) {
    Write-Warning "0 files matched but folder holds $folderTotalGB GB - enumeration is SUSPECT, not clean"
}
```

---

## 3. Access-denied trees vanish silently

Unreadable directories contribute 0 with `SilentlyContinue` / `2>/dev/null`. Large system areas disappear from the total.

**Fix:** **count** what you could not read and report it alongside the total. A scan that skipped 270 nodes is a scan with a caveat. Re-run privileged when the gap is material.

---

## 4. Hardlinks and clones inflate totals

The same physical bytes appear at multiple paths, and neither is a symlink, so link-skipping does not help.

- **Windows:** `WinSxS` hardlinks into `System32`. Its apparent size overstates real cost.
- **Windows MSIX/Store apps:** an app's data is visible at *both* `%APPDATA%\<App>` and `%LOCALAPPDATA%\Packages\<Pkg>\LocalCache\Roaming\<App>`. Redirection is done by a filter driver, **not** a reparse point — so every tool double-counts it.
- **macOS APFS:** clone files share storage until modified. `du` may report far more than is actually consumed.

**Detect it — compare file identity, not paths:**

```powershell
fsutil file queryfileid "C:\path\a"      # identical IDs => one physical copy
```
```bash
stat -c '%i' /path/a  /path/b            # Linux: same inode => same bytes
stat -f '%i' /path/a  /path/b            # macOS
```

**Real example:** an app appeared to occupy 26.7 GB across two locations. Identical file IDs proved it was **13.3 GB once**.

---

## 5. mtime is not age for rewritten files

Bucketing by modification time is the best growth detector, but any file written **in place** — VM disks, container images, databases, log files — carries today's date no matter how old the data is.

**Symptom:** the current month appears to account for an implausible share of the disk.

**Fix:** treat large single files separately from many-small-files directories. A 28 GB container disk dated today is not 28 GB of this month's growth.

---

## 6. Apparent size vs. allocated size

Sparse files (VM disks, database preallocation) report a logical size far larger than blocks consumed. Compressed filesystems report the opposite.

**Fix:** `du --apparent-size` vs plain `du` on POSIX; on Windows compare *Size* with *Size on disk*. When they diverge, say which you are quoting.

---

## 7. The tool's own units

`du` defaults to 512-byte blocks on some BSD/macOS configurations, KB elsewhere. Always pass an explicit unit flag (`-h`, `-m`, `-BG`).

---

## Reconciliation gate

After any full scan:

```
sum(top-level dirs) + sum(root files)  ≈  OS-reported used space
```

Within ~5% → trust it. Outside → **the scan is wrong**; work through traps 1–4 above before interpreting anything.

Getting this check right is what turned a wrong answer ("`C:\Users` is 10 GB") into the correct one ("197 GB") in the reference investigation.
