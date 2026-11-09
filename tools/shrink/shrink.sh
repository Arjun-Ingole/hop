# Shrinks one NTFS partition, as GParted does: ntfsresize first, then the partition's end in the GPT, keeping its start,
# type, ID, name and attributes. Sourced by init in hop's shrink image, and by test.sh on a Linux machine.
#
# Every check comes before anything is written, and a failure changes nothing, except one: ntfsresize failing part way
# through a real resize. Then the partition table is left alone, so Windows' own disk check sees the file system it knows.
#
# shrink_partition DEVICE WAS_BYTES NEW_BYTES prints one line, "ok ..." or "failed: why", and returns 0 only for ok.

say() { echo "hop: $*"; }

# The disk a partition is on and its number there, from sysfs.
part_disk() {
    name=$(basename "$1")
    [ -r "/sys/class/block/$name/partition" ] || return 1
    PART_NUMBER=$(cat "/sys/class/block/$name/partition")
    PART_DISK=/dev/$(basename "$(readlink -f "/sys/class/block/$name/..")")
}

# The partition's line in sfdisk's dump, which has every field it keeps.
part_line() { sfdisk --dump "$PART_DISK" 2>/dev/null | grep -E "^$1[[:space:]]*:" ; }

field() { echo "$1" | tr ',' '\n' | sed -n "s/^[[:space:]]*$2=[[:space:]]*//p" | head -n 1; }

shrink_partition() {
    dev=$1; was=$2; new=$3
    [ -b "$dev" ] || { echo "failed: no partition at $dev"; return 1; }
    part_disk "$dev" || { echo "failed: $dev isn't a partition"; return 1; }
    ss=$(blockdev --getss "$PART_DISK") || { echo "failed: can't read the disk's sector size"; return 1; }
    size=$(blockdev --getsize64 "$dev") || { echo "failed: can't read the partition's size"; return 1; }
    # What hop planned from must still be what's there.
    [ "$size" = "$was" ] || { echo "failed: the partition is $size bytes, not the $was hop planned for"; return 1; }
    case "$new" in ''|*[!0-9]*) echo "failed: no new size"; return 1 ;; esac
    [ "$new" -lt "$size" ] || { echo "failed: $new bytes isn't smaller than $size"; return 1; }
    [ $((new % 1048576)) -eq 0 ] || { echo "failed: $new bytes isn't whole MiB"; return 1; }
    type=$(blkid -p -o value -s TYPE "$dev" 2>/dev/null)
    [ "$type" = ntfs ] || { echo "failed: $dev holds ${type:-nothing blkid knows}, not NTFS"; return 1; }
    before=$(part_line "$dev")
    [ -n "$before" ] || { echo "failed: $dev isn't in the partition table of $PART_DISK"; return 1; }
    start=$(field "$before" start)

    # ntfsresize doesn't look at this, and resizing under a hibernated Windows loses what it was in the middle of.
    # Its first bytes say so, as ntfs-3g reads them: hibr or HIBR while hibernated. After waking, Windows clears them.
    hib=$(ntfscat "$dev" hiberfil.sys 2>/dev/null | head -c 4)
    case "$hib" in hibr|HIBR) echo "failed: Windows is hibernated, not shut down, so nothing changed"; return 1 ;; esac

    say "Checking drive C: can shrink to $((new >> 20)) MiB..."
    # Refuses a volume marked for a disk check, and a size its files don't fit in.
    if ! ntfsresize --no-action --no-progress-bar --size "$new" "$dev"; then
        echo "failed: ntfsresize would not shrink it, so nothing changed"
        return 1
    fi
    say "Moving files and shrinking drive C:. Don't turn off the PC."
    if ! printf 'y\n' | ntfsresize --no-progress-bar --size "$new" "$dev"; then
        echo "failed: ntfsresize stopped part way. The partition table is as it was, and Windows will check the drive when it starts"
        return 1
    fi
    say "Shrinking the partition to match..."
    sectors=$((new / ss))
    if ! echo ",$sectors" | sfdisk --no-reread --no-tell-kernel --quiet -N "$PART_NUMBER" "$PART_DISK"; then
        echo "failed: the file system shrank but the partition didn't, which Windows can still use"
        return 1
    fi
    after=$(part_line "$dev")
    # Only the size may differ.
    if [ "$(field "$after" start)" != "$start" ] || [ "$(field "$after" size)" != "$sectors" ] ||
       [ "$(echo "$before" | sed 's/size=[^,]*,//')" != "$(echo "$after" | sed 's/size=[^,]*,//')" ]; then
        echo "failed: the partition table doesn't read as planned: before [$before], after [$after]"
        return 1
    fi
    echo "ok $size $new"
}
