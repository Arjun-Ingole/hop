#!/bin/bash
# Runs shrink.sh against real NTFS on a loop device, laid out as Windows lays out a disk, and checks what it did:
# every file the same, only the partition's end moved, the other partitions untouched. And that each refusal
# leaves the disk byte for byte as it was. Needs root, ntfs-3g, util-linux, gdisk and the kernel's ntfs3.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
. "$HERE/shrink.sh"
WORK=${WORK:-/tmp/hop-shrink-test}
IMG=$WORK/disk.img
FAILS=0
mkdir -p "$WORK"

check() { if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1 ${3:-}"; FAILS=$((FAILS + 1)); fi; }
attach() { LOOP=$(losetup -P --show -f "$IMG"); udevadm settle; for i in $(seq 1 50); do [ -b "${LOOP}p3" ] && break; sleep 0.1; done; }
detach() { losetup -d "$LOOP"; }
hashes() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum); }

# ESP, MSR, C: and a recovery partition, numbered as Setup numbers them.
make_disk() {
    rm -f "$IMG"; truncate -s 8G "$IMG"
    sgdisk -o -n 1:2048:+100M -t 1:ef00 -c 1:'EFI system partition' \
        -n 2:0:+16M -t 2:0c01 -c 2:'Microsoft reserved partition' \
        -n 3:0:-600M -t 3:0700 -c 3:'Basic data partition' -A 3:set:63 \
        -n 4:0:0 -t 4:2700 -c 4:'Basic data partition' -A 4:set:0 "$IMG" >/dev/null
    attach
    mkfs.fat -F 32 "${LOOP}p1" >/dev/null
    mkntfs -Q -L Windows "${LOOP}p3" >/dev/null
    mkntfs -Q -L Recovery "${LOOP}p4" >/dev/null
    mkdir -p "$WORK/c"
    mount -t ntfs3 "${LOOP}p3" "$WORK/c"
    mkdir -p "$WORK/c/Windows/System32" "$WORK/c/Users/hop/Documents"
    head -c 300M /dev/urandom > "$WORK/c/Windows/System32/stand-in.bin"
    # A placeholder takes the middle, so what's written next lands near the end, where only a move gets it out of the way.
    free=$(df -B1 --output=avail "$WORK/c" | tail -n 1)
    fallocate -l $((free - 900 * 1048576)) "$WORK/c/placeholder.bin" ||
        dd if=/dev/zero of="$WORK/c/placeholder.bin" bs=16M count=$(((free - 900 * 1048576) >> 24)) status=none
    for i in 1 2 3 4 5 6; do head -c 100M /dev/urandom > "$WORK/c/Users/hop/Documents/late-$i.bin"; done
    rm "$WORK/c/placeholder.bin"
    for i in $(seq 1 3000); do echo "contents $i" > "$WORK/c/Users/hop/Documents/small-$i.txt"; done
    hashes "$WORK/c" > "$WORK/files.before"
    umount "$WORK/c"
    sync
}

image_sum() { sha256sum "$IMG" | cut -d' ' -f1; }

refuses() {
    name=$1; shift
    before=$(image_sum)
    attach
    out=$(shrink_partition "${LOOP}p3" "$@" 2>&1 | tail -n 1)
    detach
    case "$out" in failed:*) check "refuses $name: $out" 0 ;; *) check "refuses $name" 1 "said: $out" ;; esac
    [ "$(image_sum)" = "$before" ]; check "  and $name leaves the disk as it was" $?
}

make_disk
SIZE=$(blockdev --getsize64 "${LOOP}p3")
INFO3=$(sgdisk -i 3 "$IMG"); P1=$(sha256sum "${LOOP}p1" | cut -d' ' -f1); P4=$(sha256sum "${LOOP}p4" | cut -d' ' -f1)
echo "C: is $((SIZE >> 20)) MiB"
ntfsresize --info --force --no-action "${LOOP}p3" | grep -iE 'resize at|current volume size'
detach

NEW=$(( (SIZE - 3 * 1073741824) / 1048576 * 1048576 ))
refuses 'a size that changed since hop planned' $((SIZE + 1048576)) "$NEW"
refuses 'a size smaller than its files' "$SIZE" 1048576
refuses 'a size that isn''t whole MiB' "$SIZE" $((NEW + 512))
refuses 'growing' "$SIZE" $((SIZE + 1048576))

# Windows left hibernated: nothing may change. ntfsresize itself doesn't check. A hibernation file Windows woke from is fine.
cp "$IMG" "$WORK/plain.img"
attach; mount -t ntfs3 "${LOOP}p3" "$WORK/c"
{ printf 'HIBR'; head -c 4092 /dev/zero; } > "$WORK/c/hiberfil.sys"
umount "$WORK/c"; detach
refuses 'a hibernated Windows' "$SIZE" "$NEW"
cp "$WORK/plain.img" "$IMG"
attach; mount -t ntfs3 "${LOOP}p3" "$WORK/c"
head -c 4096 /dev/zero > "$WORK/c/hiberfil.sys"
umount "$WORK/c"
out=$(shrink_partition "${LOOP}p3" "$SIZE" "$NEW" 2>&1 | tail -n 1)
detach
case "$out" in ok*) check 'shrinks with a hibernation file Windows woke from' 0 ;; *) check 'shrinks with a hibernation file Windows woke from' 1 "said: $out" ;; esac
mv "$WORK/plain.img" "$IMG"

# BitLocker's signature where NTFS's would be.
cp "$IMG" "$WORK/plain.img"
attach; printf '\xeb\x58\x90-FVE-FS-' | dd of="${LOOP}p3" conv=notrunc status=none; detach
refuses 'BitLocker' "$SIZE" "$NEW"
mv "$WORK/plain.img" "$IMG"

# The real thing.
attach
out=$(shrink_partition "${LOOP}p3" "$SIZE" "$NEW" 2>&1); code=$?
echo "$out" | tail -n 20
check "shrinks C: to $((NEW >> 20)) MiB: $(echo "$out" | tail -n 1)" $code
detach; attach
[ "$(blockdev --getsize64 "${LOOP}p3")" = "$NEW" ]; check 'the partition is the new size' $?
INFO3B=$(sgdisk -i 3 "$IMG")
[ "$(echo "$INFO3" | grep -vE 'Last sector|Partition size')" = "$(echo "$INFO3B" | grep -vE 'Last sector|Partition size')" ]
check 'its start, type, ID, name and attributes are the same' $? "$(diff <(echo "$INFO3") <(echo "$INFO3B"))"
[ "$(sha256sum "${LOOP}p1" | cut -d' ' -f1)" = "$P1" ]; check 'the EFI partition is untouched' $?
[ "$(sha256sum "${LOOP}p4" | cut -d' ' -f1)" = "$P4" ]; check 'the recovery partition is untouched' $?
sgdisk -v "$IMG" | grep -q 'No problems found'; check 'the GPT checks out' $? "$(sgdisk -v "$IMG")"
ntfsresize --info --force --no-action "${LOOP}p3" | grep -iE 'volume size|resize at'
mount -t ntfs3 -o ro "${LOOP}p3" "$WORK/c"
hashes "$WORK/c" > "$WORK/files.after"
umount "$WORK/c"
diff -q "$WORK/files.before" "$WORK/files.after" >/dev/null; check "every file on C: is the same ($(wc -l < "$WORK/files.before") files)" $?
ntfsfix --no-action "${LOOP}p3"; check 'ntfsfix finds nothing to fix' $?
SIZE2=$(blockdev --getsize64 "${LOOP}p3")
detach
# ntfsresize leaves the volume marked for Windows to check, so a second go before Windows has been must be refused.
refuses 'a second shrink before Windows has checked the drive' "$SIZE2" $((SIZE2 - 1073741824))

echo "$FAILS failed"
exit $FAILS
