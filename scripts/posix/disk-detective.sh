#!/usr/bin/env bash
# disk-detective.sh - find what is silently filling a disk (macOS + Linux)
#
#   --scan [PATH]        rank top-level dirs by real size, then RECONCILE vs df
#   --growth PATH        bucket files by modification month (finds accumulators)
#   --versions PATH...   find parents holding multiple version-numbered subdirs
#   --deleted            find deleted-but-open files (df/du disagreement)
#   --snapshots          list APFS/Btrfs/ZFS snapshots that du cannot see
#   --all [PATH]         everything read-only
#
# READ-ONLY. This script never deletes anything.
#
# Portability: works with BSD (macOS) and GNU (Linux) userland. Differences in
# stat/find/du are detected at runtime rather than assumed.

set -uo pipefail

# ----------------------------------------------------------------- portability
if stat -c '%Y' . >/dev/null 2>&1; then
    STAT_MTIME() { stat -c '%Y' "$1"; }      # GNU
    STAT_INODE() { stat -c '%i' "$1"; }
else
    STAT_MTIME() { stat -f '%m' "$1"; }      # BSD / macOS
    STAT_INODE() { stat -f '%i' "$1"; }
fi

human() { awk 'function h(b){s="B KB MB GB TB";split(s,a," ");i=1;while(b>=1024&&i<5){b/=1024;i++}return sprintf("%.2f %s",b,a[i])} {print h($1)}' <<<"$1"; }
hr() { printf '%*s\n' "${COLUMNS:-72}" '' | tr ' ' '-'; }

# Version sort, newest first. `sort -V` is GNU; BSD/macOS sort does not have it and
# would fall back to LEXICAL order, where "app-1.0.9" sorts ABOVE "app-1.0.10" - i.e.
# it would name the wrong version as newest and mark the live one stale. Detected at
# runtime, with a numeric-field fallback rather than a silent wrong answer.
if printf '1.0.10\n1.0.9\n' | sort -V >/dev/null 2>&1; then
    VSORT_DESC() { sort -Vr; }
else
    VSORT_DESC() { sort -t. -k1,1nr -k2,2nr -k3,3nr -k4,4nr; }
fi

# ----------------------------------------------------------------------- scan
do_scan() {
    local root="${1:-/}"
    echo "== TOP-LEVEL SIZES under $root =="
    echo "(du -x: stays on one filesystem, does not follow symlinks)"
    echo

    # -x is essential: without it we wander into /proc, /sys, /Volumes, network mounts.
    sudo du -xd1 "$root" 2>/dev/null | sort -rn | head -30 | while read -r kb path; do
        printf '%10s  %s\n' "$(human $((kb*1024)))" "$path"
    done

    echo
    hr
    echo "== RECONCILIATION GATE =="
    # The whole point: a confident number is not a correct number. If the parts
    # do not add up to what the OS reports as used, the scan is WRONG - almost
    # always symlink double-counting or silently skipped unreadable trees.
    local used_kb sum_kb
    used_kb=$(df -k "$root" | awk 'NR==2{print $3}')
    sum_kb=$(sudo du -xd1 "$root" 2>/dev/null | awk -v r="$root" '$2!=r{s+=$1} END{print s+0}')

    echo "  df reports used : $(human $((used_kb*1024)))"
    echo "  sum of children : $(human $((sum_kb*1024)))"

    if [ "$used_kb" -gt 0 ]; then
        local pct
        pct=$(awk -v a="$sum_kb" -v b="$used_kb" 'BEGIN{d=(a-b)/b*100; print (d<0?-d:d)}')
        printf '  divergence      : %.1f%%\n' "$pct"
        if awk -v p="$pct" 'BEGIN{exit !(p>5)}'; then
            echo
            echo "  !! OVER 5% - DO NOT TRUST THIS SCAN."
            echo "  !! Check: symlink/bind-mount double counting, unreadable trees,"
            echo "  !! deleted-but-open files (--deleted), snapshots (--snapshots)."
        else
            echo "  OK - scan is trustworthy."
        fi
    fi
}

# --------------------------------------------------------------------- growth
do_growth() {
    local root="${1:?need a path}"
    echo "== BYTES BY MODIFICATION MONTH under $root =="
    echo "(a similar figure month after month = an ACCUMULATOR)"
    echo "(caveat: files rewritten in place - VM disks, DBs - always show current month)"
    echo

    # PORTABILITY: this used to pipe find into `xargs -0 -r stat $(...)` and format
    # the month with awk's strftime(). Every part of that was wrong somewhere:
    #   * BSD/macOS xargs has no -r          -> hard error on macOS
    #   * the unquoted $(...) word-split into "-c%Y" and "%s", so %s became a filename
    #   * strftime() is a GNU awk extension  -> BSD awk (macOS default) silently
    #                                           produces NOTHING, the worst outcome
    # perl does stat + month formatting + size in one step and ships on macOS and
    # essentially every Linux, so it is the portable choice here.
    if ! command -v perl >/dev/null 2>&1; then
        echo "  perl not found - growth-by-month needs it (ships with macOS and most Linux)."
        echo "  Install perl, or use the Windows scripts which do not depend on it."
        return 1
    fi

    find -P "$root" -type f -print0 2>/dev/null \
    | perl -0ne 'my @s = stat($_); next unless @s;
                 my @t = localtime($s[9]);
                 printf("%04d-%02d\t%d\n", $t[5]+1900, $t[4]+1, $s[7]);' 2>/dev/null \
    | awk -F'\t' '{sum[$1]+=$2} END{for(m in sum) printf "%s\t%d\n", m, sum[m]}' \
    | sort -r | head -18 | while IFS=$'\t' read -r month bytes; do
        printf '  %s  %12s\n' "$month" "$(human "$bytes")"
    done
}

# ------------------------------------------------------------------- versions
do_versions() {
    echo "== PARENTS HOLDING MULTIPLE VERSION-NUMBERED SUBDIRS =="
    echo "(the tell for an auto-updater that never removes old copies)"
    echo

    for root in "$@"; do
        [ -d "$root" ] || continue
        find -P "$root" -maxdepth 4 -type d 2>/dev/null \
        | grep -E '/(app-)?v?[0-9]+\.[0-9]+(\.[0-9]+)*$' \
        | while read -r d; do dirname "$d"; done \
        | sort | uniq -c | sort -rn \
        | awk '$1 >= 2 {print $1"\t"substr($0, index($0,$2))}' \
        | while IFS=$'\t' read -r count parent; do
            echo "  $parent"
            echo "     $count versions:"
            # Sort semantically (-V), NEWEST FIRST. Never sort by mtime:
            # timestamps tie, and a tie once deleted a LIVE application.
            find -P "$parent" -maxdepth 1 -type d 2>/dev/null \
            | grep -E '/(app-)?v?[0-9]+\.[0-9]+(\.[0-9]+)*$' \
            | VSORT_DESC | while read -r v; do
                sz=$(du -sk "$v" 2>/dev/null | cut -f1)
                printf '        %-40s %10s\n' "$(basename "$v")" "$(human $((sz*1024)))"
            done
            echo "     -> keep the FIRST (highest version); the rest are stale"
            echo "     -> but SKIP any with a running process (see below)"
        done
    done

    echo
    echo "  Running processes by executable dir (never prune these):"
    ps -eo comm= -o args= 2>/dev/null | awk '{print $1}' | grep '^/' | xargs -r -n1 dirname 2>/dev/null | sort -u | head -20 | sed 's/^/     /'
}

# -------------------------------------------------------------------- deleted
do_deleted() {
    echo "== DELETED-BUT-OPEN FILES =="
    echo "(space df counts and du cannot see; restart the holding process to free it)"
    echo
    if command -v lsof >/dev/null 2>&1; then
        sudo lsof -nP +L1 2>/dev/null | awk 'NR==1 || $NF ~ /deleted|^\// ' | head -25
    else
        echo "  lsof not installed - install it, this is a top cause of df/du divergence"
    fi
}

# ------------------------------------------------------------------ snapshots
do_snapshots() {
    echo "== SNAPSHOTS (invisible to du) =="
    echo
    if command -v tmutil >/dev/null 2>&1; then
        echo "-- APFS / Time Machine local snapshots --"
        tmutil listlocalsnapshots / 2>/dev/null || echo "  none"
        echo "  delete: tmutil deletelocalsnapshots <date>"
    fi
    if command -v btrfs >/dev/null 2>&1; then
        echo "-- Btrfs --"; sudo btrfs subvolume list / 2>/dev/null | head -20
    fi
    if command -v zfs >/dev/null 2>&1; then
        echo "-- ZFS --"; sudo zfs list -t snapshot 2>/dev/null | head -20
    fi
    if command -v snapper >/dev/null 2>&1; then
        echo "-- snapper --"; sudo snapper list 2>/dev/null | head -20
    fi
}

# ----------------------------------------------------------------------- main
case "${1:---all}" in
    --scan)      shift; do_scan "${1:-/}" ;;
    --growth)    shift; do_growth "${1:?usage: --growth PATH}" ;;
    --versions)  shift; do_versions "$@" ;;
    --deleted)   do_deleted ;;
    --snapshots) do_snapshots ;;
    --all)       shift
                 do_scan "${1:-/}"; echo; hr
                 do_deleted;        echo; hr
                 do_snapshots;      echo; hr
                 do_growth "$HOME"; echo; hr
                 do_versions "$HOME/.local" "$HOME/Applications" "/opt" "/Applications" 2>/dev/null ;;
    *) sed -n '2,20p' "$0"; exit 1 ;;
esac
