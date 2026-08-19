#!/bin/bash -e
#
# MooN headless hardening
#
# - disables WLAN and Bluetooth radios (device tree overlays)
# - disables HDMI output (headless, no display ever attached)
# - disables all USB ports at runtime (via a small systemd oneshot that
#   deauthorizes the root USB hubs; safer/more portable across Pi models
#   than blacklisting host controller kernel modules, which can also
#   break other on-SoC peripherals)
#
# Ethernet, SD/eMMC boot storage and the Pi's serial console are left
# untouched.

CONFIG_TXT="${ROOTFS_DIR}/boot/firmware/config.txt"

if [ ! -f "${CONFIG_TXT}" ]; then
	echo "moon: ${CONFIG_TXT} not found, skipping headless hardening" >&2
	exit 1
fi

cat >> "${CONFIG_TXT}" <<-EOF

	# --- MooN headless hardening ---------------------------------------
	# Disable on-board WLAN and Bluetooth radios entirely.
	dtoverlay=disable-wifi
	dtoverlay=disable-bt

	# Headless: no display is ever attached, so drop HDMI output/power.
	hdmi_blanking=2
	hdmi_ignore_hotplug=1
	disable_splash=1
	# ---------------------------------------------------------------------
EOF

install -m 644 files/moon-disable-usb.service \
	"${ROOTFS_DIR}/etc/systemd/system/moon-disable-usb.service"
install -m 755 files/moon-disable-usb.sh \
	"${ROOTFS_DIR}/usr/local/sbin/moon-disable-usb.sh"

on_chroot <<- EOF
	systemctl enable moon-disable-usb.service
EOF

# --- cloud-init: not used, and actively fails on a read-only rootfs ---
# cloud-init writes its state to /var/lib/cloud, which is part of the
# permanently read-only root set up in 04-readonly-rootfs -- every
# cloud-init stage fails at boot as a result (harmless, since we never
# rely on it, but noisy in `systemctl --failed`). Nothing here needs
# cloud provisioning: network is static (01-static-network), and
# software delivery goes through moon-pkg-load.service, not cloud-init
# user-data. Purge it outright rather than just masking it, so the
# three placeholder files stage2/04-cloud-init drops on
# /boot/firmware (meta-data, user-data, network-config) don't linger
# either.
on_chroot <<- EOF
	apt-get purge -y cloud-init rpi-cloud-init-mods 2>/dev/null || true
	apt-get autoremove -y 2>/dev/null || true
EOF
rm -f "${ROOTFS_DIR}/boot/firmware/meta-data" \
	"${ROOTFS_DIR}/boot/firmware/user-data" \
	"${ROOTFS_DIR}/boot/firmware/network-config"