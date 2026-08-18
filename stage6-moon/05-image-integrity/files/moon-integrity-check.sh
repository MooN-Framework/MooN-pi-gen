#!/bin/bash -e
#
# MooN OS image integrity check (boot-time hash check)
#
# Not dm-verity: this checks a curated set of security-critical files
# (see /etc/moon/manifest-paths.txt) against a signed manifest generated
# at image-build time, rather than hashing the entire rootfs block
# device. That keeps boot time low, at the cost of not covering files
# outside the manifest list. Extend the list at build time if more
# coverage is needed.

MANIFEST="/etc/moon/rootfs-manifest.json"
SIGNATURE="/etc/moon/rootfs-manifest.sig"
PUBKEY="/etc/moon/moon-signing-pub.pem"
STATE_DIR="/run/moon"
FAIL_FLAG="${STATE_DIR}/integrity-failed"

log() { echo "moon-integrity: $*"; }
fail() {
	log "FAIL: $*"
	touch "${FAIL_FLAG}"
	exit 1
}

mkdir -p "${STATE_DIR}"
rm -f "${FAIL_FLAG}"

for f in "${MANIFEST}" "${SIGNATURE}" "${PUBKEY}"; do
	[ -f "${f}" ] || fail "required file ${f} missing"
done

if ! openssl pkeyutl -verify -pubin -inkey "${PUBKEY}" -rawin \
	-in "${MANIFEST}" -sigfile "${SIGNATURE}" >/dev/null 2>&1; then
	fail "rootfs manifest signature verification failed"
fi
log "manifest signature OK"

MISMATCH=0
while IFS= read -r entry; do
	path=$(jq -r '.path' <<< "${entry}")
	expected=$(jq -r '.sha256' <<< "${entry}")
	full="/${path}"
	if [ ! -f "${full}" ]; then
		log "MISSING: ${full}"
		MISMATCH=1
		continue
	fi
	actual=$(sha256sum "${full}" | awk '{print $1}')
	if [ "${actual}" != "${expected}" ]; then
		log "MISMATCH: ${full} (expected ${expected}, got ${actual})"
		MISMATCH=1
	fi
done < <(jq -c '.files[]' "${MANIFEST}")

if [ "${MISMATCH}" -ne 0 ]; then
	fail "one or more critical files do not match the signed manifest"
fi

log "all $(jq '.files | length' "${MANIFEST}") tracked files OK"
