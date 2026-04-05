# v9 Deployment Guide

This document describes the complete process for building and deploying
`inferno-appliance:v9` — the first release with the IoT Updater baked into
the OCI image.

**What changes in v9:**
- The Cockpit IoT Updater is no longer installed manually after first boot.
  It is part of the OCI image itself (`/usr/share/cockpit/iot-updater/` etc.)
- SHA-256 integrity verification for update bundles
- `bootc status` panel in the UI (booted / staged / rollback deployments)
- Rollback button (appears when a rollback slot exists)

**Two artifacts to produce:**

| Artifact | Purpose |
|----------|---------|
| `inferno-appliance-v9.iotupdate` | Upgrade existing v8 node at `192.168.1.43` — after reboot, v8 becomes the rollback slot |
| `inferno-appliance-v9.iso` | Fresh installer ISO for new hardware |

---

## Prerequisites

- PRX-01 SSH access: `root@10.10.1.201` (password: `Schnitzel-king1`)
- Build LV at `/mnt/inferno-build/` on PRX-01 (25 GB, mounted)
- Podman available on PRX-01
- `~/.ssh/id_ed25519` or `~/.ssh/inferno_proxmox` for node SSH

---

## Step 1 — Sync IoT Updater files into appliance source

Run from the jumphost (`/home/legopc/cockpit-iot-updater/`):

```bash
# Sync cockpit-iot-updater files into the appliance source tree
tools/sync-to-appliance.sh

# Review what was created
ls /home/legopc/copilot_projects/Inferno_Appliance/inferno-aoip-releases/iot-updater/
```

---

## Step 2 — Update Containerfile on PRX-01

The appliance `Containerfile` needs these lines added (at the end, before `CMD`):

```dockerfile
# IoT Updater — baked in for v9+
COPY iot-updater/cockpit/    /usr/share/cockpit/iot-updater/
COPY iot-updater/server.py   /var/lib/iot-updater/server.py
COPY iot-updater/apply-update.sh /var/lib/iot-updater/apply-update.sh
COPY iot-updater/iot-updater.service /etc/systemd/system/iot-updater.service
COPY iot-updater/iot-update.service  /etc/systemd/system/iot-update.service
RUN chmod +x /var/lib/iot-updater/apply-update.sh && \
    systemctl enable iot-updater
```

Also create `/var/lib/iot-updater/` in the Containerfile if it doesn't exist:

```dockerfile
RUN mkdir -p /var/lib/iot-updater
```

---

## Step 3 — Sync appliance source to PRX-01

```bash
rsync -av \
    /home/legopc/copilot_projects/Inferno_Appliance/inferno-aoip-releases/ \
    root@10.10.1.201:/mnt/inferno-build/inferno-aoip-releases/
```

---

## Step 4 — Build inferno-appliance:v9 on PRX-01

```bash
ssh root@10.10.1.201 "
    cd /mnt/inferno-build/inferno-aoip-releases && \
    podman --root /mnt/inferno-build/storage build \
        -t inferno-appliance:v9 \
        --label version=v9 \
        .
"
```

Expected build time: ~10 minutes (mostly package downloads on first build;
faster on subsequent builds due to podman layer cache).

Verify the image is present:
```bash
ssh root@10.10.1.201 "podman --root /mnt/inferno-build/storage images inferno-appliance"
```

---

## Step 5a — Create the upgrade bundle (.iotupdate)

```bash
# Copy make-oci-bundle.sh to PRX-01
scp tools/make-oci-bundle.sh root@10.10.1.201:/mnt/inferno-build/

ssh root@10.10.1.201 "
    cd /mnt/inferno-build && \
    PODMAN='podman --root /mnt/inferno-build/storage' \
    bash make-oci-bundle.sh \
        --image       inferno-appliance:v9 \
        --version     v9 \
        --description 'Bake in IoT Updater; sha256 integrity; bootc status UI; rollback' \
        --out         /mnt/inferno-build/inferno-appliance-v9.iotupdate
"
```

Transfer the bundle to the jumphost:
```bash
scp root@10.10.1.201:/mnt/inferno-build/inferno-appliance-v9.iotupdate /tmp/
```

Verify the bundle:
```bash
tar -tvf /tmp/inferno-appliance-v9.iotupdate
tar -xOf /tmp/inferno-appliance-v9.iotupdate version.json | python3 -m json.tool
```

---

## Step 5b — Build the installer ISO

> **Note:** ISO build uses `bootc-image-builder` (BIB), which runs as a privileged container.
> PRX-01 root FS is ~99% full — all output must go to `/mnt/inferno-build/`.

```bash
ssh root@10.10.1.201 "
    rm -rf /mnt/inferno-build/output/bootiso && \
    mkdir -p /mnt/inferno-build/output && \
    podman run --rm --privileged \
        -v /mnt/inferno-build/storage:/var/lib/containers/storage \
        -v /mnt/inferno-build/output:/output \
        -v /mnt/inferno-build/config.toml:/config.toml:ro \
        ghcr.io/osbuild/bootc-image-builder:latest \
        --type anaconda-iso \
        --rootfs xfs \
        --config /config.toml \
        localhost/inferno-appliance:v9 && \
    ln -sf /mnt/inferno-build/output/bootiso/install.iso \
        /var/lib/vz/template/iso/inferno-appliance-v9.iso
"
```

Expected build time: ~20 minutes. The ISO will appear in Proxmox as
`inferno-appliance-v9.iso` in the ISO library.

---

## Step 6 — Apply upgrade to the running node (192.168.1.43)

1. Open Cockpit: `https://192.168.1.43:9090`
2. Log in as `core` (password: `inferno123`)
3. Click **IoT Updater** in the sidebar
4. Drag `inferno-appliance-v9.iotupdate` onto the upload area
5. Review the version preview (version: v9, sha256 shown)
6. Click **Apply v9** and confirm
7. Wait for skopeo copy (~1–3 min at 50%)
8. Device reboots automatically

After reboot:
- Node runs `inferno-appliance:v9`
- IoT Updater is now baked in (no longer user-local)
- The rollback slot contains `inferno-appliance:v8` — the rollback button will appear in the UI

---

## Step 7 — Verify post-upgrade

```bash
# Check bootc status
ssh core@192.168.1.43 "bootc status"

# Check IoT Updater is running (should now be a system service, not user-level)
ssh core@192.168.1.43 "systemctl status iot-updater.service"

# Check sidecar
ssh core@192.168.1.43 "curl -s http://127.0.0.1:8088/status"
ssh core@192.168.1.43 "curl -s http://127.0.0.1:8088/bootc-status | python3 -m json.tool"

# Verify Cockpit page loads
# https://192.168.1.43:9090 → IoT Updater → should show booted=v9, rollback=v8
```

---

## Rollback test (optional)

From the Cockpit UI:
1. Open IoT Updater → bootc status panel shows rollback = v8
2. Click **Rollback to v8**
3. Confirm — node reboots into v8
4. Rollback slot now shows v9

---

## Disk space notes

During the v9 apply on the node:
- `/var/tmp/` needs ~2 GB for the bundle file
- `/var/tmp/iot-update-work/` needs ~2 GB for image.tar extraction
- `containers-storage` needs ~2 GB for the imported OCI layers
- Total peak usage: ~6 GB on `/var` (67 GB free — well within limits)

---

## Updating Containerfile (checklist for future versions)

When preparing vN+1:
1. Run `tools/sync-to-appliance.sh` to pick up any updater code changes
2. Bump version label in Containerfile (`LABEL version=vN+1`)
3. Update application config / packages as needed
4. Repeat Steps 3–7 above, replacing `v9` with `vN+1`
