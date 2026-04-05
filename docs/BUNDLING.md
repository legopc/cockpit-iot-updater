# Bundle Format Reference

This document describes the `.iotupdate` bundle format.
For a step-by-step guide on building and delivering update bundles, see
**[BUILDING-UPDATES.md](BUILDING-UPDATES.md)**.

---

## Format

A `.iotupdate` file is a standard uncompressed tar archive containing exactly two files:

```
bundle.iotupdate
├── version.json       ← parsed first by the UI and sidecar
└── image.tar          ← full OCI image archive (skopeo oci-archive format)
```

## version.json

```json
{
  "version":      "v9",
  "description":  "Add IoT Updater baked in; sha256 integrity; rollback UI",
  "built_at":     "2025-05-14T12:00:00Z",
  "image_name":   "inferno-appliance",
  "image_sha256": "abc123def456..."
}
```

| Field | Required | Description |
|-------|---------|-------------|
| `version` | ✅ | Version string shown in UI (e.g. `v9`) |
| `description` | ✅ | Human-readable change summary |
| `built_at` | ✅ | ISO 8601 timestamp of bundle creation |
| `image_name` | ✅ | Container image name (without tag) |
| `image_sha256` | ⚠️ optional | SHA-256 of `image.tar`; required for integrity check |

If `image_sha256` is absent, the sidecar skips hash verification and logs a warning.
Bundles created by `tools/make-oci-bundle.sh` always include the hash.

## image.tar

A full OCI image archive as produced by `podman save` or `skopeo copy --format=oci`.
Imported with:

```bash
skopeo copy oci-archive:/path/image.tar containers-storage:localhost/name:tag
```

The archive includes the full image manifest, config, and all layer blobs.
Typical size for the inferno-appliance image: ~1.8–2.2 GB.

## Creating bundles

Use `tools/make-oci-bundle.sh`:

```bash
tools/make-oci-bundle.sh \
    --image       inferno-appliance:v9 \
    --version     v9 \
    --description "Description of changes" \
    --out         inferno-appliance-v9.iotupdate
```

Or from a pre-exported image.tar:

```bash
tools/make-oci-bundle.sh \
    --archive     /path/to/image.tar \
    --version     v9 \
    --description "Description of changes" \
    --out         inferno-appliance-v9.iotupdate
```

## Verifying a bundle

```bash
# List contents
tar -tvf inferno-appliance-v9.iotupdate

# Read version.json
tar -xOf inferno-appliance-v9.iotupdate version.json | python3 -m json.tool

# Verify SHA-256 of image.tar
expected=$(tar -xOf inferno-appliance-v9.iotupdate version.json | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('image_sha256',''))")
actual=$(tar -xOf inferno-appliance-v9.iotupdate image.tar | sha256sum | cut -d' ' -f1)
[ "$expected" = "$actual" ] && echo "Hash OK" || echo "HASH MISMATCH"
```
