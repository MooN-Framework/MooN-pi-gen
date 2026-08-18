#!/bin/bash -e
#
# MooN package loader / verifier
#
# Package format (.moonpkg, a plain uncompressed tar container):
#   manifest.json   {"name":..., "version":..., "created":..., "payload_sha256":"<sha256>"}
#   manifest.sig    raw ed25519 signature of manifest.json
#   payload.tar.gz  the actual node binary + config, extracted to /opt/moon
#
# Verification order:
#   1. manifest.sig must verify against the embedded public key
#   2. sha256(payload.tar.gz) must match manifest.json's payload_sha256
#   Only if both hold is the payload extracted and the node service allowed
#   to start. Any failure leaves /run/moon/package-loaded absent, which
#   moon-node.service depends on, so the node process never starts on
#   unverified input.

PKG_PATH="${MOON_PKG_PATH:-/boot/firmware/moon-package.moonpkg}"
PUBKEY="/etc/moon/moon-signing-pub.pem"
RUNTIME_DIR="/opt/moon"
STATE_DIR="/run/moon"
FLAG_FILE="${STATE_DIR}/package-loaded"

log() { echo "moon-pkg-load: $*"; }

mkdir -p "${STATE_DIR}"
rm -f "${FLAG_FILE}"

if [ -f "${STATE_DIR}/integrity-failed" ]; then
	log "ABORT: OS image integrity check has failed, refusing to load any package"
	exit 1
fi

if [ ! -f "${PKG_PATH}" ]; then
	log "ABORT: no package found at ${PKG_PATH}"
	exit 1
fi

if [ ! -f "${PUBKEY}" ]; then
	log "ABORT: signing public key ${PUBKEY} missing from image"
	exit 1
fi

WORKDIR="$(mktemp -d /run/moon-pkg.XXXXXX)"
trap 'rm -rf "${WORKDIR}"' EXIT

tar -xf "${PKG_PATH}" -C "${WORKDIR}" manifest.json manifest.sig payload.tar.gz

if ! openssl pkeyutl -verify -pubin -inkey "${PUBKEY}" -rawin \
	-in "${WORKDIR}/manifest.json" -sigfile "${WORKDIR}/manifest.sig" >/dev/null 2>&1; then
	log "ABORT: manifest signature verification FAILED"
	exit 1
fi
log "manifest signature OK"

EXPECTED_SHA=$(jq -r '.payload_sha256' "${WORKDIR}/manifest.json")
if [ -z "${EXPECTED_SHA}" ] || [ "${EXPECTED_SHA}" = "null" ]; then
	log "ABORT: manifest.json has no payload_sha256 field"
	exit 1
fi
ACTUAL_SHA=$(sha256sum "${WORKDIR}/payload.tar.gz" | awk '{print $1}')
if [ "${EXPECTED_SHA}" != "${ACTUAL_SHA}" ]; then
	log "ABORT: payload hash mismatch (expected ${EXPECTED_SHA}, got ${ACTUAL_SHA})"
	exit 1
fi
log "payload hash OK"

rm -rf "${RUNTIME_DIR:?}"/*
tar -xzf "${WORKDIR}/payload.tar.gz" -C "${RUNTIME_DIR}"

PKG_NAME=$(jq -r '.name // "unknown"' "${WORKDIR}/manifest.json")
PKG_VERSION=$(jq -r '.version // "unknown"' "${WORKDIR}/manifest.json")
log "loaded package ${PKG_NAME} version ${PKG_VERSION} into ${RUNTIME_DIR}"

touch "${FLAG_FILE}"
