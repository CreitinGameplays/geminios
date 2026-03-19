#!/bin/bash
set -e

CERT_BUNDLE_URL="https://curl.se/ca/cacert.pem"
CERT_BUNDLE="$DEP_DIR/cacert.pem"

mkdir -p "$DEP_DIR"
if [ ! -f "$CERT_BUNDLE" ]; then
    wget -q -O "$CERT_BUNDLE" "$CERT_BUNDLE_URL"
fi

install -d "$ROOTFS/etc/ssl/certs"
install -m 0644 "$CERT_BUNDLE" "$ROOTFS/etc/ssl/certs/ca-certificates.crt"
ln -sf certs/ca-certificates.crt "$ROOTFS/etc/ssl/cert.pem"
