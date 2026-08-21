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
#       [--node-unit <local moon-node.service>]
#       [--reboot]
#
# Examples:
#   # Swap only the package, restarts the node service live, no reboot
#   tools/moon-deploy.sh -H 192.168.10.10 --pkg build/moon-node-v3.moonpkg
#
#   # Re-IP a node and reboot into the new config
#   tools/moon-deploy.sh -H 192.168.10.10 --ip 192.168.10.42/24 --reboot
#
#   # Push an updated moon-node.service (e.g. Restart= change) to an
#   # already-flashed node, no reflash needed -- also re-signs the
#   # rootfs integrity manifest so the node survives its next reboot
#   tools/moon-deploy.sh -H 192.168.10.10 \
#       --node-unit stage6-moon/03-moon-package-service/files/moon-node.service \
#       --signing-key keys/moon-signing-key.pem
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
#
# --node-unit touches a file that IS in manifest-paths.txt
# (etc/systemd/system/moon-node.service). Passed together with
# --signing-key <moon-signing-key.pem> (the private key from
# tools/gen-moon-keys.sh, same one used at image-build time and by
# build-moon-package.sh), it pulls the node's current
# /etc/moon/rootfs-manifest.json, updates just that one path's
# sha256 entry, re-signs the manifest with that key, and installs
# unit + manifest + signature together -- so the node also passes
# moon-integrity.service on its next reboot, not just live.
#
# Without --signing-key, --node-unit still patches the live unit (for
# a quick test on a running node), but warns loudly and leaves the
# old manifest/signature in place, meaning the NEXT boot will fail
# the integrity check.
#
# --signing-key never leaves your machine -- it is used locally to
# produce rootfs-manifest.sig, only the resulting manifest+signature
# are uploaded. Same handling as -k in tools/build-moon-package.sh.

usage() {
	cat >&2 <<-EOF
	Usage: $0 -H host [-u user] [-i ssh-key] [--pkg file.moonpkg]
	          [--ip CIDR] [--gateway GW] [--dns DNS] [--iface IFACE]
	          [--node-unit file.service] [--signing-key key.pem]
	          [--reboot] [--dry-run]
	EOF
	exit 1
}

HOST="" SSH_USER="moon" SSH_KEY="" PKG="" NEW_IP="" GATEWAY="" DNS="" IFACE="eth0" NODE_UNIT="" SIGNING_KEY="" DO_REBOOT=0 DRY_RUN=0

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
		--node-unit) NODE_UNIT="$2"; shift 2 ;;
		--signing-key) SIGNING_KEY="$2"; shift 2 ;;
		--reboot) DO_REBOOT=1; shift ;;
		--dry-run) DRY_RUN=1; shift ;;
		-h|--help) usage ;;
		*) echo "unknown argument: $1" >&2; usage ;;
	esac
done

[ -n "${HOST}" ] || usage
[ -n "${PKG}" ] || [ -n "${NEW_IP}" ] || [ -n "${NODE_UNIT}" ] || { echo "nothing to do: pass --pkg, --ip, and/or --node-unit" >&2; exit 1; }
if [ -n "${PKG}" ] && [ ! -f "${PKG}" ]; then
	echo "package file not found: ${PKG}" >&2
	exit 1
fi
if [ -n "${NODE_UNIT}" ] && [ ! -f "${NODE_UNIT}" ]; then
	echo "unit file not found: ${NODE_UNIT}" >&2
	exit 1
fi
if [ -n "${SIGNING_KEY}" ] && [ -z "${NODE_UNIT}" ]; then
	echo "--signing-key only applies together with --node-unit" >&2
	exit 1
fi
if [ -n "${SIGNING_KEY}" ] && [ ! -f "${SIGNING_KEY}" ]; then
	echo "signing key not found: ${SIGNING_KEY}" >&2
	exit 1
fi
if [ -n "${NODE_UNIT}" ] && [ -z "${SIGNING_KEY}" ]; then
	echo "moon-deploy: WARNING no --signing-key given -- patching the unit live only," >&2
	echo "moon-deploy:           the node will fail moon-integrity.service on its next reboot" >&2
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
scp_from() {
	if [ "${DRY_RUN}" -eq 1 ]; then
		echo "[dry-run] scp ${SSH_TARGET}:$1 $2"
	else
		scp "${SSH_OPTS[@]}" "${SSH_TARGET}:$1" "$2"
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

# --- moon-node.service (live patch, see header comment on --node-unit) --
if [ -n "${NODE_UNIT}" ]; then
	MANIFEST_REL="etc/systemd/system/moon-node.service"
	NEW_SHA=$(sha256sum "${NODE_UNIT}" | awk '{print $1}')

	MANIFEST_UPDATED=0
	if [ -n "${SIGNING_KEY}" ]; then
		MANIFEST_UPDATED=1
		WORKDIR="$(mktemp -d)"
		trap 'rm -rf "${WORKDIR}"' EXIT

		log "fetching current rootfs-manifest.json from ${HOST}"
		scp_from "/etc/moon/rootfs-manifest.json" "${WORKDIR}/rootfs-manifest.json"

		if [ "${DRY_RUN}" -eq 1 ]; then
			echo "[dry-run] update \"${MANIFEST_REL}\" entry to sha256 ${NEW_SHA}, re-sign with ${SIGNING_KEY}"
		else
			python3 - "${WORKDIR}/rootfs-manifest.json" "${MANIFEST_REL}" "${NEW_SHA}" <<-'PYEOF'
import json, sys, datetime
path, rel, sha = sys.argv[1], sys.argv[2], sys.argv[3]
with open(path) as f:
    manifest = json.load(f)
for entry in manifest.get("files", []):
    if entry.get("path") == rel:
        entry["sha256"] = sha
        break
else:
    manifest.setdefault("files", []).append({"path": rel, "sha256": sha})
manifest["generated"] = datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
with open(path, "w") as f:
    json.dump(manifest, f)
			PYEOF

			log "re-signing manifest with ${SIGNING_KEY}"
			openssl pkeyutl -sign -inkey "${SIGNING_KEY}" -rawin \
				-in "${WORKDIR}/rootfs-manifest.json" -out "${WORKDIR}/rootfs-manifest.sig"
		fi
	fi

	log "uploading $(basename "${NODE_UNIT}") to ${HOST}:/etc/systemd/system/moon-node.service"
	scp_to "${NODE_UNIT}" "/tmp/moon-node.service.new"
	INSTALL_CMD="sudo /usr/local/sbin/moon-remount-rw.sh && \
		sudo install -m 644 /tmp/moon-node.service.new /etc/systemd/system/moon-node.service && \
		rm -f /tmp/moon-node.service.new"

	if [ "${MANIFEST_UPDATED}" -eq 1 ]; then
		log "uploading re-signed rootfs-manifest.json / .sig"
		scp_to "${WORKDIR}/rootfs-manifest.json" "/tmp/rootfs-manifest.json.new"
		scp_to "${WORKDIR}/rootfs-manifest.sig" "/tmp/rootfs-manifest.sig.new"
		INSTALL_CMD="${INSTALL_CMD} && \
			sudo install -m 644 /tmp/rootfs-manifest.json.new /etc/moon/rootfs-manifest.json && \
			sudo install -m 644 /tmp/rootfs-manifest.sig.new /etc/moon/rootfs-manifest.sig && \
			rm -f /tmp/rootfs-manifest.json.new /tmp/rootfs-manifest.sig.new"
	fi

	ssh_run "${INSTALL_CMD} && sudo /usr/local/sbin/moon-remount-ro.sh && sudo systemctl daemon-reload"

	if [ "${MANIFEST_UPDATED}" -eq 1 ]; then
		log "unit + re-signed manifest installed -- this node will also pass" \
			"moon-integrity.service on its next reboot"
	else
		log "unit installed and reloaded -- no --signing-key given, so the manifest" \
			"was NOT updated; this node will fail moon-integrity.service on its" \
			"next boot until reflashed or updated with --signing-key"
	fi

	if [ "${DO_REBOOT}" -eq 0 ]; then
		log "restarting moon-node.service live"
		ssh_run "sudo systemctl restart moon-node.service"
		ssh_run "systemctl is-active --quiet moon-node.service" \
			&& log "moon-node.service is active" \
			|| log "WARNING: moon-node.service did not come up, check 'journalctl -u moon-node' on the host"
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
