# Bundle Creation Guide

Detailed reference for creating `.iotupdate` bundles for Fedora IoT 43 devices.

Run all commands in this guide on a **staging/developer machine** — not on the IoT device itself.

---

## Prerequisites

```bash
# Fedora/RHEL staging machine with internet access
sudo dnf install ostree

# Verify
ostree --version
```

---

## Concepts

An `.iotupdate` bundle is a tar archive containing:
1. `version.json` — metadata (version, commit hashes, description)
2. `update.delta` — an **OSTree static delta** from the device's current commit to the new commit

An OSTree static delta is a binary diff that contains exactly the data needed to bring one
commit up to another. It is much smaller than a full commit archive.

---

## Step 1 — Prepare your OSTree repository

You need an OSTree repository on your staging machine that contains both the
**current device commit** and the **target commit**.

### Option A — Mirror from upstream Fedora IoT

```bash
# Create a local mirror (first time)
mkdir -p /srv/fedora-iot-mirror
ostree --repo=/srv/fedora-iot-mirror init --mode=archive

# Pull the current stable ref
ostree --repo=/srv/fedora-iot-mirror pull \
    https://ostree.fedoraproject.org/iot \
    fedora/stable/aarch64/iot

# List commits pulled
ostree --repo=/srv/fedora-iot-mirror log fedora/stable/aarch64/iot | head -20
```

To pull a **specific older commit** (needed as the `--from` base):
```bash
# Find the commit hash from a device:
ssh user@device "rpm-ostree status --json" | \
    python3 -c "import json,sys; print(json.load(sys.stdin)['deployments'][0]['checksum'])"

# Pull that specific commit (if it's not in your mirror yet)
ostree --repo=/srv/fedora-iot-mirror pull \
    https://ostree.fedoraproject.org/iot \
    <commit-hash>
```

### Option B — Use your own composed image

If you're composing custom Fedora IoT images with `rpm-ostree compose`:
```bash
# After composing, your repo is typically at:
# /var/cache/compose/repo   or   /srv/my-iot-repo

# Verify the commit is present
ostree --repo=/srv/my-iot-repo log fedora/stable/aarch64/iot
```

---

## Step 2 — Find commit hashes

### Current commit on the device (from_commit)

Run on the device, or SSH in:
```bash
rpm-ostree status --json | python3 -c \
    "import json,sys; print(json.load(sys.stdin)['deployments'][0]['checksum'])"
```

Or shorter:
```bash
ostree --repo=/ostree/repo rev-parse fedora/stable/aarch64/iot
```

### Target commit (to_commit)

```bash
# Latest commit in your mirror
ostree --repo=/srv/fedora-iot-mirror rev-parse fedora/stable/aarch64/iot
```

### Verify both commits are in your staging repo

```bash
ostree --repo=/srv/fedora-iot-mirror show <from-commit> | head -5
ostree --repo=/srv/fedora-iot-mirror show <to-commit>   | head -5
```

Both must return output without errors before you can generate the delta.

---

## Step 3 — Generate the bundle

```bash
./tools/make-bundle.sh \
    --version     43.1.2 \
    --description "Kernel 6.12.15, systemd 257.3, security updates" \
    --repo        /srv/fedora-iot-mirror \
    --from        <from-commit-hash> \
    --to          <to-commit-hash> \
    --out         /tmp/iot43-43.1.2.iotupdate
```

**Expected output:**
```
═══════════════════════════════════════════════════
  Fedora IoT Update Bundle Generator
  Version:     43.1.2
  Description: Kernel 6.12.15, systemd 257.3, security updates
  From:        abc123def456…
  To:          789012abcdef…
  Output:      /tmp/iot43-43.1.2.iotupdate
═══════════════════════════════════════════════════

[1/3] Writing version.json…
[2/3] Generating OSTree static delta (this may take several minutes)…
      Delta size: 1.8G
[3/3] Packaging into /tmp/iot43-43.1.2.iotupdate…

✓ Bundle created successfully!
  File:    /tmp/iot43-43.1.2.iotupdate
  Size:    1.8G
  Version: 43.1.2
```

**Time estimate:** 5–20 minutes depending on how much changed between commits and disk I/O speed.

---

## Step 4 — Verify the bundle

```bash
# Check the version metadata
tar -xOf /tmp/iot43-43.1.2.iotupdate version.json | python3 -m json.tool

# Check the contents
tar -tvf /tmp/iot43-43.1.2.iotupdate
# Should show:
#   version.json  (a few KB)
#   update.delta  (the bulk, ~1-2 GB)

# Check total size
du -sh /tmp/iot43-43.1.2.iotupdate
```

---

## Step 5 — Deliver to the device

### Via Cockpit (recommended)

1. Open `https://<device-ip>:9090` and log in
2. Click **IoT Updater** in the sidebar
3. Drag and drop the `.iotupdate` file (or click to browse)
4. Review the version preview — confirm the `from_commit` matches the device's current commit
5. Click **Apply v43.1.2** and confirm the reboot dialog

### Via SCP + manual apply (fallback)

```bash
# Copy to device
scp /tmp/iot43-43.1.2.iotupdate user@device:/var/tmp/iot43-update.iotupdate

# Apply manually (as root on the device)
ssh user@device "sudo /var/lib/iot-updater/apply-update.sh"
```

---

## Troubleshooting bundle generation

### "from-commit not found in repo"
The base commit is not in your local mirror. Pull it explicitly:
```bash
ostree --repo=/srv/fedora-iot-mirror pull \
    https://ostree.fedoraproject.org/iot <from-commit>
```

### "ostree static-delta generate failed"
Usually means the two commits are not in the same repository or one is missing.
Verify with `ostree show` as described in Step 2.

### Bundle is unexpectedly small (< 100 MB)
The delta was generated but one of the commits may be wrong, resulting in a near-empty diff.
Re-check your commit hashes with `rpm-ostree status` on the device and `ostree log` on the
staging machine.

### `from_commit` mismatch on device upload
If the device's current commit does not match the bundle's `from_commit`, `ostree static-delta
apply-offline` will fail. You need to generate a new bundle with the correct `--from` hash.
The device's current commit can change if someone ran `rpm-ostree upgrade` or `rpm-ostree rollback`.

---

## Generating a "full" bundle (no base commit)

If you don't know the device's current commit (e.g. factory install, unknown state), you can
generate a full commit archive instead of a delta. This is larger but works regardless of the
device's current state:

```bash
# Export a full commit as an OSTree archive
ostree --repo=/srv/fedora-iot-mirror export \
    --output-dir=/tmp/full-commit-dir \
    <to-commit>

# Alternatively, create a static delta from the empty tree (generates a full bundle)
ostree --repo=/srv/fedora-iot-mirror static-delta generate \
    --min-fallback-size=0 \
    --filename=/tmp/full-update.delta \
    <to-commit>
```

Then package with `make-bundle.sh` but omit `--from` (set `from_commit` to empty string
in `version.json`). The apply script and page handle this gracefully — they apply the delta
without a from-commit check.

> Note: A full delta is typically 3–5× larger than an incremental one (the full OS tree,
> not just the diff).

---

## Version numbering quick reference

```
43 . 1 . 2
│    │   └─ PATCH: security/bugfix only — no new features
│    └───── MINOR: kernel update, feature addition, config change
└────────── MAJOR: Fedora release number (43 = Fedora 43 IoT)
```

Store the version in your own notes alongside the OSTree commit hash so you can
always reproduce or extend a bundle later.
