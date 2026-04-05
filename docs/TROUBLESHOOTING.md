# Troubleshooting Guide

---

## Sidecar not reachable

**Symptom:** Cockpit page shows "Sidecar unreachable — is iot-updater.service running?"

```bash
# Check service status
systemctl status iot-updater.service

# Check it's listening
curl http://127.0.0.1:8088/status

# View logs
journalctl -u iot-updater.service -n 50
```

**Common causes:**
- Service not started: `systemctl enable --now iot-updater.service`
- Python syntax error: `python3 /var/lib/iot-updater/server.py` (run manually to see error)
- Port conflict: `ss -tlnp | grep 8088`

---

## "IoT Updater" not in Cockpit sidebar

**Symptom:** The page doesn't appear in Cockpit's navigation

```bash
# Check the page files exist (user-local install)
ls ~/.local/share/cockpit/iot-updater/
# Should show: manifest.json  index.html  update.js

# Or system-wide install:
ls /usr/share/cockpit/iot-updater/

# Restart Cockpit to reload plugins
systemctl restart cockpit.socket
```

**Note:** The manifest.json key must be `"index"` (not `"iot-updater"`) so Cockpit
maps it to `index.html`. If you see a 404 when clicking IoT Updater, check that
manifest.json contains `"index": { ... }`.

---

## Upload fails or stalls

**Symptom:** Progress bar stops, browser shows network error

```bash
# Check sidecar is still alive during upload
journalctl -u iot-updater.service -f

# Check disk space (/var/tmp must have ~2× bundle size free)
df -h /var/tmp

# Check partial file
ls -lh /var/tmp/iot43-update.iotupdate
```

**Common causes:**
- `/var/tmp` full: `rm /var/tmp/iot43-update.iotupdate` then free space
- Browser timeout: try a different browser; avoid Safari for large uploads
- Connection reset: ensure your LAN is stable; Gigabit recommended for 2 GB files

---

## "Bundle error: version.json missing or invalid"

**Symptom:** After upload, error appears instead of version preview

```bash
# Verify the bundle on the source machine before uploading
tar -tvf bundle.iotupdate        # should list version.json and image.tar
tar -xOf bundle.iotupdate version.json | python3 -m json.tool   # should print valid JSON
```

The bundle may not have been created by `make-oci-bundle.sh` (wrong format) or was
corrupted during download/transfer.

---

## SHA-256 verification fails

**Symptom:** Upload completes but sidecar returns "SHA-256 mismatch" error

```bash
# Manually check the hash
tar -xOf /var/tmp/iot43-update.iotupdate version.json | python3 -c \
    "import json,sys; print(json.load(sys.stdin).get('image_sha256','<no hash>'))"
tar -xOf /var/tmp/iot43-update.iotupdate image.tar | sha256sum
```

**Common causes:**
- Bundle corrupted in transit (re-download from build host)
- Bundle was hand-edited after hash was embedded — recreate with `make-oci-bundle.sh`

If you have a legitimate bundle without a hash (pre-hash era):
The sidecar will log a warning and continue (hash is optional). Bundles from
`make-oci-bundle.sh` always include the hash.

---

## skopeo copy fails / hangs

**Symptom:** Apply starts, progress bar stuck for > 5 minutes, `iot-update.service` fails

```bash
journalctl -u iot-update.service -n 100

# Check disk space on /var (needs ~4 GB free during apply)
df -h /var
```

**Common causes:**

| Error | Fix |
|-------|-----|
| `no space left on device` | Free space on `/var`; skopeo + containers-storage both need room |
| `Error parsing image configuration` | image.tar is corrupted; re-create the bundle |
| `layers from manifest don't match image config` | Podman export issue; rebuild the image |
| `permission denied` | apply-update.sh not running as root; check iot-update.service |

---

## bootc switch fails

**Symptom:** skopeo succeeds, bootc switch fails, device does not reboot

```bash
journalctl -u iot-update.service -n 50

# Manually run bootc switch to see error:
bootc switch --transport containers-storage localhost/inferno-appliance:v9
```

**Common causes:**

| Error | Fix |
|-------|-----|
| `image not found in containers-storage` | skopeo copy failed silently; check its log |
| `cannot switch to same image` | Already on v9; bundle already applied |
| `bootc: command not found` | bootc not installed; `rpm-ostree install bootc` |

---

## "No rollback available"

**Symptom:** Clicking Rollback shows "No rollback slot available"

This is expected if the device has never had a successful OCI update applied via
`bootc switch`. The rollback slot is created automatically after the first real
update completes. The rollback button is hidden in the UI until a rollback slot exists.

```bash
bootc status --format json | python3 -c \
    "import json,sys; d=json.load(sys.stdin); print('rollback:', d.get('rollback'))"
```

---

## bootc status shows wrong data / cached

The `/bootc-status` endpoint caches results for 5 seconds. If you just applied a change
and the UI hasn't updated, wait 10 seconds for the next poll cycle to refresh.

---

## Progress bar stuck at ~50% for a long time

This is normal. The `skopeo copy` step (loading the 2 GB image into containers-storage)
is the bottleneck — it typically takes 1–3 minutes and holds the progress bar near 50%.
Check the journal to confirm it's still running:

```bash
journalctl -u iot-update.service -f
```

---

## Device reboots but boots wrong version

```bash
bootc status
```

If the staged image shows correctly before reboot but wrong version after, the
`bootc switch` worked but something overrode the boot selection. This is unusual.

Manually force the correct image:
```bash
bootc switch --transport containers-storage localhost/inferno-appliance:vN
systemctl reboot
```

---

## History file corrupted

```bash
# Reset history (loses audit trail, sidecar recovers cleanly)
echo '[]' > /var/lib/iot-updater/history.json

# Or view and validate
cat /var/lib/iot-updater/history.json | python3 -m json.tool
```

---

## Manual apply (bypassing the UI)

If the Cockpit page is unavailable, apply the bundle manually:

```bash
# Copy bundle to device
scp bundle.iotupdate user@device:/var/tmp/iot43-update.iotupdate

# On the device as root:
bash /var/lib/iot-updater/apply-update.sh

# The script will:
# 1. Verify SHA-256 (if hash present in version.json)
# 2. Extract image.tar from the bundle
# 3. skopeo copy → containers-storage
# 4. bootc switch
# 5. Reboot
```

---

## Manual rollback (bypassing the UI)

```bash
# On the device as root
bootc rollback --apply
# Device reboots immediately into the previous deployment
```

Update the history entry if needed:
```bash
python3 -c "
import json
h = json.load(open('/var/lib/iot-updater/history.json'))
if h: h[-1]['status'] = 'rolledback'
json.dump(h, open('/var/lib/iot-updater/history.json','w'), indent=2)
"
```
