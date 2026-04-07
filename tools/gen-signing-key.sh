#!/bin/bash
# Generate Ed25519 signing key pair for iot-updater bundle signing
openssl genpkey -algorithm Ed25519 -out iot-updater-signing.key
openssl pkey -in iot-updater-signing.key -pubout -out iot-updater-signing.pub
echo "Keys generated: iot-updater-signing.key (private), iot-updater-signing.pub (public)"
echo "Install public key: sudo cp iot-updater-signing.pub /etc/iot-updater/signing.pub"
echo "KEEP THE PRIVATE KEY SECRET — never commit it."
