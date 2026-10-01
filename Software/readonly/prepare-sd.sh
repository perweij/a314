#!/usr/bin/env bash
#
# Run on a Linux PC with the Raspberry Pi SD card attached (not mounted by the Pi).
#
# Resizes the root partition (partition 2) to ROOT_SIZE and creates a third
# partition, ext4 labelled A314DATA, in the remaining space. That partition is
# later mounted as /home on the Pi by setup-readonly.sh.
#
# Works both on a freshly flashed card and on a card that has already been
# booted (where the root partition has been grown to fill the card).

set -euo pipefail

DATA_LABEL=A314DATA
ALIGN=8192                      # 4 MiB in 512 byte sectors
MIN_DATA_SECTORS=$((1024 * 2048)) # 1 GiB
ROOT_MARGIN=$((1024 * 1024 * 1024)) # free space to keep on root, in bytes

die() {
	echo "Error: $*" >&2
	exit 1
}

usage() {
	echo "Usage: sudo ./prepare-sd.sh <device> [root-size]"
	echo "       <device>     the whole SD card, e.g. /dev/sdb or /dev/mmcblk0"
	echo "       [root-size]  new size of the root partition, default 8G"
	exit 1
}

part() {
	case "$DEV" in
		*[0-9]) echo "${DEV}p$1" ;;
		*) echo "${DEV}$1" ;;
	esac
}

unmount_all() {
	udevadm settle
	for p in "$P1" "$P2" "$P3"; do
		if [ -b "$p" ] && findmnt -rn -S "$p" > /dev/null; then
			umount -A "$p"
		fi
	done
}

sectors_of() {
	cat "/sys/class/block/$(basename "$1")/$2"
}

[ $# -ge 1 ] && [ $# -le 2 ] || usage

if [ "$(id -u)" != 0 ] ; then
	echo "Please run prepare-sd.sh using sudo"
	exit 1
fi

for cmd in lsblk blkid sfdisk partprobe e2fsck resize2fs dumpe2fs mkfs.ext4 wipefs numfmt udevadm; do
	command -v $cmd > /dev/null || die "$cmd not found"
done

DEV=$(readlink -f "$1")
ROOT_BYTES=$(numfmt --from=iec "${2:-8G}") || die "invalid root size: ${2:-8G}"

P1=$(part 1)
P2=$(part 2)
P3=$(part 3)

# Sanity checks, so that we don't destroy the wrong disk

[ -b "$DEV" ] || die "$DEV is not a block device"

case "$(lsblk -ndo TYPE "$DEV")" in
	disk | loop) ;;
	*) die "$DEV is not a whole disk (use e.g. /dev/sdb, not /dev/sdb2)" ;;
esac

[ "$(blockdev --getss "$DEV")" = 512 ] || die "only 512 byte sectors are supported"
[ "$(blkid -po value -s PTTYPE "$DEV")" = dos ] || die "$DEV does not have an MBR (dos) partition table"

while read -r name; do
	while read -r mnt; do
		case "$mnt" in
			/ | /boot | /boot/efi | /usr | /var | /home)
				die "$DEV holds this computer's $mnt, refusing" ;;
		esac
	done < <(findmnt -rno TARGET -S "$name" || true)
	if grep -q "^$name " /proc/swaps; then
		die "$DEV holds this computer's swap, refusing"
	fi
done < <(lsblk -nrpo NAME "$DEV")

[ -b "$P1" ] && [ -b "$P2" ] || die "$DEV does not have two partitions"
[ "$(blkid -o value -s TYPE "$P1")" = vfat ] || die "$P1 is not a vfat boot partition"
[ "$(blkid -o value -s TYPE "$P2")" = ext4 ] || die "$P2 is not an ext4 root partition"
[ "$(blkid -o value -s LABEL "$P1")" = bootfs ] || die "$P1 is not labelled bootfs, is this a Raspberry Pi OS card?"
[ "$(blkid -o value -s LABEL "$P2")" = rootfs ] || die "$P2 is not labelled rootfs, is this a Raspberry Pi OS card?"

if [ -b "$P3" ]; then
	if [ "$(blkid -o value -s LABEL "$P3")" = "$DATA_LABEL" ]; then
		echo "$P3 is already labelled $DATA_LABEL, nothing to do"
		exit 0
	fi
	die "$DEV already has a third partition"
fi

# Compute the new layout

DISK_SECTORS=$(blockdev --getsz "$DEV")
P2_START=$(sectors_of "$P2" start)
P2_SECTORS=$(sectors_of "$P2" size)
P3_START=$(( (P2_START + ROOT_BYTES / 512 + ALIGN - 1) / ALIGN * ALIGN ))
NEW_P2_SECTORS=$((P3_START - P2_START))
P3_SECTORS=$(( (DISK_SECTORS - P3_START) / ALIGN * ALIGN ))

[ "$P3_SECTORS" -ge "$MIN_DATA_SECTORS" ] || die "not enough space left on $DEV for a data partition, try a smaller root size"

echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,MOUNTPOINTS "$DEV"
echo
echo "Root partition $P2: $(numfmt --to=iec $((P2_SECTORS * 512))) -> $(numfmt --to=iec $((NEW_P2_SECTORS * 512)))"
echo "New partition  $P3: $(numfmt --to=iec $((P3_SECTORS * 512))), ext4, label $DATA_LABEL"
echo
read -r -p "Modify the partitions on $DEV? Type YES to continue: " answer
[ "$answer" = YES ] || die "aborted"

# Unmount anything the desktop may have automounted
unmount_all

rc=0
e2fsck -f -y "$P2" || rc=$?
[ "$rc" -lt 4 ] || die "e2fsck failed on $P2 (exit code $rc)"

if [ "$NEW_P2_SECTORS" -lt "$P2_SECTORS" ]; then
	BLOCK_SIZE=$(dumpe2fs -h "$P2" 2> /dev/null | sed -n 's/^Block size: *//p')
	MIN_BLOCKS=$(resize2fs -P "$P2" 2> /dev/null | sed -n 's/^Estimated minimum size of the filesystem: *//p')
	[ -n "$BLOCK_SIZE" ] && [ -n "$MIN_BLOCKS" ] || die "could not determine minimum size of $P2"
	[ $((MIN_BLOCKS * BLOCK_SIZE + ROOT_MARGIN)) -le $((NEW_P2_SECTORS * 512)) ] ||
		die "root file system needs at least $(numfmt --to=iec $((MIN_BLOCKS * BLOCK_SIZE + ROOT_MARGIN))), try a larger root size"

	echo "Shrinking root file system"
	resize2fs "$P2" "${NEW_P2_SECTORS}s"
fi

# Keep the start sector so that the PARTUUID in cmdline.txt and fstab stays valid
echo "Resizing root partition"
echo "${P2_START},${NEW_P2_SECTORS}" | sfdisk --no-reread --wipe-partitions never -N 2 "$DEV"

echo "Creating data partition"
echo "${P3_START},${P3_SECTORS},L" | sfdisk --no-reread --wipe-partitions never --append "$DEV"

partprobe "$DEV"
udevadm settle
[ -b "$P3" ] || die "$P3 did not appear after re-reading the partition table"
unmount_all

# Grows the file system on a freshly flashed card; no-op after a shrink
resize2fs "$P2"

wipefs -q -a "$P3"
mkfs.ext4 -q -L "$DATA_LABEL" -E lazy_itable_init=0,lazy_journal_init=0 "$P3"

# The first boot of a freshly flashed card grows the root partition to the end
# of the card in the initramfs. That fails with a partition after it, so remove
# the request.
BOOT_MNT=$(mktemp -d)
mount "$P1" "$BOOT_MNT"
if grep -qE '(^| )resize( |$)' "$BOOT_MNT/cmdline.txt"; then
	echo "Removing 'resize' from cmdline.txt"
	sed -i -E 's/(^| )resize( |$)/\1/; s/ +$//' "$BOOT_MNT/cmdline.txt"
fi
umount "$BOOT_MNT"
rmdir "$BOOT_MNT"

unmount_all
e2fsck -f -n "$P2" > /dev/null || die "e2fsck reports problems on $P2"
e2fsck -f -n "$P3" > /dev/null || die "e2fsck reports problems on $P3"

echo
lsblk -o NAME,SIZE,FSTYPE,LABEL,PARTUUID "$DEV"
echo
echo "Done. Put the card back in the Raspberry Pi, boot it and run:"
echo "  sudo ./setup-readonly.sh"
