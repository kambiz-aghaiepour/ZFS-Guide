# ZFS Starter Guide — Encrypted Backup Pool with Offsite B2 Replication

A complete, tested walkthrough for building an encrypted ZFS backup pool on NVMe,
snapshotting it automatically, replicating it offsite to Backblaze B2 with end-to-end
encryption, and recovering from it — including the guide author's own failure modes.

**Audience:** Linux sysadmins, Fedora/RPM-based systems shown (adapt per distro).
**Result:** a raidz1 pool with an AES-256-GCM encrypted dataset, daily/weekly/monthly
snapshots, weekly encrypted B2 chain, verified restore drills, and a disaster runbook.

> This guide was validated against OpenZFS 2.4.x, rclone 1.74.x, B2. Commands need root.
> It contains no secrets: where you need your own key/passphrase, placeholders are shown.

---

## Table of Contents

1. [Architecture overview](#1-architecture-overview)
2. [ZFS concepts you need](#2-zfs-concepts-you-need)
3. [Step 0 — Install OpenZFS](#3-step-0--install-openzfs)
4. [Step 1 — Create the pool](#4-step-1--create-the-pool)
5. [Step 2 — Encryption and the dataset](#5-step-2--encryption-and-the-dataset)
6. [Step 3 — Snapshots (daily/weekly/monthly)](#6-step-3--snapshots)
7. [Step 4 — Offsite B2 replication](#7-step-4--offsite-b2-replication)
8. [Step 5 — Restore drills](#8-step-5--restore-drills)
9. [Step 6 — Disaster recovery](#9-step-6--disaster-recovery)
10. [Maintenance](#10-maintenance)
11. [Key custody and FAQ](#11-key-custody-and-faq)
12. [Troubleshooting](#12-troubleshooting)

---

## 1. Architecture overview

```
        ┌─────────────────────────── linux box ───────────────────────────┐
        │  pool: tank  (raidz1, 4 × NVMe, ~75% usable)                    │
        │  dataset: tank/backup → /backup                                 │
        │       encryption=aes-256-gcm  (key: /etc/zfs/zfs.key, 0400 root)│
        │       compression=zstd                                          │
        │  snapshots: daily×14 / weekly×8 / monthly×6 (zfs-snapshot.sh)    │
        └──────────────┬──────────────────────────────────┬───────────────┘
                       │ zfs send -w (raw/encrypted)      │ .zfs/snapshot/
                       ▼                                  ▼
        ┌──────────────────────────┐     ┌──────────────────────────────┐
        │ Offsite: B2 bucket       │     │ Local single-file recovery   │
        │  base.zfs   (full weekly)│     │ cp /backup/.zfs/snapshot/…   │
        │  deltas/*.zfs (increment)│     │ zfs diff / rollback (careful)│
        └──────────────────────────┘     └──────────────────────────────┘
```

- **Parity:** raidz1 (single parity) survives one disk failure with ~75% raw capacity.
- **Encryption:** dataset is encrypted natively; `zfs send -w` streams *ciphertext*,
  so the cloud provider never sees data or keys.
- **Offsite:** B2 stores a weekly chain (1 base + 8 incremental deltas). Restores happen
  on any ZFS host; B2 never needs to run ZFS.

## 2. ZFS concepts you need

| Concept | Meaning in this guide |
|---|---|
| **Pool** (`zpool`) | aggregates devices; `raidz1` = single parity, tolerates 1 drive |
| **ashift** | sector-size alignment of the vdev; `12` = 4 KiB (standard for modern disks) |
| **Dataset** | the filesystem; `zfs` manages it (not fstab) |
| **Checksums + scrub** | every block checksummed; `zpool scrub` verifies & self-heals from parity |
| **Encryption model** | a random **data encryption key (DEK)** encrypts data; the DEK is wrapped by a **wrapping key (WK)** — either a passphrase or a raw keyfile. Only the WK needs to be kept safe |
| **Raw send (`-w`)** | send encrypted blocks exactly as on disk; receiver cannot read without the WK |
| **Snapshots** | CoW point-in-time; read-only; instant; browsable at `.zfs/snapshot/` |
| **zfs-mount-generator** | systemd units for import/key-load/mount at boot |

## 3. Step 0 — Install OpenZFS

OpenZFS is not in Fedora's repos; use the official repo (DKMS packages, rebuilt on
kernel updates):

```bash
# Fedora (match your version)
dnf install -y https://zfsonlinux.org/fedora/zfs-release-3-1$(rpm --eval "%{dist}").noarch.rpm
dnf install -y zfs                      # pulls zfs-dkms; needs matching kernel-devel
modprobe zfs && zfs version | head -n1
echo 'zfs' | tee /etc/modules-load.d/zfs.conf    # load module at boot
```

- Install `kernel-devel-$(uname -r | cut -d- -f1)` before `zfs`.
- The package enables `zfs.target` and import/mount units automatically
  (`systemctl enable zfs.target` if not).

## 4. Step 1 — Create the pool

Use whole disks (ZFS manages them; no partitioning needed):

```bash
# raiz1 across 4 whole NVMe namespaces; ashift=12 for 4K alignment
zpool create -o ashift=12 tank raidz1 /dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1
zpool status          # expect ONLINE, no errors
zpool list -v tank    # raw ~ 4 × disk size; usable ≈ 75%
```

Checks: `zpool status -x` (should print "all pools are healthy").
If a disk already carries foreign signatures (LVM, old filesystem), `zpool create` warns;
wipe deliberately first (`pvremove`/`wipefs`) — that data is gone.

## 5. Step 2 — Encryption and the dataset

### Choose your key model

| Model | Wrapping key | At boot |
|---|---|---|
| **raw keyfile** (recommended) | `/etc/zfs/zfs.key` (32 random bytes, 0400 root) | fully unattended |
| passphrase | human-memorable | prompts (or keyfile containing passphrase) |

### A. Generate a raw keyfile (256-bit)

```bash
mkdir -p /etc/zfs
dd if=/dev/urandom of=/etc/zfs/zfs.key bs=32 count=1 status=none
chmod 400 /etc/zfs/zfs.key && chown root:root /etc/zfs/zfs.key
sha256sum /etc/zfs/zfs.key        # record this! verify offsite copy later
```

The keyfile **is the key** — 32 raw bytes, no headers, no passphrase, no recovery path
if lost. Keep at least two offsite copies of it.

### B. Create the encrypted dataset

```bash
zfs create -o encryption=aes-256-gcm \
           -o keyformat=raw \
           -o keylocation=file:///etc/zfs/zfs.key \
           -o compression=zstd \
           -o atime=off \
           -o mountpoint=/backup \
           tank/backup
zfs get keystatus,mountpoint,encryption,compression tank/backup
# expect: available, /backup, aes-256-gcm, zstd
```

### C. Unattended boot

ZFS boots itself through generated systemd units:

- `zfs-import-cache.service` imports pools from `/etc/zfs/zpool.cache`
- `zfs-load-key@tank-backup.service` loads the key from `keylocation` (no prompt)
- `tank-backup.mount` (generated) mounts it

They come from `zfs-mount-generator`, which reads `/etc/zfs/zfs-list.cache/<pool>`.
**Gotcha (real):** if you created the pool/dataset *before* `zfs-zed` ever ran, that
cache file doesn't exist and no units are generated. Fix:

```bash
systemctl start zfs-zed.service          # keep it running: it maintains the cache
mkdir -p /etc/zfs/zfs-list.cache && touch /etc/zfs/zfs-list.cache/tank
# replay the cache generation once (zed started after the fact):
ZED_ZEDLET_DIR=/etc/zfs/zed.d ZEVENT_POOL=tank ZEVENT_SUBCLASS=history_event \
  ZEVENT_HISTORY_DSNAME=tank/backup ZEVENT_HISTORY_INTERNAL_NAME=create \
  ZFS=/usr/sbin/zfs /etc/zfs/zed.d/history_event-zfs-list-cacher.sh
systemctl daemon-reload && systemctl list-unit-files | grep -E 'tank|backup'
# expect: tank.mount, backup.mount, zfs-load-key@tank-backup.service (generated)
```

Verify the boot path (unmount → unload key → load-key unit → mount unit):

```bash
systemctl stop backup.mount; zfs unload-key tank/backup
systemctl start zfs-load-key@tank-backup.service   # reads keyfile, no prompt
systemctl start backup.mount
findmnt /backup
```

### D. Mount management note

Once generated units exist, **systemd owns the mounts** — use
`systemctl start/stop backup.mount` (or reboot), not `zfs mount/unmount`; a
`systemctl daemon-reload` will even unmount a manually-mounted dataset to take
ownership.

## 6. Step 3 — Snapshots

### The script

`/usr/local/sbin/zfs-snapshot.sh` — daily (keep 14), weekly (keep 8), monthly (keep 6):

```bash
#!/bin/bash
set -euo pipefail
DS="tank/backup"; DAILY_KEEP=14; WEEKLY_KEEP=8; MONTHLY_KEEP=6
TODAY=$(date +%F); DOW=$(date +%u); DOM=$(date +%d)

snap() { # snap <kind> <name> <keep>
    local kind="$1" name="$2" keep="$3" full="${DS}@${name}"
    if ! zfs list -H -o name -t snapshot "$full" >/dev/null 2>&1; then
        zfs snapshot "$full" && echo "created $full"
    fi
    local to_delete
    mapfile -t to_delete < <(zfs list -H -o name -t snapshot "$DS" \
        | grep "@${kind}-" | sort -r | tail -n +$((keep + 1)))
    for s in "${to_delete[@]}"; do zfs destroy "$s" && echo "destroyed $s"; done
}

snap daily "daily-${TODAY}" "$DAILY_KEEP"
[ "$DOW" = "7" ] && snap weekly "weekly-${TODAY}" "$WEEKLY_KEEP"
[ "$DOM" = "01" ] && snap monthly "monthly-${TODAY}" "$MONTHLY_KEEP"
exit 0
```

systemd units (daily 02:00, `Persistent=true`):

```ini
# /usr/lib/systemd/system/zfs-snapshot.service
[Unit]
Description=ZFS snapshots of tank/backup (daily/weekly/monthly with retention)
Requires=zfs.target
After=zfs.target
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zfs-snapshot.sh

# /usr/lib/systemd/system/zfs-snapshot.timer
[Unit]
Description=Daily ZFS snapshot of tank/backup
[Timer]
OnCalendar=*-*-* 02:00:00
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
chmod 755 /usr/local/sbin/zfs-snapshot.sh
systemctl daemon-reload && systemctl enable --now zfs-snapshot.timer
```

### Browsing and single-file restore

```bash
zfs set snapdir=visible tank/backup           # makes .zfs browsable
ls /backup/.zfs/snapshot/                     # all snapshots, read-only
cp /backup/.zfs/snapshot/daily-2026-10-03/path/to/file /backup/path/to/file
zfs diff tank/backup@daily-2026-10-03 tank/backup@daily-2026-10-04   # what changed
```

**Never `zfs rollback` for one file** — it reverts the whole dataset and destroys
newer snapshots. `cp` is the single-file answer. If you must rollback: snapshot first,
then `zfs rollback tank/backup@target`.

## 7. Step 4 — Offsite B2 replication

### A. Backblaze setup

1. In the Backblaze console: **Buckets → Add Application Key** (Read/Write/Delete on a
   new bucket, e.g. `zfs-backup`). Save `keyID` + `applicationKey` in a password manager.
2. Install and configure rclone:

```bash
dnf install -y rclone
rclone config create b2 b2 account=<keyID> key=<applicationKey>
rclone lsd b2:                # bucket must be listed
rclone mkdir b2:zfs-backup
```

### B. The upload script

`/usr/local/sbin/zfs-b2-upload.sh` — uploads the latest `weekly-*` snapshot as a raw
(`-w`) stream: `base.zfs` initially, then `deltas/YYYY-MM-DD.zfs` incrementals; auto
full-resend if the local base was pruned; verifies uploaded size; keeps 8 deltas;
modes: `--dry-run`, `--drill`:

```bash
#!/bin/bash
set -euo pipefail
DS="tank/backup"; REMOTE="b2:zfs-backup"
STATE_DIR=/var/lib/zfs-backup; KEEP_DELTAS=8; KEYFILE=/etc/zfs/zfs.key

usage() { echo "usage: $0 [--dry-run|--drill]"; exit 1; }
MODE=upload
case "${1:-}" in "" ) ;; --dry-run ) MODE=dry-run ;; --drill ) MODE=drill ;; * ) usage ;; esac
[ ${#@} -gt 1 ] && usage
mkdir -p "$STATE_DIR"

drill() { # restore latest chain locally, verify, cleanup
    local TMP_DS="tank/drill" RC=0
    echo "== DRILL: restoring latest chain from $REMOTE =="
    zfs list -H -o name "$TMP_DS" >/dev/null 2>&1 && zfs destroy -r "$TMP_DS"
    rclone lsl "$REMOTE/base.zfs" >/dev/null 2>&1 || { echo "no base.zfs" >&2; exit 2; }
    echo "[1/5] receiving base.zfs"
    rclone cat "$REMOTE/base.zfs" | zfs receive -u -o "mountpoint=/tank/drill" "$TMP_DS" || RC=1
    mapfile -t DELTAS < <(rclone lsl "$REMOTE/deltas/" 2>/dev/null | awk '{print $NF}' | sort)
    echo "[2/5] receiving ${#DELTAS[@]} delta(s)"
    for d in "${DELTAS[@]}"; do
        d="${d#deltas/}"
        rclone cat "$REMOTE/deltas/$d" | zfs receive "$TMP_DS" || RC=1
    done
    if [ "$RC" = "0" ]; then
        echo "[3/5] loading key"; zfs load-key -L "file://$KEYFILE" "$TMP_DS" || RC=1
        echo "[4/5] mounting and comparing manifest"
        zfs mount "$TMP_DS" || RC=1
        local LIVE REST
        LIVE="$(cd /backup && find . -xdev -type f -printf '%P|%s\n' | sort)"
        REST="$(cd /tank/drill && find . -xdev -type f -printf '%P|%s\n' | sort)"
        [ "$LIVE" = "$REST" ] || RC=1
    fi
    echo "[5/5] cleanup"; zfs destroy -r "$TMP_DS" 2>/dev/null || true
    [ "$RC" = "0" ] && echo "DRILL OK" || { echo "DRILL FAILED" >&2; }
    exit "$RC"
}
[ "$MODE" = "drill" ] && drill

SNAP="$(zfs list -H -o name -t snapshot "$DS" | grep '@weekly-' | sort -r | head -n1 || true)"
[ -n "$SNAP" ] || { echo "no weekly snapshot" >&2; exit 2; }
BASE_FILE="$STATE_DIR/.base_snap"; PREV=""
[ -f "$BASE_FILE" ] && { PREV="$(cat "$BASE_FILE")"
  zfs list -H -o name -t snapshot "$PREV" >/dev/null 2>&1 || { echo "base gone - full send"; PREV=""; }; }
if [ -n "$PREV" ] && [ "$PREV" = "$SNAP" ]; then echo "already uploaded"; exit 0; fi
if [ -n "$PREV" ]; then OBJ="deltas/$(date +%F).zfs"; SEND_ARGS=(-i "$PREV"); else OBJ="base.zfs"; SEND_ARGS=(); fi
[ "$MODE" = "dry-run" ] && { echo "DRY RUN: zfs send -w ${SEND_ARGS[*]} $SNAP | rclone rcat $REMOTE/$OBJ"; exit 0; }

echo "snapshot: $SNAP -> $REMOTE/$OBJ"
BYTES=$(zfs send -w "${SEND_ARGS[@]}" "$SNAP" | tee >(rclone --quiet rcat "$REMOTE/$OBJ") | wc -c)
R_SIZE=$(rclone --quiet lsl "$REMOTE/$OBJ" | awk '{print $1}')
[ "${R_SIZE:-}" = "$BYTES" ] || { echo "size mismatch: $BYTES vs $R_SIZE" >&2; exit 1; }
echo "uploaded $BYTES bytes (verified)"
echo "$SNAP" > "$BASE_FILE"
[ -z "$PREV" ] && rclone delete --quiet "$REMOTE/deltas/" 2>/dev/null || true
mapfile -t OLD < <(rclone lsl "$REMOTE/deltas/" 2>/dev/null | awk '{print $NF}' | sort -r | tail -n +$((KEEP_DELTAS + 1)))
for o in "${OLD[@]}"; do o="${o#deltas/}"; rclone delete --quiet "$REMOTE/$o" && echo "pruned $o"; done
echo "OK"
```

> **Gotcha (real):** `rclone lsl` lines are `size date time name` — the name is the
> **last** field (`awk '{print $NF}'`), not `$2` (that's the date). Using `$2` produces
> a "cannot receive: failed to read from stream" failure. Also: pick the **latest**
> weekly snapshot by listing, not by today's date — the snapshot exists from the day it
> was created.

systemd units (after snapshot timer; Mon 03:00):

```ini
# /usr/lib/systemd/system/zfs-b2-upload.service
[Unit]
Description=Weekly encrypted ZFS send of tank/backup to Backblaze B2
Requires=zfs.target
After=zfs.target zfs-snapshot.service
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/zfs-b2-upload.sh

# /usr/lib/systemd/system/zfs-b2-upload.timer
[Unit]
Description=Weekly encrypted ZFS send of tank/backup to Backblaze B2
[Timer]
OnCalendar=Mon *-*-* 03:00:00
Persistent=true
[Install]
WantedBy=timers.target
```

```bash
chmod 755 /usr/local/sbin/zfs-b2-upload.sh
systemctl daemon-reload && systemctl enable --now zfs-b2-upload.timer
```

### C. What lives in B2

```
b2:zfs-backup/
  base.zfs            ← full raw send of the first weekly snapshot
  deltas/2026-10-03.zfs ← incremental raw send (chain continues from base)
  deltas/2026-10-10.zfs
  ...
```

- Only the **weekly** chain is offsite. `daily-*`/`monthly-*` are local-only.
- Every object is ciphertext (`-w`); B2 cannot read it.
- Restore = download base + deltas in chronological order (see §9).

## 8. Step 5 — Restore drills

```bash
zfs-b2-upload.sh --dry-run    # show the planned send, touch nothing
zfs-b2-upload.sh --drill      # real test: downloads chain, receives, decrypts,
                              # mounts to /tank/drill, compares file manifest vs /backup, cleans up
```

The drill proves: chain completeness, stream integrity (receive verifies checksums),
decryptability (keyfile), mountability, and content equality. Run monthly, and after
any change to the pipeline. Drill = download volume; B2 egress is free up to 3× storage.

## 9. Step 6 — Disaster recovery

**Things that survive you:** (1) offsite `zfs.key` copy + its SHA256, (2) B2
Application Key, (3) bucket name. Everything else is rebuildable.

### Full restore (drives fail)

```bash
# 1. Install (any Linux; ZFS 2.x+; root FS can be anything):
dnf install -y https://zfsonlinux.org/fedora/zfs-release-3-1$(rpm --eval "%{dist}").noarch.rpm
dnf install -y zfs rclone && modprobe zfs

# 2. Key, byte-exact, verified:
install -m 400 -o root -g root <offsite copy> /etc/zfs/zfs.key
sha256sum /etc/zfs/zfs.key        # must equal recorded hash

# 3. B2 access:
rclone config create b2 b2 account=<keyID> key=<applicationKey>
rclone lsd b2:

# 4. New pool (geometry/name may differ - receive remaps):
zpool create -o ashift=12 tank raidz1 /dev/nvme0n1 /dev/nvme1n1 /dev/nvme2n1 /dev/nvme3n1

# 5. Receive base + deltas, chronological:
rclone cat b2:zfs-backup/base.zfs | zfs receive -u -o mountpoint=/backup tank/backup
rclone lsl b2:zfs-backup/deltas/ | awk '{print $NF}' | sort | while read -r d; do
  rclone cat "b2:zfs-backup/deltas/$d" | zfs receive tank/backup
done

# 6. Decrypt, mount, make snapshots browsable:
zfs load-key -L file:///etc/zfs/zfs.key tank/backup
zfs mount tank/backup
zfs set snapdir=visible tank/backup

# 7. Verify:
zfs get keystatus,mountpoint tank/backup
ls /backup/.zfs/snapshot/          # weekly points reconstructed
zpool scrub tank                   # integrity pass
zfs-b2-upload.sh --drill           # re-prove the chain

# 8. Resume automation: reinstall scripts/units; seed the chain state with the newest
#    restored weekly snapshot so the next upload is incremental:
zfs list -t snapshot tank/backup | grep @weekly- | sort -r | head -1 > /var/lib/zfs-backup/.base_snap
systemctl enable --now zfs-snapshot.timer zfs-b2-upload.timer
```

**What the restore reconstructs:** every `weekly-*` snapshot in the chain (base carries
its own snapshot; each delta carries the next). **Not reconstructed:** `daily-*` and
`monthly-*` (local-only). After a disaster you have ~weekly granularity, not daily.

### Single file from B2 (older than local retention)

```bash
rclone cat b2:zfs-backup/base.zfs | zfs receive -u -o mountpoint=/tank/x tank/recover
rclone lsl b2:zfs-backup/deltas/ | awk '{print $NF}' | sort | while read -r d; do
  rclone cat "b2:zfs-backup/deltas/$d" | zfs receive tank/recover
done
zfs load-key -L file:///etc/zfs/zfs.key tank/recover && zfs mount tank/recover
cp /tank/recover/path/to/file /backup/path/to/file
zfs destroy -r tank/recover
```

Receiving materializes the **whole volume state** — scratch space ≈ data size. There is
no partial extraction from a stream. For everyday single files use local snapshots.

## 10. Maintenance

```bash
systemctl enable --now zfs-scrub-weekly@tank.timer     # shipped scrub timer
systemctl enable --now zfs-trim-weekly@tank.timer      # NVMe TRIM (backup pool)
zpool status -x                                        # health; all healthy
zpool scrub tank                                       # manual scrub
zfs list -t snapshot                                   # retention state
nvme smart-log -H /dev/nvme0n1                         # drive health (all disks)
```

Scrub verifies all checksums weekly; trim keeps NVMe performance. Alert on
`zpool status` not ONLINE (or use smartd/zabbix-style monitoring around it).

## 11. Key custody and FAQ

**Key format:** exactly 32 raw random bytes, mode 0400 root. No header, no text, no
passphrase — the file content *is* the wrapping key. (Human-memorable alternative:
`keyformat=passphrase` + `keylocation=prompt`/keyfile; prompts at boot unless in a file.)

**Key deleted?** Current session unaffected (key cached in kernel); after reboot the
`zfs-load-key@` unit fails, `/backup` doesn't mount, boot itself is fine. Restore the
byte-identical file (verify SHA256). **Different bytes = permanently unreadable.** Two
offsite copies minimum.

**Is local restoration encrypted-but-recoverable?** Yes: `zfs load-key` (from keyfile
or prompt) + `zfs mount`. `zfs change-key` can rewrap the DEK to a new key without
re-encrypting data.

**Provider notes (cost/egress matter more than storage):**
| Provider | ~$/TB-mo | Restore egress |
|---|---|---|
| Backblaze B2 | $6.95 | free up to 3× storage, then $0.01/GB |
| Wasabi | $7.99 | $0 |
| AWS S3 Glacier Deep Archive | $0.99 | $0.09/GB + retrieval (minutes-days) |
| GCS Coldline/Archive | $4 / $1.2 | $0.12/GB + retrieval |

**Reboot behavior with keyfile:** fully unattended — systemd import → `zfs-load-key@`
reads keyfile → mount. No password anywhere.

## 12. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `zfs load-key` says busy | dataset is mounted; `systemctl stop backup.mount` first |
| No `zfs-load-key@`/`backup.mount` units | `/etc/zfs/zfs-list.cache/tank` missing → see §5C |
| `systemd` unmounts `/backup` after daemon-reload | expected: systemd owns generated `.mount` units; use systemctl |
| Drill: `cannot receive: failed to read from stream` | wrong object path (`awk $2` vs `$NF` on `rclone lsl`) or stale chain |
| `not an earlier snapshot from the same fs` | sending a snapshot onto itself; script picks latest and checks state |
| Upload every week fails "missing snapshot" | snapshot name derived from date; always list latest (see §7B) |
| Couldn't receive: destination exists | `zfs receive` creates new FS; don't pre-create (or use `-F`) |

---

*Validated end-to-end: pool → encryption → snapshots → B2 chain (full + incremental) →
drill with content manifest → documented recovery. All scripts are generic; the only
secrets in your deployment are the keyfile and the B2 credentials, both outside the repo.*
