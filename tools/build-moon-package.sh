#!/bin/bash -e
#
# Builds a signed .moonpkg package for the MooN package loader.
#
# Usage:
#   tools/build-moon-package.sh -k <signing-key.pem> -n <name> -v <version> \
#       -p <payload-dir> -o <output.moonpkg>
#
# <payload-dir> becomes payload.tar.gz, extracted verbatim to /opt/moon
# by the on-target loader (e.g. it should contain bin/node and
# config/node.toml).

usage() { echo "Usage: $0 -k key.pem -n name -v version -p payload-dir -o out.moonpkg" >&2; exit 1; }

KEY="" NAME="" VERSION="" PAYLOAD_DIR="" OUT=""
while getopts "k:n:v:p:o:" opt; do
	case "${opt}" in
		k) KEY="${OPTARG}" ;;
		n) NAME="${OPTARG}" ;;
		v) VERSION="${OPTARG}" ;;
		p) PAYLOAD_DIR="${OPTARG}" ;;
		o) OUT="${OPTARG}" ;;
		*) usage ;;
	esac
done

[ -n "${KEY}" ] && [ -n "${NAME}" ] && [ -n "${VERSION}" ] && [ -n "${PAYLOAD_DIR}" ] && [ -n "${OUT}" ] || usage
[ -f "${KEY}" ] || { echo "signing key ${KEY} not found" >&2; exit 1; }
[ -d "${PAYLOAD_DIR}" ] || { echo "payload dir ${PAYLOAD_DIR} not found" >&2; exit 1; }

WORKDIR="$(mktemp -d)"
trap 'rm -rf "${WORKDIR}"' EXIT

tar -czf "${WORKDIR}/payload.tar.gz" -C "${PAYLOAD_DIR}" .
PAYLOAD_SHA=$(sha256sum "${WORKDIR}/payload.tar.gz" | awk '{print $1}')
CREATED=$(date -u +%Y-%m-%dT%H:%M:%SZ)

cat > "${WORKDIR}/manifest.json" <<-EOF
{"name":"${NAME}","version":"${VERSION}","created":"${CREATED}","payload_sha256":"${PAYLOAD_SHA}"}
EOF

openssl pkeyutl -sign -inkey "${KEY}" -rawin \
	-in "${WORKDIR}/manifest.json" -out "${WORKDIR}/manifest.sig"

tar -cf "${OUT}" -C "${WORKDIR}" manifest.json manifest.sig payload.tar.gz

echo "wrote ${OUT} (${NAME} v${VERSION}, payload sha256 ${PAYLOAD_SHA})"
