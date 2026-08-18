#!/bin/bash -e
#
# Reconfigures an already-flashed, already-booted MooN Pi over SSH:
# swap its .moonpkg package and/or its static IP (and a few related
# network settings). Does NOT touch anything covered by the signed
# rootfs integrity manifest -- only /boot/firmware (always writable)
# and the one network file that stage6-moon/05-image-integrity
# deliberately excludes from that manifest (see manifest-paths.txt).
#
# Usage:
#   tools/moon-deploy.sh -H <host> [-u user] [-i ssh-key]
#       [--pkg <local .moonpkg>]
#       [--ip <CIDR>] [--gateway <gw>] [--dns <dns>] [--iface eth0]
#       [--reboot]
#
# Examples:
#   # Swap only the package, restarts the node service live, no reboot
#   tools/moon-deploy.sh -H 192.168.10.10 --pkg build/moon-node-v3.moonpkg
#
#   # Re-IP a node and reboot into the new config
#   tools/moon-deploy.sh -H 192.168.10.10 --ip 192.168.10.42/24 --reboot
#
#   # Both at once
#   tools/moon-deploy.sh -H 192.168.10.10 \
#       --pkg build/moon-node-v3.moonpkg --ip 192.168.10.42/24 --reboot
#
# Changing the IP without --reboot only writes the new config -- it is
# NOT applied live, on purpose: restarting systemd-networkd on the same
# session you're connected through can hang the SSH connection if the
# new address isn't reachable the same way. Use --reboot, or apply it
# yourself over a console/serial connection.

usage() {
	cat >&2 <<-EOF
	Usage: $0 -H host [-u user] [-i ssh-key] [--pkg file.moonpkg]
	          [--ip CIDR] [--gateway GW] [--dns DNS] [--iface IFACE]
	          [--reboot] [--dry-run]
	EOF
	exit 1
}

HOST="" SSH_USER="moon" SSH_KEY="" PKG="" NEW_IP="" GATEWAY="" DNS="" IFACE="eth0" DO_REBOOT=0 DRY_RUN=0

while [ $# -gt 0 ]; do
	case "$1" in
		-H) HOST="$2"; shift 2 ;;
		-u) SSH_USER="$2"; shift 2 ;;
		-i) SSH_KEY="$2"; shift 2 ;;
		--pkg) PKG="$2"; shift 2 ;;
		--ip) NEW_IP="$2"; shift 2 ;;
		--gateway) GATEWAY="$2"; shift 2 ;;
		--dns) DNS="$2"; shift 2 ;;
		--iface) IFACE="$2"; shift 2 ;;
		--reboot) DO_REBOOT=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage ;;
		*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "${HOST}" ] || usage
[ -n "${PKG}" ] || [ -n "${NEW_IP}" ] || { echo "nothing to do: pass --pkg and/or --ip" >&2; exit 1; }
if [ -n "${PKG}" ] && [ ! -f "${PKG}" ]; then
	echo "package file not found: ${PKG}" >&2
	exit 1
fi

SSH_OPTS=(-o BatchMode=no)
[ -n "${SSH_KEY}" ] && SSH_OPTS+=(-i "${SSH_KEY}")
SSH_TARGET="${SSH_USER}@${HOST}"

ssh_run() {
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "[dry-run] ssh ${SSH_TARGET} -- $*"
	else
		ssh "${SSH_OPTS[@]}" "${SSH_TARGET}" "$@"
	fi
}
scp_to() {
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "[dry-run] scp $1 ${SSH_TARGET}:$2"
	else
		scp "${SSH_OPTS[@]}" "$1" "${SSH_TARGET}:$2"
	fi
}

log() { echo "moon-deploy: $*"; }

# --- package -----------------------------------------------------------
if [ -n "${PKG}" ]; then
	log "uploading $(basename "${PKG}") to ${HOST}:/boot/firmware/moon-package.moonpkg"
	scp_to "${PKG}" "/tmp/moon-package.moonpkg.new"
	ssh_run "sudo mv /tmp/moon-package.moonpkg.new /boot/firmware/moon-package.moonpkg && sudo chmod 644 /boot/firmware/moon-package.moonpkg"

	if [ "${DO_REBOOT}" -eq 0 ]; then
		log "reloading package live (moon-pkg-load.service + moon-node.service)"
		ssh_run "sudo systemctl restart moon-pkg-load.service && sudo systemctl restart moon-node.service"
		ssh_run "systemctl is-active --quiet moon-node.service" \
			&& log "moon-node.service is active" \
			|| log "WARNING: moon-node.service did not come up, check 'journalctl -u moon-pkg-load -u moon-node' on the host"
	fi
fi

# --- static IP -----------------------------------------------------------
if [ -n "${NEW_IP}" ]; then
	log "preparing new network config for ${IFACE}: ${NEW_IP}"

	GATEWAY_LINE=""
	[ -n "${GATEWAY}" ] && GATEWAY_LINE="Gateway=${GATEWAY}"
	DNS_LINE=""
	[ -n "${DNS}" ] && DNS_LINE="DNS=${DNS}"

	# Must stay in sync with stage6-moon/01-static-network's template.
	TMPFILE="$(mktemp)"
	trap 'rm -f "${TMPFILE}"' EXIT
	{
		echo "[Match]"
		echo "Name=${IFACE}"
		echo
		echo "[Network]"
		echo "Address=${NEW_IP}"
		[ -n "${GATEWAY_LINE}" ] && echo "${GATEWAY_LINE}"
		[ -n "${DNS_LINE}" ] && echo "${DNS_LINE}"
		echo "IPv6AcceptRA=no"
		echo "LinkLocalAddressing=no"
	} > "${TMPFILE}"

	log "uploading new network config"
	scp_to "${TMPFILE}" "/tmp/10-eth0-static.network.new"

	log "remounting rootfs rw, installing config, remounting ro"
	ssh_run "sudo /usr/local/sbin/moon-remount-rw.sh && \
		sudo install -m 644 /tmp/10-eth0-static.network.new /etc/systemd/network/10-eth0-static.network && \
		rm -f /tmp/10-eth0-static.network.new && \
		sudo /usr/local/sbin/moon-remount-ro.sh"

	if [ "${DO_REBOOT}" -eq 0 ]; then
		log "NOT applying the new IP live -- reconnect and rerun with --reboot," \
			"or apply it yourself (systemctl restart systemd-networkd) over a" \
			"connection that survives the address change"
	fi
fi

# --- reboot --------------------------------------------------------------
if [ "${DO_REBOOT}" -eq 1 ]; then
	log "rebooting ${HOST}"
	ssh_run "sudo reboot" || true
	log "done -- reconnect at the new address once it's back up (may take a minute)"
else
	log "done"
fi
