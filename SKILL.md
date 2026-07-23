---
name: disk-space-detective
description: Find what is silently filling a disk, identify the root cause by measurement, and install a permanent fix. Use when a drive keeps filling up, free space shrinks month over month, cleaning caches stops helping, or the user asks "what is eating my disk". Works on Windows, macOS, and Linux.
---

# Disk Space Detective

Find the thing that refills a disk every month, prove it by measurement, and stop it permanently.

This is **not** a "run a cleaner" skill. Cleaners only remove what they already know about. This skill exists for the case where the user *already* clears the obvious caches and space still disappears — which means the real accumulator is something no cleaner looks at.

## Core principle

> **Measure. Never guess. Then verify the measurement itself.**

The most common failure is not picking the wrong folder to delete — it is **believing a broken measurement**. Every sizing tool on every OS has silent failure modes that under-report by 10x (see `references/measurement-traps.md`). A scan that returns a confident number is not the same as a correct number.

**Reconciliation gate — do this before drawing any conclusion:**

```
sum(top-level folders) + sum(root files)  ≈  used space reported by the OS
```

If those disagree by more than ~5%, **your scan is wrong** — you are following symlinks into double-counts, or silently skipping unreadable trees, or missing hidden/system files. Fix the measurement before continuing. In the reference case this check caught a scan reporting a 197 GB directory as 10 GB.

## Workflow

### Phase 0 — Frame the problem

Ask, or infer from what the user already said:

1. **How much, how often?** "40 GB a month" is a different problem from "it filled up once."
2. **What have they already cleared?** Do not re-investigate ruled-out territory. Note it and move on.
3. **What must never be touched?** Source code, video projects, VM/container data, model weights, photo libraries.

Distinguish two very different phenomena, because the fix differs:

| Pattern | Meaning | Fix |
|---|---|---|
| **Churn** | Regenerating caches. Cleared, comes back, cleared again. Space *returns* each cycle. | Cap it, or accept it |
| **Ratchet** | Grows monthly, never shrinks, survives every cleanup. Free space trends down permanently. | **This is the real target** |

A user saying "I clear 40 GB every month and I'm still out of space" is describing churn that they handle **plus** a ratchet they have not found. Find the ratchet.

### Phase 1 — Baseline

Record real free space *before* touching anything. You will report the delta later, and you need an honest starting number.

### Phase 2 — Rank top-level, then reconcile

Size every top-level directory and every large root-level file. Sort descending. **Then run the reconciliation gate above.** Do not proceed past a failed reconciliation.

Use the platform script (`scripts/`) rather than naive recursion — they exist specifically to avoid the traps.

### Phase 3 — Drill

Recurse into the top offenders until you can name specific directories. Stop when a line item is explainable in one sentence.

### Phase 4 — Find the ratchet

Three independent detectors. Run all three — each catches what the others miss.

**4a. Bucket every file by modification month.** A directory holding a similar number of GB in month after month is accumulating. This is the strongest single signal.

> Caveat: large files rewritten *in place* (VM disks, databases, container images) always show the current month regardless of age. Do not mistake an active file for new growth. Cross-check size history, not just mtime.

**4b. Look for retained version folders.** Multiple sibling directories named like versions (`app-1.2.3`, `v2.0`, `1.4.7`) means an auto-updater is keeping old copies. Report how many and their combined size.

**4c. Look for package/patch caches.** OS and app installers cache packages permanently and rarely garbage-collect superseded ones. This is the highest-yield category and the one users never find on their own — see the per-OS references.

**Treat each detector as a hypothesis to be falsified.** In the reference case, the version-folder hypothesis looked obvious and was *wrong* — it accounted for 2.27 GB against a 41 GB culprit. Report rejected hypotheses explicitly; a ruled-out suspect is a real result.

### Phase 5 — Classify

Produce a ranked table. Every row gets a verdict:

| Verdict | Meaning |
|---|---|
| `JUNK-delete` | Dead weight. Nothing references it. |
| `CACHE-safe` | Regenerates on demand. Safe, costs a rebuild. |
| `DATA-keep` | Real data. Never delete. |
| `MOVABLE` | Large and personal. Propose relocating, not deleting. |

### Phase 6 — Root cause

State plainly which **one or two** things cause the recurrence, and *why it comes back*. The mechanism matters more than the number — "the updater caches every patch permanently and never deletes the superseded one" is what makes the permanent fix obvious.

**Be honest about arithmetic.** If the accumulator adds 2.7 GB/month and the user believes they lose 40 GB/month, say so and explain the rest. Do not inflate a finding to match the user's framing.

### Phase 7 — Reclaim, with confirmation

**Confirm before every destructive action. One item at a time. Show the command first. Report actual GB freed after each step.**

Order: safest and largest first. No-elevation, zero-risk items before privileged, riskier ones.

Prefer **quarantine over delete** when the destination has room — move to a holding directory, verify normal operation for a week, then delete. If it does not fit, say so rather than silently switching to deletion.

**Hard safety rules:**

- **Never delete from a directory that a running process is using.** Enumerate running process paths and exclude matches. A file lock is the OS telling you it is in use.
- **Sort versions semantically, never by timestamp.** Timestamps tie and lie. In the reference case an mtime sort deleted the *live* application and kept a stub.
- **Establish "orphaned" from the package database, never from the filename.** Query the OS package manager / installer registry for referenced paths; anything on disk and not referenced is orphaned.
- **If the reference query returns zero, abort.** Zero references means the query failed, not that everything is orphaned. Acting on it destroys live packages.

### Phase 8 — Verify

After reclaiming, prove nothing load-bearing was lost:

- Re-query the package database and confirm every referenced path still exists on disk.
- Confirm affected applications still launch / are registered.
- Report real before/after free space.

If something did break, say so immediately and fix it before moving on.

### Phase 9 — Permanent fix

A one-time cleanup is a failure. Deliver:

1. **A reusable script**, dry-run by default, requiring an explicit flag to act.
2. **A scheduled job** (Task Scheduler / launchd / cron / systemd timer) so it never needs doing by hand.
3. **A log**, one line per run, so unattended runs are auditable.

Where a setting can prevent accumulation at the source (cap a cache, disable a log, redirect a directory), prefer that over recurring cleanup — but only if it does not degrade something the user relies on.

## Platform references

Read the one matching the user's OS. Each lists the high-yield accumulators, the authoritative "is this orphaned" query, and safe cleanup commands.

- `references/windows.md`
- `references/macos.md`
- `references/linux.md`
- `references/measurement-traps.md` — **read this one regardless of OS**

## Scripts

- `scripts/windows/` — PowerShell 5.1-compatible sizing, growth-by-month, version-folder and orphaned-package detection, plus a reclaim script
- `scripts/posix/disk-detective.sh` — the same detectors for macOS and Linux

All scripts are **read-only by default**. Only the reclaim scripts modify anything, and only with an explicit `-Execute` / `--execute` flag.

## Reporting

Lead with the ranked table, then root cause, then the proposed fix. Include:

- Real before/after free space, not estimates
- Hypotheses **rejected** by measurement, with their numbers
- Any measurement correction you had to make mid-investigation — if a first scan was wrong, say so and say why
- What you did **not** touch, and why
