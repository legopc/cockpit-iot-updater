# Building Real Update Images for the Inferno Appliance

This guide explains how to build and deliver a new `inferno-appliance` OCI image
to a running device via the Cockpit IoT Updater page.

The device at `192.168.1.43` runs a **bootc-managed OCI image** (`inferno-appliance:v8`).
Updates are delivered as a new full container image — not traditional package upgrades.
The IoT Updater page handles the upload and applies the update via `bootc switch`.

---

## When to build a new image

Build a new image whenever any of the following change:

| Change type | Where it lives | Example |
|-------------|---------------|---------|
| Installed packages | `Containerfile` | Add a new cockpit module |
| Inferno binaries | GitHub Releases (`legopc/inferno-aoip-releases`) | New `libasound_module_pcm_inferno.so` |
| Systemd unit templates | `templates/systemd/` | Adjust restart policy |
| ALSA config templates | `templates/alsa/` | Change buffer sizes |
| Cockpit page (IoT Updater) | `cockpit/` in source repo | UI improvements |
| First-boot configure script | `build/inferno-configure.sh` | Fix NIC detection |
| statime PTP config template | `templates/inferno-ptpv1.toml` | Adjust sync interval |
| Kernel module options | `Containerfile` | Change snd-aloop index |

---

## Build environment

| Item | Value |
|------|-------|
| Build host | PRX-01 (`10.10.1.201`) |
| Build directory | `/mnt/inferno-build/inferno-aoip-releases/` |
| Source repo | `github.com/legopc/inferno-aoip-releases` (private) |
| SSH to PRX-01 | `ssh root@10.10.1.201` (password: `Schnitzel-king1`) |

---

## Step 1 — Make your changes on the build host

SSH to PRX-01 and update the source:

```bash
ssh root@10.10.1.201
cd /mnt/inferno-build/inferno-aoip-releases/

# Pull latest changes (if working from git)
git pull

# Edit what you need — e.g.:
nano Containerfile
nano templates/alsa/99-inferno.conf
nano build/inferno-configure.sh
# etc.
```

### Bumping the binary version (new inferno .so or statime)

The Containerfile pulls binaries from GitHub Releases at build time:

```dockerfile
ARG RELEASES_URL=https://github.com/legopc/inferno-aoip-releases/releases/latest/download
```

To use a specific release instead of `latest`, change `latest` to the tag name:
```dockerfile
ARG RELEASES_URL=https://github.com/legopc/inferno-aoip-releases/releases/download/v2026-05-01
```

> **Note:** The binary release tarball (`inferno-aoip.tar.gz`) is built separately
> from the Inferno development repo. To build new binaries, see the Inferno dev project
> at `~/Inferno_developement/`.

### Updating the Cockpit IoT Updater page

If you updated files in `cockpit-iot-updater/`, copy them into the source repo:

```bash
# From the jumphost, sync changed cockpit page files:
SRC=/home/legopc/cockpit-iot-updater/cockpit-page
DST=/mnt/inferno-build/inferno-aoip-releases/cockpit

scp -i ~/.ssh/inferno_proxmox ${SRC}/index.html root@10.10.1.201:${DST}/
scp -i ~/.ssh/inferno_proxmox ${SRC}/update.js  root@10.10.1.201:${DST}/
scp -i ~/.ssh/inferno_proxmox ${SRC}/manifest.json root@10.10.1.201:${DST}/
```

---

## Step 2 — Build the new container image on PRX-01

Choose the next version number (current production is `v8`, so use `v9`):

```bash
cd /mnt/inferno-build/inferno-aoip-releases/

# Build — this takes 2–5 minutes (downloads packages + binary tarball)
podman build -t inferno-appliance:v9 .

# Verify it built correctly:
podman images | grep inferno-appliance
# Should show: localhost/inferno-appliance  v9  <id>  <size>
```

**If the build fails:**
- `dnf install` errors → check for package name changes in Fedora 43
- Binary download fails → check `legopc/inferno-aoip-releases` GitHub Releases page
- `COPY` errors → verify file paths in `templates/`, `cockpit/`, `build/` dirs

---

## Step 3 — Export and bundle the image

Still on PRX-01, export the image and create the `.iotupdate` bundle:

```bash
# Option A: Use make-oci-bundle.sh directly on PRX-01 (if the script is available there)
# Copy the script from the jumphost first:
# scp -i ~/.ssh/inferno_proxmox /home/legopc/cockpit-iot-updater/tools/make-oci-bundle.sh \
#     root@10.10.1.201:/mnt/inferno-build/make-oci-bundle.sh

cd /mnt/inferno-build/
bash make-oci-bundle.sh \
    --image inferno-appliance:v9 \
    --version v9 \
    --description "Describe what changed in this version" \
    --out /mnt/inferno-build/inferno-appliance-v9.iotupdate
```

```bash
# Option B: Export manually, bundle on the jumphost
# On PRX-01 — export the OCI image:
podman save inferno-appliance:v9 -o /mnt/inferno-build/inferno-appliance-v9.tar

# Transfer to jumphost:
scp -i ~/.ssh/inferno_proxmox \
    root@10.10.1.201:/mnt/inferno-build/inferno-appliance-v9.tar \
    /tmp/inferno-appliance-v9.tar

# Bundle on jumphost:
cd /home/legopc/cockpit-iot-updater
bash tools/make-oci-bundle.sh \
    --archive /tmp/inferno-appliance-v9.tar \
    --version v9 \
    --description "Describe what changed in this version" \
    --out /tmp/inferno-appliance-v9.iotupdate
```

The `.iotupdate` file will be approximately the same size as the image itself (~2GB).

---

## Step 4 — Upload via Cockpit IoT Updater

1. Open a browser: `https://192.168.1.43:9090`
2. Log in as `core` / `inferno123`
3. Click **IoT Updater** in the sidebar
4. The **Current Deployment** card shows the running image (e.g. `inferno-appliance:v8`)
5. Drag the `.iotupdate` file onto the upload area (or click to browse)
6. The page shows a version preview — verify it says `v9` and your description
7. Click **Apply Update**
8. Progress bar advances through: Extracting → Loading OCI image → Staging bootc → Rebooting
9. The device reboots; reconnect after ~60 seconds
10. **Current Deployment** now shows `inferno-appliance:v9` ✅

> **Upload time:** At Gigabit LAN speeds, a 2GB bundle uploads in ~20–30 seconds.
> At 100 Mbps, allow ~3–4 minutes. Do not close the browser during upload.

---

## What happens on the device during apply

The `apply-update.sh` script (triggered by `iot-update.service`) performs:

```
1. Validates bundle exists and reads version.json
2. Detects oci_image_file field → takes OCI path
3. Extracts image.tar from the .iotupdate bundle
4. skopeo copy oci-archive:image.tar containers-storage:localhost/inferno-appliance:v9
   └─ loads the full OCI image into local container storage (~1-3 minutes)
5. bootc switch --transport containers-storage localhost/inferno-appliance:v9
   └─ stages the new image for next boot (atomically, no partial state)
6. systemctl reboot
   └─ bootc applies the staged image on boot (~30-60 seconds)
```

**Important:** The `skopeo copy` step is the longest (loading ~2GB into local storage).
The progress bar will sit at ~50% for 1–3 minutes — this is normal.

---

## Rollback

If the new image doesn't boot correctly, bootc keeps the previous deployment:

```bash
# SSH to the device (if it comes up with old image via bootc fallback)
ssh core@192.168.1.43

# Check deployments:
sudo bootc status

# Roll back to previous:
sudo bootc rollback
sudo systemctl reboot
```

bootc always keeps the last two deployments. If a new image fails to boot, the device
automatically falls back to the previous image after 3 failed boot attempts (bootc behavior).

---

## Version history on the device

The IoT Updater tracks all applied updates in `/var/lib/iot-updater/history.json`.
The **Update History** card in the Cockpit page shows this list, including:
- Version string and description
- Date applied
- Status: `applied`, `dry_run`, or `error`

---

## Testing with a dry-run bundle (no device changes)

Before delivering a real update, you can test the full upload/apply flow using a fake bundle:

```bash
# On the jumphost:
bash /home/legopc/cockpit-iot-updater/tools/make-test-bundle.sh
# Creates: /tmp/test-update.iotupdate (~110KB dry-run bundle)

# Upload this to the device via the Cockpit page — it simulates the flow
# without modifying anything. The device does NOT reboot.
```

---

## Caveats and gotchas

- **No partial updates:** The full OCI image (~2GB) is transferred every time. There is no
  delta or diff mechanism. This is intentional — simplicity over bandwidth efficiency.

- **Disk space on device:** The device needs enough space in `/var` for the extracted
  bundle and the loaded image. Check with `df -h /var` before uploading.
  Rule of thumb: need ~4GB free during apply (bundle + image tar + container storage).

- **`skopeo` loads into containers-storage, not /var/tmp:** Container storage on Fedora IoT
  is at `/var/lib/containers/storage/`. This persists across reboots and is bootc-managed.

- **bootc transport must match:** The node was originally installed with
  `transport: registry` pointing to `localhost/inferno-appliance:v8`. After an update via
  `bootc switch --transport containers-storage`, the transport changes to `containers-storage`.
  Subsequent updates must continue via the IoT Updater (same mechanism). This is fine.

- **Do not use `bootc upgrade`** on this device — the source image is not in a remote registry.
  All updates must go through the IoT Updater upload mechanism.

- **Cockpit session disconnects on reboot:** This is expected. Wait 60 seconds and reload
  `https://192.168.1.43:9090`. The Update History card will show the applied entry.
