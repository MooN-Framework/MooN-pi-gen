#!/bin/bash -e
#
# Deauthorizes every USB root hub found on the system, which cascades to
# all downstream ports/devices. Runs once at boot, after usb core has
# enumerated the root hubs but before udev settles user-visible devices.
#
# This is done at the "authorized" attribute level rather than by
# blacklisting the host controller driver, because on the Raspberry Pi
# the same controller silicon is sometimes shared with other on-SoC
# functions depending on model/revision. Deauthorizing is reversible at
# runtime (echo 1 > authorized) without a reboot, which is useful for
# field debugging.

shopt -s nullglob

for hub in /sys/bus/usb/devices/usb*; do
	[ -f "${hub}/authorized" ] || continue
	echo 0 > "${hub}/authorized" || true
done

# Also flip the default so any USB device that gets hot-plugged later
# (or enumerated after a warm reset) stays deauthorized.
for default in /sys/bus/usb/devices/usb*/authorized_default; do
	echo 0 > "${default}" || true
done
