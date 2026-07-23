# macOS accumulators

---

## 0. Read `du` correctly first

APFS **clone files** share storage until modified, so `du` can report far more than is consumed. And "Purgeable" space (snapshots, cached iCloud files) means Finder's free-space number and `df` disagree.

```bash
df -h /                      # what the OS reports
diskutil info / | grep -i 'free\|available'
sudo du -xhd1 / 2>/dev/null | sort -hr | head -30
```

`-x` stays on one filesystem — without it you wander into `/Volumes` and network mounts.

---

## 1. Time Machine local snapshots — the top hidden accumulator

macOS keeps local APFS snapshots even without an external backup disk. They consume real space and are invisible in Finder (shown only as "Purgeable").

```bash
tmutil listlocalsnapshots /
tmutil deletelocalsnapshots <snapshot-date>       # one
for s in $(tmutil listlocalsnapshots / | awk -F'com.apple.TimeMachine.' '{print $2}'); do tmutil deletelocalsnapshots "$s"; done
```

Frequently 10–50 GB. **First thing to check on a Mac.**

---

## 2. iOS device backups

```
~/Library/Application Support/MobileSync/Backup/
```

One full backup per device, retained forever, ~5–15 GB each. Users almost never know these exist.

---

## 3. Xcode — the developer ratchet

```
~/Library/Developer/Xcode/DerivedData          # regenerates, delete freely
~/Library/Developer/Xcode/iOS DeviceSupport    # one dir PER iOS VERSION, keeps them all
~/Library/Developer/Xcode/Archives             # release archives, retained forever
~/Library/Developer/CoreSimulator/Devices      # one runtime per OS version
```

`iOS DeviceSupport` and `CoreSimulator` are textbook ratchets — a new folder every OS release, nothing ever removed. Tens of GB.

```bash
xcrun simctl delete unavailable
```

---

## 4. Caches

```
~/Library/Caches/                 # per-user
/Library/Caches/                  # system
~/Library/Containers/<app>/Data/Library/Caches/
```

Adobe, DaVinci Resolve, and CapCut caches live here and are uncapped by default.

---

## 5. Mail and Messages attachments

```
~/Library/Mail/                   # V*/…/Attachments
~/Library/Messages/Attachments/
```

Grows forever on an IMAP account with large attachments.

---

## 6. Package manager caches

```bash
brew cleanup -s --prune=all       # ~/Library/Caches/Homebrew
npm cache clean --force
pip cache purge
uv cache clean
go clean -modcache
rm -rf ~/Library/Caches/pypoetry ~/.gradle/caches ~/.cargo/registry/cache
docker system prune -a            # Docker.raw does NOT shrink on its own
```

Docker Desktop's disk image:
```
~/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw
```
Grows and never shrinks. Reclaim from Docker Desktop → Troubleshoot, or recreate the disk.

---

## 7. Old system installers

`Install macOS *.app` in `/Applications` is 12–15 GB. Safe to delete after upgrading.

---

## Authoritative "is this orphaned"

macOS has no single installer database, but receipts are the closest equivalent:

```bash
pkgutil --pkgs                       # installed package IDs
pkgutil --files <pkg-id>             # files it owns
ls /var/db/receipts/                 # .bom + .plist per installed package
```

For Homebrew, `brew list --versions` is authoritative; anything in the Cellar not listed is stale.

---

## Scheduling the permanent fix (launchd)

`~/Library/LaunchAgents/com.user.diskreclaim.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>            <string>com.user.diskreclaim</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>/usr/local/bin/disk-detective.sh</string>
    <string>--reclaim</string>
    <string>--execute</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
    <key>Weekday</key><integer>0</integer>
    <key>Hour</key><integer>9</integer>
    <key>Minute</key><integer>0</integer>
  </dict>
  <key>StandardOutPath</key>  <string>/tmp/diskreclaim.log</string>
  <key>StandardErrorPath</key><string>/tmp/diskreclaim.err</string>
</dict>
</plist>
```

```bash
launchctl load -w ~/Library/LaunchAgents/com.user.diskreclaim.plist
```

Full-disk operations need **Full Disk Access** granted to the executing binary (Terminal, or `/bin/bash`) in System Settings → Privacy & Security.
