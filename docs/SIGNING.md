# Bundle Signing (Ed25519)

The IoT Updater supports optional Ed25519 bundle signing to ensure that only
bundles produced by trusted build hosts can be applied to appliances.

## Key generation

Run on the build host (e.g. PRX-01):

```bash
tools/gen-signing-key.sh
```

This produces:
- `iot-updater-signing.key` — private key (keep secret, never commit)
- `iot-updater-signing.pub` — public key (safe to distribute)

## Installing the public key on the appliance

```bash
sudo mkdir -p /etc/iot-updater
sudo cp iot-updater-signing.pub /etc/iot-updater/signing.pub
sudo chmod 644 /etc/iot-updater/signing.pub
```

The appliance checks for the public key at `/etc/iot-updater/signing.pub`
on every update. If the file is absent, signature checking is skipped.

## Signing a bundle

Pass `--sign-key` to `make-oci-bundle.sh`:

```bash
tools/make-oci-bundle.sh \
  --archive /path/to/image.tar \
  --version v10 \
  --description "My update" \
  --out bundle.iotupdate \
  --sign-key iot-updater-signing.key
```

The Ed25519 signature of `version.json` is base64-encoded and embedded in
`version.json` itself under the `"signature"` key. The `"signed_fields"`
key records which files were covered (`["version.json"]`).

## Enforcement

By default, signature failures produce a warning log entry but do **not**
block the update (soft enforcement). To enforce strict signing:

```ini
# /etc/systemd/system/iot-update.service.d/enforce-signing.conf
[Service]
Environment=IOT_UPDATER_ENFORCE_SIGNING=1
```

Then reload:

```bash
sudo systemctl daemon-reload
```

With enforcement on:
- Unsigned bundles are **rejected**
- Bundles with invalid signatures are **rejected**

## Cockpit UI

The version preview panel shows a **✅ Signed** or **⚠️ Unsigned** badge
next to the bundle version when a bundle is uploaded.
