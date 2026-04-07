# Inferno Appliance Build Pipeline

Explains how the `cockpit-iot-updater` integrates with the `inferno-aoip-releases` build pipeline.

## Overview

```
cockpit-iot-updater (this repo)
  └─ tools/sync-to-appliance.sh
         │
         ▼
  inferno-aoip-releases/iot-updater/   (appliance source)
         │
         ▼
  Containerfile (podman build on PRX-01 / COPILOT-BUILD-01)
         │
         ▼
  OCI image → make-oci-bundle.sh → .iotupdate
         │
         ▼
  Cockpit IoT Updater UI → apply-update.sh → bootc switch → reboot
```

## Build servers

| Server | Role |
|--------|------|
| COPILOT-BUILD-01 (10.10.1.98) | Image builder, HTTP file server |
| PRX-01 (10.10.1.201) | Proxmox host, VMs |

Built artefacts served at http://10.10.1.98/ (no auth required on local network).

## Step 1: Sync updater files to appliance source

Run on the jumphost after making changes to cockpit-iot-updater:

```bash
cd cockpit-iot-updater
tools/sync-to-appliance.sh --appliance-src /path/to/inferno-aoip-releases
```

## Step 2: Build the appliance image

Use the inferno-build skill or run the build script directly on COPILOT-BUILD-01.
The Containerfile installs: skopeo, bootc, bsdiff, cockpit, iot-updater files.

## Step 3: Package as .iotupdate (full bundle)

```bash
tools/make-oci-bundle.sh \
  --archive /path/to/image.tar \
  --version vN \
  --description "Description" \
  --changelog "What changed" \
  --out inferno-appliance-vN.iotupdate
```

## Step 4: (Optional) Create delta bundle

Only viable for minor updates (typically ~50 KB vs 2 GB full bundle). Requires the
base image to be present in podman's image store on the build host.

> **IMPORTANT:** Run as root (`sudo`) on COPILOT-BUILD-01. The Inferno build pipeline
> loads images via `sudo podman`, so they live in root's containers-storage. The script
> must also run as root so `podman save` can export them. The apply-update.sh script
> on the appliance also runs as root and uses `podman save --format docker-archive`
> to export the base for sha256 comparison — both ends must produce the same bytes.

```bash
# Using images already in root's containers-storage:
sudo tools/make-delta-bundle.sh \
  --base-image localhost/inferno-appliance:v(N-1) \
  --target-image localhost/inferno-appliance:vN \
  --base-version v(N-1) \
  --version vN \
  --image-name localhost/inferno-appliance:vN \
  --description "Delta: v(N-1) to vN" \
  --out inferno-v(N-1)-to-vN.delta.iotupdate

# Or using pre-existing .tar archives (must be docker-archive format):
sudo tools/make-delta-bundle.sh \
  --base-archive inferno-appliance-v(N-1).tar \
  --target-archive inferno-appliance-vN.tar \
  --base-version v(N-1) \
  --version vN \
  --image-name localhost/inferno-appliance:vN \
  --description "Delta: v(N-1) to vN" \
  --out inferno-v(N-1)-to-vN.delta.iotupdate
```

Build host requirements: bsdiff installed, ~8 GB free disk, ~6 GB free RAM, run as root.

## Step 5: Distribute

Copy .iotupdate files to COPILOT-BUILD-01 HTTP root, or distribute via manifest URL.

## After appliance update (post-reboot)

The new image has the updater baked in. If testing a pre-release updater version, re-deploy manually:

```bash
# From jumphost:
sshpass -p 'inferno123' scp sidecar/server.py core@NODE_IP:/tmp/
sshpass -p 'inferno123' ssh core@NODE_IP "sudo cp /tmp/server.py /var/lib/iot-updater/server.py && sudo chmod 700 /var/lib/iot-updater/server.py && sudo systemctl restart iot-updater.service"
```
