#!/bin/bash -e
#
# MooN OS image integrity
#
# Generates a manifest of sha256 hashes over the security-critical files
# listed in files/manifest-paths.txt (as they exist in the FINISHED
# rootfs, i.e. after all previous stages/substages ran) and signs it with
# MOON_SIGNING_PRIVKEY. Only the signature and the public key end up in
# the image; the private key never leaves the build host and is not
# needed again unless the image is rebuilt.
#
# Config variables (set in the pi-gen `config` file):
#   MOON_SIGNING_PUBKEY   ed25519 public key, PEM (also used by the
#                         package loader, see 03-moon-package-service)
#   MOON_SIGNING_PRIVKEY  matching ed25519 private key, PEM. Only read
#                         here, on the build host, to produce the
#                         signature. See tools/gen-moon-keys.sh.

if [ -z "${MOON_SIGNING_PRIVKEY}" ]; then
	echo "moon: MOON_SIGNING_PRIVKEY not set in config (see tools/gen-moon-keys.sh)" >&2
	exit 1
fi
# Same relative-path caveat as 03-moon-package-service: resolve against
# BASE_DIR (pi-gen repo root), not the current directory, since pi-gen
# pushd's into this stage's own subdirectory before running this script.
case "${MOON_SIGNING_PRIVKEY}" in
	/*) : ;;
	*) MOON_SIGNING_PRIVKEY="${BASE_DIR}/${MOON_SIGNING_PRIVKEY}" ;;
esac
if [ ! -f "${MOON_SIGNING_PRIVKEY}" ]; then
	echo "moon: MOON_SIGNING_PRIVKEY (${MOON_SIGNING_PRIVKEY}) not found" >&2
	exit 1
fi

install -d -m 755 "${ROOTFS_DIR}/etc/moon"
install -m 644 files/manifest-paths.txt "${ROOTFS_DIR}/etc/moon/manifest-paths.txt"
install -m 755 files/moon-integrity-check.sh "${ROOTFS_DIR}/usr/local/sbin/moon-integrity-check.sh"
install -m 644 files/moon-integrity.service "${ROOTFS_DIR}/etc/systemd/system/moon-integrity.service"

# --- build the manifest on the host, against the finished rootfs -------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

{
	echo '{"generated":"'"$(date -u +%Y-%m-%dT%H:%M:%SZ)"'","files":['
	FIRST=1
	while IFS= read -r rel; do
		[ -z "${rel}" ] && continue
		case "${rel}" in \#*) continue ;; esac
		full="${ROOTFS_DIR}/${rel}"
		if [ ! -f "${full}" ]; then
			echo "moon: WARNING manifest path ${rel} not found in rootfs, skipping" >&2
			continue
		fi
		sha=$(sha256sum "${full}" | awk '{print $1}')
		[ "${FIRST}" -eq 1 ] && FIRST=0 || echo ','
		printf '{"path":"%s","sha256":"%s"}' "${rel}" "${sha}"
	done < "${ROOTFS_DIR}/etc/moon/manifest-paths.txt"
	echo ']}'
} > "${WORKDIR}/rootfs-manifest.json"

if command -v python3 >/dev/null 2>&1; then
	python3 -c "import json,sys; json.load(open('${WORKDIR}/rootfs-manifest.json'))" \
		|| { echo "moon: generated rootfs-manifest.json is not valid JSON" >&2; exit 1; }
fi

openssl pkeyutl -sign -inkey "${MOON_SIGNING_PRIVKEY}" -rawin \
	-in "${WORKDIR}/rootfs-manifest.json" -out "${WORKDIR}/rootfs-manifest.sig"

install -m 644 "${WORKDIR}/rootfs-manifest.json" "${ROOTFS_DIR}/etc/moon/rootfs-manifest.json"
install -m 644 "${WORKDIR}/rootfs-manifest.sig" "${ROOTFS_DIR}/etc/moon/rootfs-manifest.sig"

on_chroot <<- EOF
	systemctl enable moon-integrity.service
EOF