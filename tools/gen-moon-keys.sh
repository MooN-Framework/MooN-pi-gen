#!/bin/bash -e
#
# Generates the ed25519 keypair used to sign the rootfs integrity
# manifest (image build time) and later MooN packages (deployment time).
#
# Usage: tools/gen-moon-keys.sh [output-dir]
#
# Keep moon-signing-key.pem OFFLINE / out of version control. Only
# moon-signing-pub.pem is meant to end up on the build host / in the
# image.

OUT_DIR="${1:-./keys}"
mkdir -p "${OUT_DIR}"

if [ -f "${OUT_DIR}/moon-signing-key.pem" ]; then
	echo "refusing to overwrite existing ${OUT_DIR}/moon-signing-key.pem" >&2
	exit 1
fi

openssl genpkey -algorithm ed25519 -out "${OUT_DIR}/moon-signing-key.pem"
openssl pkey -in "${OUT_DIR}/moon-signing-key.pem" -pubout -out "${OUT_DIR}/moon-signing-pub.pem"
chmod 600 "${OUT_DIR}/moon-signing-key.pem"
chmod 644 "${OUT_DIR}/moon-signing-pub.pem"

echo "private key: ${OUT_DIR}/moon-signing-key.pem   (keep offline)"
echo "public key:  ${OUT_DIR}/moon-signing-pub.pem   (goes into the image / build config)"
