# --- Shrinking a drive from outside Windows ------------------------------------
# Windows can't move some of its own files, $Mft::$BITMAP among them, so on some PCs it can release almost none of a
# drive with plenty free. Outside Windows, nothing has them open, and ntfsresize moves them, as GParted does. hop's
# shrink image, built by tools/shrink, is Fedora's signed shim, GRUB and kernel with a small initramfs that does only
# that: it's started once, shrinks the drive, writes what happened to the EFI partition and restarts into Windows.

$ShrinkFolder = 'EFI\hop-shrink'   # on Windows' EFI partition
$ShrinkFiles = @('shimx64.efi', 'grubx64.efi', 'vmlinuz', 'initrd.img')

# The menu Fedora's GRUB reads next to itself. It starts the one entry at once. The line says exactly what to shrink and
# from what size, so a drive that changed since can't be shrunk by an old plan. Partition IDs in lower case, as blkid has them.
function Get-ShrinkGrubConfig([string]$PartitionGuid, [int64]$Was, [int64]$NewSize, [string]$EspGuid, [string]$Id, [string]$Extra = '') {
    $part = $PartitionGuid.Trim('{}').ToLowerInvariant()
    $esp = $EspGuid.Trim('{}').ToLowerInvariant()
    $line = "hop.part=$part hop.was=$Was hop.size=$NewSize hop.esp=$esp hop.id=$Id quiet loglevel=3$(if ($Extra) { " $Extra" })"
    @(
        'set timeout=0'
        "menuentry 'hop: make room for Linux' {"
        "    linux /$($ShrinkFolder -replace '\\', '/')/vmlinuz $line"
        "    initrd /$($ShrinkFolder -replace '\\', '/')/initrd.img"
        '}'
    )
}
