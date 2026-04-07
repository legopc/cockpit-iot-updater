# Delta Bundle Support

> **Status: Scaffold only — not yet implemented.**
> The detection stub rejects delta bundles at apply time. See [Implementation Checklist](#implementation-checklist) below.

---

## Why Delta Bundles?

Full OCI image bundles for the Inferno appliance are typically **1–3 GB** per release.
Most of that data is unchanged between releases (base OS layers, static libraries, etc.).

A delta bundle ships only the *difference* between the running image and the new target,
reducing over-the-air transfer size to tens or hundreds of MB for minor updates — a
significant saving on constrained network links or metered connections.

---

## Bundle Format

A `.iotupdate` file is a plain tar archive. Delta bundles follow the same container format
as full bundles, distinguished by `bundle_type` in `version.json`.

### Files inside the tar

| File | Description |
|------|-------------|
| `version.json` | Bundle metadata (see fields below) |
| `delta.patch` | Binary diff in **bsdiff** format |

Full bundles carry `image.tar` instead of `delta.patch`. The apply script detects which
type it is via `bundle_type`.

### `version.json` fields

All existing fields from full bundles apply. Delta bundles add:

| Field | Type | Description |
|-------|------|-------------|
| `bundle_type` | `"full"` \| `"delta"` | Discriminator. Full bundles use `"full"`. All new bundles must include this field. |
| `base_version` | string | Version string of the image the patch applies to (must match the running appliance). |
| `base_sha256` | string | SHA256 of the base `image.tar`. Used to verify the appliance is on the expected base before patching. |
| `target_sha256` | string | SHA256 of the resulting `image.tar` after applying the patch. Used to verify patch success. |

Example `version.json` for a delta bundle:

```json
{
  "bundle_type": "delta",
  "version": "v11",
  "base_version": "v10",
  "base_sha256": "abc123...",
  "target_sha256": "def456...",
  "description": "Minor config update",
  "build_date": "2025-01-01T00:00:00Z",
  "oci_image_name": "localhost/inferno-appliance:v11"
}
```

---

## Apply Flow

```
Upload delta.iotupdate
        │
        ▼
Extract version.json
        │
        ▼
bundle_type == "delta"?
   │
   ├─ NO  → existing full-bundle path (skopeo + bootc switch)
   │
   └─ YES ─→ Verify running image sha256 == base_sha256
                    │
              sha256 mismatch? → FAIL (wrong base, user needs full bundle)
                    │
                    ▼
             Apply delta.patch via bspatch:
               bspatch <base-image.tar> <new-image.tar> delta.patch
                    │
                    ▼
             Verify new-image.tar sha256 == target_sha256
                    │
              sha256 mismatch? → FAIL (patch corrupt or truncated)
                    │
                    ▼
             Proceed as full OCI bundle:
               skopeo copy + bootc switch + reboot
```

---

## Tools

### On the build host

**`tools/make-delta-bundle.sh`** — generates a delta bundle from two podman images.

```bash
./tools/make-delta-bundle.sh \
  --base  inferno-appliance:v10 \
  --target inferno-appliance:v11 \
  --out   inferno-v10-to-v11.iotupdate \
  --changelog "Fix statime configuration"
```

Internally it will:
1. `podman save` both images to temporary tars
2. `bsdiff base.tar target.tar delta.patch`
3. Write `version.json` with all required fields
4. Package `version.json` + `delta.patch` into the `.iotupdate` tar

### On the appliance

**`bspatch`** must be present on the appliance (`bsdiff` package in the container image).
It is only needed at update-apply time, not at runtime.

---

## Current Status

The scaffold is in place but the feature is **not functional**:

- `tools/make-delta-bundle.sh` parses arguments and exits with an error message.
- `scripts/apply-update.sh` detects `bundle_type == "delta"` and rejects the bundle.
- `sidecar/server.py` exposes `bundle_type` in `/version-preview` so the UI can show it.
- `tools/make-oci-bundle.sh` now writes `bundle_type: "full"` explicitly.

---

## Implementation Checklist

Future work required to make delta bundles functional:

- [ ] **Appliance image**: add `bsdiff`/`bspatch` to the Containerfile
- [ ] **`tools/make-delta-bundle.sh`**: implement `podman save` + `bsdiff` + packaging
- [ ] **`scripts/apply-update.sh`**: implement the delta apply path (replace the stub rejection)
  - [ ] Locate or reconstruct the base image tar from container storage
  - [ ] Run `bspatch`
  - [ ] Verify `target_sha256`
  - [ ] Hand off to the existing skopeo/bootc path
- [ ] **`sidecar/server.py`**: surface `base_version` in `/version-preview` response (already included when `bundle_type == "delta"`)
- [ ] **`cockpit-page/update.js`**: display delta badge and base version in the UI
- [ ] **Integration test**: build a tiny synthetic delta bundle and test the full apply flow on a VM
- [ ] **Documentation**: update `docs/BUILDING-UPDATES.md` with delta bundle workflow
