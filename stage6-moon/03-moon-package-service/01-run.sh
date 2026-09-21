#!/bin/bash -e
#
# MooN package service
#
# Installs the package loader (moon-pkg-load.sh + .service), the tmpfs
# mount for the payload (/opt/moon) and the node service. The loader
# verifies /boot/firmware/moon-package.moonpkg at every boot and only
# then lets moon-node.service start. See docs/stage6-moon.md and
# docs/package-format.md.
#
# Requires MOON_SIGNING_PUBKEY (set in the pi-gen `config` file) to point
# to an ed25519 public key in PEM form on the build host (absolute, or
# relative to the repository root). Generate a keypair with
# tools/gen-moon-keys.sh. Only the public key is copied into the image.
# The private key is needed on the build host by 05-image-integrity and
# by tools/build-moon-package.sh, never in the image and never in version
# control.

if [ -z "${MOON_SIGNING_PUBKEY}" ]; then
	echo "moon: MOON_SIGNING_PUBKEY not set in config (see tools/gen-moon-keys.sh)" >&2
	exit 1
fi
# Resolve a relative path against BASE_DIR (the pi-gen repo root, always
# exported by build.sh) rather than the current directory -- pi-gen
# pushd's into this stage's own subdirectory before running this script,
# so a relative path from `config` would otherwise resolve to the wrong
# place.
case "${MOON_SIGNING_PUBKEY}" in
	/*) : ;;
	*) MOON_SIGNING_PUBKEY="${BASE_DIR}/${MOON_SIGNING_PUBKEY}" ;;
esac
if [ ! -f "${MOON_SIGNING_PUBKEY}" ]; then
	echo "moon: MOON_SIGNING_PUBKEY (${MOON_SIGNING_PUBKEY}) not found" >&2
	exit 1
fi

install -d -m 755 "${ROOTFS_DIR}/etc/moon"
install -m 644 "${MOON_SIGNING_PUBKEY}" "${ROOTFS_DIR}/etc/moon/moon-signing-pub.pem"

install -d -m 755 "${ROOTFS_DIR}/opt/moon"

install -m 755 files/moon-pkg-load.sh "${ROOTFS_DIR}/usr/local/sbin/moon-pkg-load.sh"
install -m 644 files/opt-moon.mount "${ROOTFS_DIR}/etc/systemd/system/opt-moon.mount"
install -m 644 files/moon-pkg-load.service "${ROOTFS_DIR}/etc/systemd/system/moon-pkg-load.service"
install -m 644 files/moon-node.service "${ROOTFS_DIR}/etc/systemd/system/moon-node.service"

on_chroot <<- EOF
	systemctl enable opt-moon.mount
	systemctl enable moon-pkg-load.service
	systemctl enable moon-node.service
EOF