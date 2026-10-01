#!/usr/bin/env bash
#
# Run on the Raspberry Pi, after prepare-sd.sh has created the A314DATA
# partition. Makes the system survive being switched off together with the
# Amiga:
#
# - The root file system is read-only with a RAM overlay (overlayroot).
# - /home is on the A314DATA partition, mounted with 'sync' so that data is
#   on the SD card as soon as a write returns.
# - /boot/firmware is mounted read-only.
# - Swap is in compressed RAM only (zram).
#
# Use 'sudo a314-maint rw' / 'sudo a314-maint ro' to switch to and from a
# writable maintenance mode, e.g. for apt upgrade.

set -euo pipefail

DATA_LABEL=A314DATA
SCRIPT_DIR=$(dirname "$(readlink -f "$0")")

die() {
	echo "Error: $*" >&2
	exit 1
}

if [ "$(id -u)" != 0 ] ; then
	echo "Please run setup-readonly.sh using sudo (sudo ./setup-readonly.sh)"
	exit 1
fi

if [ -d /boot/firmware ]; then
	BOOT_FW_DIR=/boot/firmware
else
	BOOT_FW_DIR=/boot
fi

if [ "$(findmnt -no FSTYPE /)" = overlay ]; then
	die "the root file system is already read-only; run 'sudo a314-maint rw' and reboot first"
fi

DATA_DEV=$(blkid -L "$DATA_LABEL") ||
	die "no partition labelled $DATA_LABEL found; create it with prepare-sd.sh on a PC first"

command -v raspi-config > /dev/null || die "raspi-config not found"

# Copy /home to the data partition. The old /home stays on the root file
# system, hidden under the mount, as a fallback if the data partition fails.

if [ "$(findmnt -no SOURCE /home || true)" = "$DATA_DEV" ]; then
	echo "/home is already on $DATA_DEV"
else
	DATA_MNT=$(mktemp -d)
	mount "$DATA_DEV" "$DATA_MNT"
	if [ -z "$(find "$DATA_MNT" -mindepth 1 -maxdepth 1 ! -name lost+found -print -quit)" ]; then
		echo "Copying /home to $DATA_DEV"
		cp -a /home/. "$DATA_MNT/"
		sync
		if ! diff <(cd /home && find . | sort) \
		          <(cd "$DATA_MNT" && find . -path ./lost+found -prune -o -print | sort) > /dev/null; then
			umount "$DATA_MNT"
			die "copy of /home to $DATA_DEV is incomplete"
		fi
	else
		echo "$DATA_DEV already has contents, not copying /home"
	fi
	umount "$DATA_MNT"
	rmdir "$DATA_MNT"
fi

# Mount /home with a native systemd unit rather than /etc/fstab: with
# overlayroot=tmpfs, overlayroot turns every ext4 entry in fstab into a
# throw-away tmpfs overlay, and writes to /home would be lost.

cat > /etc/systemd/system/home.mount << 'EOF'
# Installed by a314 setup-readonly.sh
#
# Not in /etc/fstab on purpose: overlayroot replaces ext4 fstab entries with
# tmpfs overlays, which would make /home non-persistent.
[Unit]
Description=A314 persistent /home (sync, survives read-only root)
Requires=systemd-fsck@dev-disk-by\x2dlabel-A314DATA.service
After=systemd-fsck@dev-disk-by\x2dlabel-A314DATA.service
Before=local-fs.target

[Mount]
What=/dev/disk/by-label/A314DATA
Where=/home
Type=ext4
Options=sync,noatime,errors=remount-ro

[Install]
WantedBy=local-fs.target
EOF

# Don't start a314d with the fallback /home if the data partition is missing
mkdir -p /etc/systemd/system/a314d.service.d
cat > /etc/systemd/system/a314d.service.d/readonly.conf << 'EOF'
# Installed by a314 setup-readonly.sh
[Unit]
RequiresMountsFor=/home
EOF

systemctl daemon-reload
systemctl enable home.mount

# Swap in compressed RAM only; a swap file can't live on the read-only root
mkdir -p /etc/rpi/swap.conf.d
cat > /etc/rpi/swap.conf.d/80-a314-readonly.conf << 'EOF'
# Installed by a314 setup-readonly.sh
[Main]
Mechanism=zram
EOF
if [ -f /var/swap ]; then
	swapoff /var/swap 2> /dev/null || true
	grep -q '^/var/swap ' /proc/swaps || rm -f /var/swap
fi

# Package list updates would only fill up RAM in read-only mode
systemctl disable --now apt-daily.timer apt-daily-upgrade.timer

install -m755 "$SCRIPT_DIR/a314-maint" /usr/local/sbin
install -m644 "$SCRIPT_DIR/a314-readonly.sh" /etc/profile.d

# Enable the overlay file system; this also rebuilds the initramfs
if ! dpkg -s overlayroot > /dev/null 2>&1; then
	apt-get install -y overlayroot
fi
raspi-config nonint do_overlayfs 0
grep -q overlayroot=tmpfs "$BOOT_FW_DIR/cmdline.txt" || die "failed to enable overlayroot in cmdline.txt"

# Mount the boot partition read-only (same edit as raspi-config)
sed -i -E "\\#[[:space:]]${BOOT_FW_DIR}[[:space:]]# { /defaults,ro[ ,]/! s#defaults#defaults,ro# }" /etc/fstab

found=0
for f in "$BOOT_FW_DIR"/initramfs*; do
	# Not grep -q: with pipefail, lsinitramfs dying of SIGPIPE would fail the test
	if lsinitramfs "$f" 2> /dev/null | grep overlayroot > /dev/null; then
		found=1
	fi
done
if [ "$found" = 0 ]; then
	echo
	echo "Warning: overlayroot was not found in any initramfs in $BOOT_FW_DIR;"
	echo "the root file system may stay writable after reboot."
	echo "Check with 'a314-maint status' after rebooting."
fi

echo
echo "Setup complete. After a reboot:"
echo "  - everything outside /home is reset on every boot"
echo "  - /home is on $DATA_DEV, written to the SD card synchronously"
echo "  - use 'sudo a314-maint rw' before apt upgrade or network changes,"
echo "    and 'sudo a314-maint ro' afterwards"
echo
read -r -p "Reboot now? [y/N] " answer
case "$answer" in
	y | Y) systemctl reboot ;;
esac
