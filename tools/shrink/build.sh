#!/bin/bash
# Builds hop's shrink image in a Fedora container: Fedora's own signed shim, GRUB and kernel, so it starts with Secure
# Boot on, and a small initramfs of busybox, ntfsresize and sfdisk with shrink.sh and init. Nothing in it is rebuilt from
# source, and the initramfs isn't something shim checks. Writes OUT/hop-shrink/ and OUT/hop-shrink.zip, plus manifest.txt.
#   build.sh OUT
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OUT=$(realpath -m "${1:?output folder}")
WORK=$(mktemp -d)
mkdir -p "$OUT"

dnf -y -q install cpio zstd xz gzip zip findutils kmod busybox ntfsprogs util-linux >/dev/null
cd "$WORK"
dnf -q download kernel-core kernel-modules-core shim-x64 grub2-efi-x64 >/dev/null
# Signed by Fedora, with the keys the container trusts, before anything in them is used.
for rpm in *.rpm; do rpm -K "$rpm" | grep -q 'signatures OK' || { echo "$rpm isn't signed as Fedora signs it" >&2; exit 1; }; done
for rpm in *.rpm; do rpm2cpio "$rpm" | cpio -idm --quiet; done
KVER=$(ls lib/modules | sort -V | tail -n 1)
echo "kernel $KVER"

ROOT=$WORK/initramfs
mkdir -p "$ROOT"/{bin,sbin,usr/bin,usr/sbin,lib64,proc,sys,dev,tmp,esp,lib/modules}
copy_bin() {
    local path
    path=$(command -v "$1")
    install -D -m 0755 "$path" "$ROOT$path"
    ldd "$path" 2>/dev/null | grep -oE '/[^ ]+\.so[^ ]*' | while read -r lib; do
        [ -e "$ROOT$lib" ] || install -D -m 0755 "$lib" "$ROOT$lib"
    done
}
install -m 0755 "$(command -v busybox)" "$ROOT/bin/busybox"
for tool in ntfsresize ntfsfix ntfscat sfdisk blkid blockdev; do copy_bin "$tool"; done

# The drivers for the disks a PC might have and for the EFI partition, with what they need.
MODS=$WORK/lib/modules/$KVER
depmod -b "$WORK" "$KVER"
for module in nvme vmd ahci sd_mod virtio_blk virtio_scsi virtio_pci mmc_block sdhci_pci vfat nls_cp437 nls_iso8859_1 nls_ascii; do
    modprobe -d "$WORK" -S "$KVER" --show-depends "$module" 2>/dev/null | awk '$1 == "insmod" { print $2 }' || true
done | sort -u | while read -r path; do
    # Uncompressed, so busybox's modprobe needn't read xz or zstd.
    target=$ROOT${path#"$WORK"}
    mkdir -p "$(dirname "$target")"
    case "$path" in
        *.ko.xz) xz -dc "$path" > "${target%.xz}" ;;
        *.ko.zst) zstd -dcq "$path" > "${target%.zst}" ;;
        *.ko.gz) gzip -dc "$path" > "${target%.gz}" ;;
        *) install -m 0644 "$path" "$target" ;;
    esac
done
cp "$MODS"/modules.{order,builtin,builtin.modinfo} "$ROOT/lib/modules/$KVER/" 2>/dev/null || true
depmod -b "$ROOT" "$KVER"

install -m 0755 "$HERE/init" "$ROOT/init"
install -m 0644 "$HERE/shrink.sh" "$ROOT/shrink.sh"
(cd "$ROOT" && find . -print0 | sort -z | cpio --null -o -H newc --quiet | zstd -19 -q -o "$WORK/initrd.img")

DEST=$OUT/hop-shrink
rm -rf "$DEST"; mkdir -p "$DEST"
cp "$MODS/vmlinuz" "$DEST/vmlinuz"
find "$WORK" -path "$ROOT" -prune -o -iname '*.efi' -print
one() { local found; found=$(find "$WORK" -path "$ROOT" -prune -o -type f -name "$1" -print | head -n 1); [ -n "$found" ] || { echo "no $1 in the packages" >&2; exit 1; }; echo "$found"; }
cp "$(one shimx64.efi)" "$DEST/shimx64.efi"
cp "$(one grubx64.efi)" "$DEST/grubx64.efi"
cp "$WORK/initrd.img" "$DEST/initrd.img"
{
    echo "hop shrink image"
    echo "kernel $KVER"
    for rpm in "$WORK"/*.rpm; do rpm -qp --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' "$rpm" 2>/dev/null; done
    rpm -q busybox ntfsprogs util-linux
    (cd "$DEST" && sha256sum *)
} > "$OUT/manifest.txt"
(cd "$OUT" && rm -f hop-shrink.zip && zip -q -X -r hop-shrink.zip hop-shrink)
cat "$OUT/manifest.txt"
du -sh "$DEST"/*
du -sh "$OUT/hop-shrink.zip"
