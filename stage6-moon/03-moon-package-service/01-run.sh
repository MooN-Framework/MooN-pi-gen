#!/bin/bash -e
#
# MooN package service
#
# Requires MOON_SIGNING_PUBKEY (set in the pi-gen `config` file) to point
# to an ed25519 public key in PEM form on the build host. Generate a
# keypair with tools/gen-moon-keys.sh; keep the private key OFF the build
# host / out of version control, it is only needed by tools/build-moon-package.sh
# when signing packages for deployment.

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