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
