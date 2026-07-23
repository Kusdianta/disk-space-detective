# Linux accumulators

---

## 0. Measure correctly first

```bash
df -h                                        # per-filesystem
sudo du -xhd1 / 2>/dev/null | sort -hr | head -30
```

`-x` keeps you on one filesystem — without it you descend into `/proc`, `/sys`, bind mounts and network shares.

**If `df` and `du` disagree wildly, look for deleted-but-open files** — space held by a process that still has the handle. Classic cause: a log rotated with `rm` instead of `truncate`.

```bash
sudo lsof -nP +L1 | sort -k7 -n | tail -20    # link count 0 = deleted but open
```
Restarting the holding process releases it instantly. This is the single most-missed cause of "df says full, du says empty."

---

## 1. Journal logs — the top systemd accumulator

```bash
journalctl --disk-usage
sudo journalctl --vacuum-size=500M
sudo journalctl --vacuum-time=14d
```

Cap it permanently in `/etc/systemd/journald.conf`:
```ini
SystemMaxUse=500M
```
then `sudo systemctl restart systemd-journald`. Uncapped journals routinely reach many GB.

---

## 2. Package manager caches

```bash
# Debian/Ubuntu
sudo apt clean && sudo apt autoremove --purge
du -sh /var/cache/apt/archives

# Fedora/RHEL
sudo dnf clean all && sudo dnf autoremove

# Arch  (pacman keeps EVERY old package version)
sudo paccache -rk2                 # keep 2 most recent
sudo pacman -Sc
du -sh /var/cache/pacman/pkg
```

**Arch's `/var/cache/pacman/pkg` is a textbook ratchet** — every version of every package ever installed, forever.

---

## 3. Old kernels

Each kernel is ~200–400 MB across `/boot` and `/lib/modules`. A full `/boot` blocks upgrades.

```bash
dpkg --list | grep linux-image                    # Debian/Ubuntu
sudo apt autoremove --purge
sudo dnf remove --oldinstallonly --setopt installonly_limit=2   # Fedora
```

Always keep the running kernel (`uname -r`) plus one.

---

## 4. Snap and Flatpak — retained revisions

```bash
snap list --all                    # 'disabled' rows are old revisions
sudo snap set system refresh.retain=2
du -sh /var/lib/snapd/snaps

flatpak uninstall --unused
flatpak repair
```

Snap keeps old revisions by default and mounts each as a loop device — high-yield and rarely noticed.

---

## 5. Docker / Podman

```bash
docker system df                   # ALWAYS look before pruning
docker system prune -a --volumes   # WARNING: --volumes deletes data
docker builder prune
podman system prune -a
```

**Never `--volumes` without confirming** — that is user data, not cache. Overlay2 layers under `/var/lib/docker` are the usual bulk.

---

## 6. Logs and crash dumps

```
/var/log/                         # check for un-rotated giants
/var/crash/                       # apport / kdump
/var/lib/systemd/coredump/
```

```bash
sudo find /var/log -type f -size +100M -exec ls -lh {} \;
```

Fix un-rotated logs in `/etc/logrotate.d/` rather than deleting repeatedly. **Truncate, never `rm`, a log a process holds open** (see trap 0):
```bash
sudo truncate -s 0 /var/log/huge.log
```

---

## 7. Per-user caches

```
~/.cache/                          # often the biggest single user dir
~/.cache/pip  ~/.npm  ~/.cargo/registry  ~/.gradle/caches  ~/go/pkg/mod
~/.local/share/Trash/              # emptying the GUI trash is not always enough
~/.thumbnails  ~/.cache/thumbnails
```

```bash
du -xhd1 ~ 2>/dev/null | sort -hr | head -20
```

---

## 8. Filesystem-level reserves and snapshots

```bash
sudo btrfs filesystem usage /      # Btrfs
sudo btrfs subvolume list /
sudo snapper list                  # snapshots consume real space

sudo zfs list -t snapshot          # ZFS

sudo tune2fs -m 1 /dev/sdaX        # ext4 reserves 5% for root by default
```

Btrfs/ZFS snapshots and `timeshift` are frequent hidden consumers — `du` cannot see them.

---

## Authoritative "is this orphaned"

Ask the package manager, never the filename:

```bash
dpkg -S /path/to/file              # Debian/Ubuntu: which package owns it
rpm -qf /path/to/file              # RHEL/Fedora
pacman -Qo /path/to/file           # Arch
```

No owner ⇒ orphaned. Also:
```bash
sudo apt autoremove                # orphaned dependencies
sudo pacman -Qdtq | sudo pacman -Rns -   # Arch orphans
```

---

## Scheduling the permanent fix

**systemd timer** (preferred). `/etc/systemd/system/disk-reclaim.service`:
```ini
[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-detective.sh --reclaim --execute
```

`/etc/systemd/system/disk-reclaim.timer`:
```ini
[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
```

```bash
sudo systemctl enable --now disk-reclaim.timer
systemctl list-timers disk-reclaim.timer
```

`Persistent=true` runs a missed job after downtime.

**cron alternative:**
```cron
0 9 * * 0 /usr/local/bin/disk-detective.sh --reclaim --execute >> /var/log/disk-reclaim.log 2>&1
```
