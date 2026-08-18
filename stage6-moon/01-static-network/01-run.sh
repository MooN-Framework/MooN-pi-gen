#!/bin/bash -e
#
# MooN static network configuration
#
# Switches network management to systemd-networkd with a single static
# address on the ethernet interface. NetworkManager, dhcpcd and
# wpa_supplicant are disabled since there is no WLAN and no need for
# interactive/dynamic network setup on a fixed-topology cluster node.
#
# Config variables (set in the pi-gen `config` file):
#   MOON_ETH_IFACE     ethernet interface name (default: eth0)
#   MOON_ETH_ADDRESS   static address in CIDR form, e.g. 192.168.10.10/24
#                       (REQUIRED)
#   MOON_ETH_GATEWAY    default gateway, optional (transport is multicast
#                       on-link, so a gateway is usually not needed)
#   MOON_ETH_DNS        DNS server, optional

: "${MOON_ETH_IFACE:=eth0}"

if [ -z "${MOON_ETH_ADDRESS}" ]; then
	echo "moon: MOON_ETH_ADDRESS is not set in config, cannot configure static IP" >&2
	exit 1
fi

GATEWAY_LINE=""
if [ -n "${MOON_ETH_GATEWAY}" ]; then
	GATEWAY_LINE="Gateway=${MOON_ETH_GATEWAY}"
fi

DNS_LINE=""
if [ -n "${MOON_ETH_DNS}" ]; then
	DNS_LINE="DNS=${MOON_ETH_DNS}"
fi

sed \
	-e "s|__MOON_ETH_IFACE__|${MOON_ETH_IFACE}|" \
	-e "s|__MOON_ETH_ADDRESS__|${MOON_ETH_ADDRESS}|" \
	-e "s|__MOON_GATEWAY_LINE__|${GATEWAY_LINE}|" \
	-e "s|__MOON_DNS_LINE__|${DNS_LINE}|" \
	files/10-eth0-static.network.template \
	> "${ROOTFS_DIR}/etc/systemd/network/10-eth0-static.network"
# Drop now-empty template lines (no gateway/DNS configured).
sed -i '/^$/d' "${ROOTFS_DIR}/etc/systemd/network/10-eth0-static.network"

on_chroot <<- EOF
	# Disable dynamic/interactive network stacks
	systemctl disable NetworkManager.service 2>/dev/null || true
	systemctl mask NetworkManager.service 2>/dev/null || true
	systemctl disable wpa_supplicant.service 2>/dev/null || true
	systemctl mask wpa_supplicant.service 2>/dev/null || true
	systemctl disable dhcpcd.service 2>/dev/null || true
	systemctl mask dhcpcd.service 2>/dev/null || true

	# Enable static networking
	systemctl enable systemd-networkd.service
	systemctl enable systemd-resolved.service
	ln -sf /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
EOF
