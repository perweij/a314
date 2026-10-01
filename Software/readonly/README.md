# Read-only root file system for the A314 Raspberry Pi

The Raspberry Pi in an A314 is normally switched off together with the Amiga,
without being shut down. Data still in the write cache is then lost, and a
power cut while the SD card is writing can corrupt the file system or the
card itself.

The scripts in this directory set up the Raspberry Pi so that this is safe:

- The root file system is mounted read-only with a RAM overlay
  ([overlayroot](https://launchpad.net/cloud-initramfs-tools), the same
  mechanism as the "Overlay File System" option in `raspi-config`).
  Changes outside `/home` work as usual but are lost at power off.
- `/home` is on a separate ext4 partition, labelled `A314DATA`, mounted with
  the `sync` option. When a write returns, for example from the Amiga to the
  a314fs volume (`PI0:`) or to an ADF image, the data is already on the SD card.
  The partition is checked with fsck on every boot.
- The boot partition (`/boot/firmware`) is mounted read-only.
- Swap is in compressed RAM (zram) only.

What this does *not* protect against: a write that is still in progress when
the power goes, and data in files that an Amiga program still has open.

## Installation

Install Raspberry Pi OS and the A314 software as usual (see
[../README.md](../README.md)), then:

1. Shut down the Raspberry Pi and put the SD card in a Linux PC. Find the
   card's device name with `lsblk` (e.g. `/dev/sdb`) and run:

   ```sh
   sudo ./prepare-sd.sh /dev/sdX [root-size]
   ```

   This shrinks (or, on a freshly flashed card, grows) the root partition to
   `root-size` (default `8G`) and creates the `A314DATA` partition in the rest
   of the card. The script checks that the card looks like a Raspberry Pi OS
   card and asks for confirmation before changing anything, but back up
   anything important first.

   This step has to be done on another computer since the root partition
   can't be shrunk while the Raspberry Pi is running from it.

2. Put the card back in the Raspberry Pi, boot it and run:

   ```sh
   cd a314/Software/readonly
   sudo ./setup-readonly.sh
   ```

   This copies `/home` to the new partition, installs the mount unit, enables
   the overlay file system (installing `overlayroot` if needed, so a network
   connection is required) and asks to reboot.

3. After the reboot, check the result with `a314-maint status`:

   ```text
   Root file system:  read-only (RAM overlay)
   After reboot:      read-only
   /boot/firmware:    read-only
   /home:             /dev/mmcblk0p3 rw,noatime,sync,errors=remount-ro
   Swap:              /dev/zram0
   ```

## Maintenance

Package upgrades, network configuration (`nmtui`), A314 software updates and
other changes outside `/home` need a writable system:

```sh
sudo a314-maint rw     # and reboot
sudo apt update && sudo apt full-upgrade
sudo a314-maint ro     # and reboot
```

In maintenance mode, shut down properly (`sudo poweroff`) before switching off
the Amiga. The login message shows which mode is active.

Don't run `apt upgrade` in read-only mode: everything it writes is kept in RAM,
and the Raspberry Pi Zero 2 W only has 512 MB.

## Notes

- `/home` is mounted by the systemd unit `/etc/systemd/system/home.mount`, not
  by `/etc/fstab`. overlayroot turns ext4 entries in `/etc/fstab` into RAM
  overlays, so an fstab entry would silently lose all writes.
- The original `/home` is left on the root file system, hidden under the
  mount. If the `A314DATA` partition can't be mounted, the Raspberry Pi still
  boots, but `a314d` is not started.
- The system clock starts from the time of the last maintenance boot until it
  has been set over the network.
- Files: `prepare-sd.sh` (PC), `setup-readonly.sh` (Pi),
  `a314-maint` (installed to `/usr/local/sbin`), `a314-readonly.sh`
  (installed to `/etc/profile.d`).
