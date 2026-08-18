#!/bin/bash -e
#
# MooN SSH access
#
# ENABLE_SSH and FIRST_USER_PASS (set in the pi-gen `config` file, e.g.
# ENABLE_SSH=1 / FIRST_USER_PASS=123) are already handled by the stock
# pi-gen stage0/stage2 scripts. This stage only makes sure password
# authentication is explicitly enabled (in case it was disabled upstream)
# and drops a login banner, since a hardcoded default password is a
# known, accepted risk for this internal test topology and should stay
# visible to anyone logging in.

SSHD_CONFIG="${ROOTFS_DIR}/etc/ssh/sshd_config"

sed -i -Ee \
	's/^#?[[:blank:]]*PasswordAuthentication[[:blank:]]*(yes|no)[[:blank:]]*$/PasswordAuthentication yes/' \
	"${SSHD_CONFIG}"
if ! grep -q '^PasswordAuthentication yes' "${SSHD_CONFIG}"; then
	echo "PasswordAuthentication yes" >> "${SSHD_CONFIG}"
fi
sed -i -Ee \
	's/^#?[[:blank:]]*PermitRootLogin[[:blank:]]*.*$/PermitRootLogin no/' \
	"${SSHD_CONFIG}"

install -m 644 files/moon-motd "${ROOTFS_DIR}/etc/motd"
