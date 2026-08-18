#!/bin/bash -e
#
# MooN read-only rootfs
#
# Rootfs is mounted `ro` permanently. Only /boot/firmware (where deploy
# scripts drop .moonpkg files) and /opt/moon (tmpfs, filled fresh by
# moon-pkg-load.service every boot) are ever writable at runtime.
# This is a plain mount-option + tmpfs-overlay setup, not dm-verity --
# it stops accidental/ordinary writes, it does not cryptographically
# verify block contents (that is what stage 05-image-integrity's signed
# manifest is for, over a curated file list).
#
# Consequence: anything that would normally write into /etc or /var on
# first boot must instead be pre-baked at IMAGE BUILD time, here:
#   - SSH host keys (normally (re)generated on first boot by ssh.service)
#   - /etc/machine-id (normally generated on first boot by systemd)
# Trade-off, same category as the already-documented Secure Boot
# omission: every SD card flashed from the SAME built image shares the
# same host keys and machine-id. Rebuilding the image (a fresh
# ./build.sh run) produces new ones. If per-node uniqueness is required
# later, that needs an explicit first-boot provisioning step -- out of
# scope here, flagged for later.

FSTAB="${ROOTFS_DIR}/etc/fstab"

# --- root filesystem: read-only ---------------------------------------
# This stage runs before export-image/04-set-partuuid substitutes the
# ROOTDEV placeholder with the real PARTUUID, so the root line still
# reads literally "ROOTDEV  /  ext4  defaults,noatime  0  1" here.
if ! grep -q '^ROOTDEV[[:space:]]\+/[[:space:]]\+ext4[[:space:]]\+defaults,noatime' "${FSTAB}"; then
	echo "moon: ${FSTAB} root entry not in the expected format, aborting rather than guessing" >&2
	exit 1
fi
sed -i 's|^\(ROOTDEV[[:space:]]\+/[[:space:]]\+ext4[[:space:]]\+\)defaults,noatime|\1ro,noatime|' "${FSTAB}"
grep -q '^ROOTDEV[[:space:]]\+/[[:space:]]\+ext4[[:space:]]\+ro,noatime' "${FSTAB}" \
	|| { echo "moon: failed to set root fstab entry to ro" >&2; exit 1; }

# Auto-resize-on-first-boot writes to the partition table and fs; not
# compatible with a permanently read-only root. Cluster images are
# built to fit the target SD/eMMC size instead.
on_chroot <<- EOF
	systemctl disable rpi-resize.service 2>/dev/null || true
	systemctl mask rpi-resize.service 2>/dev/null || true
EOF

# The "resize" keyword on the kernel cmdline independently triggers the
# same first-boot partition/filesystem growth via a udev/systemd
# generator, regardless of rpi-resize.service being masked -- strip it
# too so nothing tries to write to the partition table of a ro rootfs.
CMDLINE="${ROOTFS_DIR}/boot/firmware/cmdline.txt"
sed -i 's/[[:space:]]*\<resize\>//' "${CMDLINE}"

# --- writable runtime paths: tmpfs, non-persistent --------------------
install -m 644 files/tmp.mount     "${ROOTFS_DIR}/etc/systemd/system/tmp.mount"
install -m 644 files/var-log.mount "${ROOTFS_DIR}/etc/systemd/system/var-log.mount"
install -m 644 files/var-tmp.mount "${ROOTFS_DIR}/etc/systemd/system/var-tmp.mount"

install -d -m 755 "${ROOTFS_DIR}/etc/systemd/journald.conf.d"
install -m 644 files/journald-volatile.conf \
	"${ROOTFS_DIR}/etc/systemd/journald.conf.d/10-moon-volatile.conf"

install -m 755 files/moon-remount-rw.sh "${ROOTFS_DIR}/usr/local/sbin/moon-remount-rw.sh"
install -m 755 files/moon-remount-ro.sh "${ROOTFS_DIR}/usr/local/sbin/moon-remount-ro.sh"

on_chroot <<- EOF
	systemctl enable tmp.mount
	systemctl enable var-log.mount
	systemctl enable var-tmp.mount
EOF

# --- pre-bake what would otherwise need to write to /etc on first boot -
on_chroot <<- EOF
	rm -f /etc/ssh/ssh_host_*_key*
	ssh-keygen -A
	systemd-machine-id-setup
EOF
