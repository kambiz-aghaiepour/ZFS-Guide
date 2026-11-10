# ZFS Starter Guide — Encrypted Backup Pool with Offsite B2 Replication

A complete, tested walkthrough for building an encrypted ZFS backup pool,
populating it with critical files, snapshotting it automatically, replicating
it offsite to Backblaze B2 with end-to-end encryption, restoring files locally
or from B2, and recovering from a lost pool — including the guide author's own
failure modes.

**Audience:** Linux sysadmins. Fedora/RPM systems are shown; adapt per distro.
**Result:** a raidz1 pool with an AES-256-GCM encrypted dataset, rsync-fed
daily/weekly/monthly snapshots, a weekly encrypted B2 chain, verified restore
drills, a local restore runbook, and a disaster/rebuild runbook.

> Validated against OpenZFS 2.4.x and rclone 1.75.x on Fedora 44. The helper
> scripts and units are shipped as real files; the restore drill was exercised
> end-to-end against B2 and the upload logic was tested against a local rclone
> remote. Commands need root unless noted.
> This repository contains no secrets: keys, account IDs, bucket names, and
> hostnames are placeholders.

## Repository layout

| Path | Purpose |
|---|---|
| `README.md` | this guide |
| `scripts/zfs-snapshot.sh` | snapshot creation + retention (daily/weekly/monthly/yearly) |
| `scripts/zfs-b2-upload.sh` | raw encrypted B2 upload, `--dry-run`, `--drill` |
| `systemd/` | service and timer units for both scripts |
| `examples/zfs-backup.conf` | optional overrides for datasets, remote, retention |
| `examples/rsync-documents.cron` | cron template for the critical-file copies |
| `.gitignore` | keeps local credentials and state out of git |

Unless noted, run install commands from the root of a checkout of this
repository.

---

## Table of contents

1. [Architecture overview](#1-architecture-overview)
2. [ZFS concepts you need](#2-zfs-concepts-you-need)
3. [Step 0 — Install OpenZFS](#3-step-0--install-openzfs)
4. [Step 1 — Create the pool](#4-step-1--create-the-pool)
5. [Step 2 — Encryption and the dataset](#5-step-2--encryption-and-the-dataset)
6. [Step 3 — Populate the backup volume](#6-step-3--populate-the-backup-volume)
7. [Step 4 — Snapshots and local restores](#7-step-4--snapshots-and-local-restores)
8. [Step 5 — Offsite B2 replication](#8-step-5--offsite-b2-replication)
9. [Step 6 — Restore drills](#9-step-6--restore-drills)
10. [Step 7 — Disaster recovery](#10-step-7--disaster-recovery)
11. [Step 8 — Rebuild the local volume](#11-step-8--rebuild-the-local-volume)
12. [Maintenance](#12-maintenance)
13. [Key custody and FAQ](#13-key-custody-and-faq)
14. [Troubleshooting](#14-troubleshooting)

---

## 1. Architecture overview

```
        +--------------------------- linux box ---------------------------+
        |  pool: tank  (raidz1, 4 x NVMe, ~75% usable)                    |
        |  dataset: tank/backup -> /backup                                |
        |       encryption=aes-256-gcm  (key: /etc/zfs/zfs.key, 0400 root)|
        |       compression=zstd                                          |
        |  snapshots: daily x14 / weekly x8 / monthly x12 / yearly x3     |
        +--------+--------------------------------------+-----------------+
                 ^                                      |
                 | rsync (cron, before 02:00)           | zfs send -w (raw/encrypted)
                 |                                      v
        +--------+-----------------+        +-----------------------------+
        | Critical files           |        | Offsite: B2 bucket          |
        | ~/Documents, ~/Pictures, |        |  base.zfs (full weekly)     |
        | ~/Projects, ~/.ssh, ...  |        |  deltas/*.zfs (incremental) |
        +--------------------------+        +-----------------------------+

        /backup/.zfs/snapshot/  -> local single-file / directory restore
        tank/restore (clone)    -> read-only snapshot clone when needed
```

- **Parity:** raidz1 survives one disk failure with ~75% raw capacity. Adapt
  the vdev layout to your hardware.
- **Encryption:** the dataset is encrypted natively; `zfs send -w` streams
  ciphertext, so B2 never sees data or keys.
- **Ingestion:** rsync mirrors the critical source directories into
  `/backup/<hostname>/home/<user>/...` before the nightly snapshot. This step
  is mandatory; otherwise the snapshots and the B2 chain are empty.
- **Offsite:** B2 stores one weekly chain: a full base plus at most
  `KEEP_DELTAS` (default 8) increments. When the cap is reached, the upload
  script sends a fresh full base and clears the old chain.
- **Restores:** local restores come from the live volume or local snapshots;
  B2 restores materialize the chain into a scratch dataset. Disaster recovery
  rebuilds a host; Step 8 rebuilds only the local pool/dataset.

**Scope and assumptions**

- Linux with systemd; OpenZFS 2.x with raw encrypted send support.
- One dataset per installation. Run a second copy of the setup with different
  dataset/remote names if you need more.
- Offsite granularity is weekly (RPO up to ~8 days). Daily history is local.
- The scripts use absolute paths `/usr/sbin/zfs` and `/usr/bin/rclone`; adjust
  if your distribution differs.
- Upload/health alerting is not implemented; §12 suggests what to monitor.

## 2. ZFS concepts you need

| Concept | Meaning in this guide |
|---|---|
| **Pool** (`zpool`) | aggregates devices; `raidz1` = single parity, tolerates 1 drive |
| **ashift** | sector-size alignment of the vdev; `12` = 4 KiB (standard for modern disks) |
| **Dataset** | the filesystem; `zfs` manages it (not fstab) |
| **Checksums + scrub** | every block checksummed; `zpool scrub` verifies and self-heals from parity |
| **Encryption model** | a random **data encryption key (DEK)** encrypts data; the DEK is wrapped by a **wrapping key (WK)** — raw keyfile or passphrase. Only the WK needs to be kept safe |
| **Raw send (`-w`)** | sends encrypted blocks exactly as on disk; the receiver cannot read them without the WK |
| **Incremental send (`-i`)** | sends changes since an older snapshot; increments must be received after all earlier objects |
| **Snapshots** | CoW point-in-time, read-only, instant, browsable at `.zfs/snapshot/` |
| **Clone** | writable dataset created from a snapshot; useful for reading an old state without touching the live dataset |
| **zfs-mount-generator** | systemd units for import/key-load/mount at boot |

## 3. Step 0 — Install OpenZFS

OpenZFS is not in Fedora's repos; use the official repository (DKMS packages,
rebuilt on kernel updates):

```bash
# Fedora (match your version)
sudo dnf install -y https://zfsonlinux.org/fedora/zfs-release-3-1$(rpm --eval "%{dist}").noarch.rpm
sudo dnf install -y zfs                    # pulls zfs-dkms; needs matching kernel-devel
sudo modprobe zfs && zfs version | head -n1
echo 'zfs' | sudo tee /etc/modules-load.d/zfs.conf    # load the module at boot
```

- Install `kernel-devel-$(uname -r | cut -d- -f1)` before `zfs`.
- The package enables `zfs.target` and the import/mount units
  (`sudo systemctl enable zfs.target` if not).
- `zfs-zed` maintains the mount-generator cache; keep it running (§5C).

## 4. Step 1 — Create the pool

Use whole disks; ZFS manages them and no partitioning is needed. Prefer stable
`/dev/disk/by-id/...` names over `/dev/nvme0n1` or `/dev/sdX`.

```bash
lsblk -o NAME,SIZE,MODEL,SERIAL
sudo zpool create -o ashift=12 tank raidz1 \
  /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2> \
  /dev/disk/by-id/<disk3> /dev/disk/by-id/<disk4>
sudo zpool status          # expect ONLINE, no errors
sudo zpool list -v tank    # raw ~ 4 x disk size; usable ~75%
```

Checks: `sudo zpool status -x` should print `all pools are healthy`.

- `zpool create` destroys any existing data on the named vdevs. If the disks
  carry an importable pool, stop and import it instead:
  `sudo zpool import -d /dev/disk/by-id` (lists), then
  `sudo zpool import -d /dev/disk/by-id tank`.
- Foreign signatures (LVM, old filesystems) cause warnings; wipe deliberately
  with `wipefs`/`pvremove` only after confirming the data is expendable.

## 5. Step 2 — Encryption and the dataset

### Choose your key model

| Model | Wrapping key | At boot |
|---|---|---|
| **raw keyfile** (recommended) | `/etc/zfs/zfs.key` (32 random bytes, 0400 root) | fully unattended |
| passphrase | human-memorable | prompts, unless stored in a keyfile |

### A. Generate a raw keyfile (256-bit)

```bash
sudo install -d -m 755 /etc/zfs
sudo dd if=/dev/urandom of=/etc/zfs/zfs.key bs=32 count=1 status=none
sudo chmod 400 /etc/zfs/zfs.key
sudo chown root:root /etc/zfs/zfs.key
sudo sha256sum /etc/zfs/zfs.key        # record this hash outside the host
```

The keyfile **is the key** — 32 raw bytes, no header, no passphrase, no
recovery path if lost. Keep at least two offsite copies (password manager plus
an offline medium) and record the SHA-256 so a restored copy can be verified.
Never commit it to git.

### B. Create the encrypted dataset

```bash
sudo zfs create -o encryption=aes-256-gcm \
  -o keyformat=raw \
  -o keylocation=file:///etc/zfs/zfs.key \
  -o compression=zstd \
  -o atime=off \
  -o snapdir=visible \
  -o mountpoint=/backup \
  tank/backup

sudo zfs get keystatus,mountpoint,encryption,compression,snapdir tank/backup
# expect: available, /backup, aes-256-gcm, zstd, visible
```

`snapdir=visible` exposes read-only snapshots at `/backup/.zfs/snapshot/`,
which is used by the local restore steps in Step 4. It can also be enabled
later with `sudo zfs set snapdir=visible tank/backup`.

### C. Unattended boot

ZFS boots itself through generated systemd units:

- `zfs-import-cache.service` imports pools from `/etc/zfs/zpool.cache`
- `zfs-load-key@tank-backup.service` loads the key from `keylocation` (no prompt)
- `tank-backup.mount` (generated) mounts it

They come from `zfs-mount-generator`, which reads
`/etc/zfs/zfs-list.cache/<pool>`. **Gotcha (real):** if the pool/dataset was
created before `zfs-zed` ever ran, that cache file does not exist and no units
are generated. Fix:

```bash
sudo systemctl start zfs-zed.service          # keep it running: it maintains the cache
sudo mkdir -p /etc/zfs/zfs-list.cache && sudo touch /etc/zfs/zfs-list.cache/tank
# replay the cache generation once (zed started after the fact):
sudo env ZED_ZEDLET_DIR=/etc/zfs/zed.d ZEVENT_POOL=tank ZEVENT_SUBCLASS=history_event \
  ZEVENT_HISTORY_DSNAME=tank/backup ZEVENT_HISTORY_INTERNAL_NAME=create \
  ZFS=/usr/sbin/zfs /etc/zfs/zed.d/history_event-zfs-list-cacher.sh
sudo systemctl daemon-reload && systemctl list-unit-files | grep -E 'tank|backup'
# expect: tank.mount, backup.mount, zfs-load-key@tank-backup.service (generated)
```

Verify the boot path (unmount -> unload key -> load-key unit -> mount unit):

```bash
sudo systemctl stop backup.mount
sudo zfs unload-key tank/backup
sudo systemctl start zfs-load-key@tank-backup.service   # reads keyfile, no prompt
sudo systemctl start backup.mount
findmnt /backup
```

### D. Mount management note

Once generated units exist, **systemd owns the mounts** — use
`systemctl start/stop backup.mount` (or reboot), not `zfs mount/unmount`.
A `systemctl daemon-reload` can unmount a manually mounted dataset so systemd
can take ownership.

## 6. Step 3 — Populate the backup volume

The dataset starts empty. Mirror critical directories into it before the
snapshot timer runs. Use a host/user layout so several machines can share one
bucket later:

```
/backup/<hostname>/home/<user>/Documents
/backup/<hostname>/home/<user>/Pictures
/backup/<hostname>/home/<user>/Projects
...
```

### What to back up

| Source | Why |
|---|---|
| `~/Documents` | contracts, taxes, notes, scans |
| `~/Pictures`, `~/Videos` | personal media that cannot be regenerated |
| `~/Projects`, `~/src`, `~/git` | uncommitted or unpushed work |
| `~/.ssh`, `~/.gnupg` | keys and trust stores; the dataset is encrypted, but keep an offline copy too |
| `~/.config` | application and desktop configuration |
| local mail store | mail not held on a server |
| KeePass/KDBX/1Password exports | password databases; also keep an offline copy |

Skip what can be re-fetched or rebuilt: `~/.cache`, Trash, browser caches,
`~/Downloads` unless it holds originals, `node_modules`, `target/`, `dist/`,
Steam libraries, and VM images unless explicitly needed.

### Create the target directories

```bash
USER_NAME="$(id -un)"
HOST_NAME="$(hostname -s)"

for d in Documents Pictures Projects; do
  sudo install -d -o "$USER_NAME" -g "$USER_NAME" \
    "/backup/$HOST_NAME/home/$USER_NAME/$d"
done
```

The subdirectories must be writable by the cron user. Do not recursively chown
`/backup` itself; it is owned by root.

### Automate with rsync and cron

Run the copies as the owning user (`crontab -e`), with one line per source:

```cron
15 1 * * * rsync -a --delete --partial /home/<user>/Documents/ /backup/<hostname>/home/<user>/Documents/ >> /home/<user>/rsync-backup.log 2>&1
20 1 * * * rsync -a --delete --partial /home/<user>/Pictures/  /backup/<hostname>/home/<user>/Pictures/  >> /home/<user>/rsync-backup.log 2>&1
25 1 * * * rsync -a --delete --partial /home/<user>/Projects/  /backup/<hostname>/home/<user>/Projects/  >> /home/<user>/rsync-backup.log 2>&1
```

The template is in [`examples/rsync-documents.cron`](examples/rsync-documents.cron).
Start early enough that every copy finishes before the 02:00 snapshot. For a
whole home directory with exclusions:

```cron
0 1 * * * rsync -a --delete --partial --exclude='.cache/' --exclude='.local/share/Trash/' --exclude='Downloads/' /home/<user>/ /backup/<hostname>/home/<user>/ >> /home/<user>/rsync-backup.log 2>&1
```

Notes:

- The trailing `/` on the source copies its contents, not the directory itself.
- `--delete` makes the target a mirror. A typo in the source path can delete
  the backup tree; test with `rsync -an --delete ...` first. Local snapshots
  are the safety net.
- `-a` preserves permissions and timestamps. For root-owned files, use
  `sudo rsync` and make the target ownership match.
- Do not copy `/backup` into itself.

Verify the first copy before trusting it:

```bash
rsync -an --delete /home/<user>/Documents/ /backup/<hostname>/home/<user>/Documents/
find /backup/<hostname>/home/<user>/Documents -type f | wc -l
du -sh /backup/<hostname>/home/<user>/Documents
tail -n 20 /home/<user>/rsync-backup.log
```

## 7. Step 4 — Snapshots and local restores

### Install the snapshot script and timer

The repository ships the script; install it rather than retyping it:

```bash
sudo install -m 755 scripts/zfs-snapshot.sh /usr/local/sbin/
sudo install -m 644 systemd/zfs-snapshot.service systemd/zfs-snapshot.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now zfs-snapshot.timer
```

Defaults match this guide (`DS=tank/backup`, daily 14, weekly 8, monthly 12,
yearly 3). To change datasets or retention, install
`examples/zfs-backup.conf` as `/etc/zfs-backup.conf` and edit it. The script
runs as root, uses `/usr/sbin/zfs`, and refuses to run otherwise.

| Kind | Created | Kept |
|---|---|---|
| daily | 02:00 every day | 14 |
| weekly | Sundays 02:00 | 8 |
| monthly | 1st of the month, 02:00 | 12 |
| yearly | January 1, 02:00 | 3 |

`zfs-snapshot.timer` uses `Persistent=true`, so a missed run after downtime is
executed once. Schedule the rsync copies before 02:00 (Step 3).

### Browse and restore a single file

```bash
sudo zfs set snapdir=visible tank/backup   # idempotent
ls /backup/.zfs/snapshot/                  # all snapshots, read-only
sudo zfs diff tank/backup@daily-2026-10-03 tank/backup@daily-2026-10-04   # example dates
```

Restoring to the **live volume** (the mirror) is useful when the source copy
was damaged but the backup copy is intact:

```bash
# dry run, then execute
rsync -an "/backup/<hostname>/home/<user>/Documents/<file>" "/home/<user>/Documents/"
rsync -a  "/backup/<hostname>/home/<user>/Documents/<file>" "/home/<user>/Documents/"

# whole directory
rsync -an "/backup/<hostname>/home/<user>/Documents/" "/home/<user>/Documents/"
rsync -a  "/backup/<hostname>/home/<user>/Documents/" "/home/<user>/Documents/"
```

Restoring an **older version** from a local snapshot:

```bash
sudo cp -a "/backup/.zfs/snapshot/daily-YYYY-MM-DD/<hostname>/home/<user>/Documents/<file>" /tmp/
sha256sum "/tmp/<file>"
rsync -an /tmp/<file> "/home/<user>/Documents/"
rsync -a  /tmp/<file> "/home/<user>/Documents/"
```

If `snapdir` is hidden, clone the snapshot instead (this also works when it is
visible):

```bash
sudo zfs get keystatus tank/backup
# if keystatus is "unavailable":
sudo zfs load-key -L file:///etc/zfs/zfs.key tank/backup

sudo zfs clone -o mountpoint=/tank/restore \
  tank/backup@daily-YYYY-MM-DD tank/restore

ls -l "/tank/restore/<hostname>/home/<user>/Documents/"
sudo cp -a "/tank/restore/<hostname>/home/<user>/Documents/<file>" /tmp/

sudo zfs unmount tank/restore
sudo zfs destroy tank/restore
```

The clone is independent: destroying it does not delete the snapshot. Snapshot
content is read-only; `cp -a` preserves ownership and timestamps. For a whole
directory, point `rsync -a` at the snapshot or clone path. Verify with
`sha256sum` for a file or `diff -r` for a directory.

**Never `zfs rollback` for one file.** It reverts the whole dataset and
discards current contents. With newer snapshots present, `zfs rollback` even
refuses to run unless you pass `-r`, which destroys those newer snapshots.
Use clone-and-copy instead; rollback is only for replacing the whole volume
while accepting the loss of newer data.

Local snapshots do not survive loss of the pool/dataset. Offsite granularity
is one weekly state; see Step 7.

## 8. Step 5 — Offsite B2 replication

### A. Backblaze setup

1. In the Backblaze console, **Buckets -> Create a Bucket**. Use a unique name,
   for example `zfs-backup`, and keep it **Private**.
2. **Application Keys -> Add a New Application Key**. Name it for the host,
   restrict it to the `zfs-backup` bucket, and grant **Read and Write**
   (list/read/write/delete on files; the upload script needs delete to clear
   an expired chain). Enable **List All Bucket Names** only if you want
   `rclone lsd b2:` to work;
   without it, list the bucket directly with `rclone lsd b2:zfs-backup`.
3. Save **keyID** and **applicationKey** in a password manager. The secret is
   shown once. Never put either in this repository.
4. If you enable bucket versioning, add a lifecycle rule that keeps only the
   most recent version; otherwise overwritten `base.zfs` versions accumulate
   storage charges. With versioning off (default), the script's own base/delta
   chain is the history.

### B. Configure rclone as root

The backup runs from systemd as root, so the remote must live in root's rclone
config:

```bash
sudo rclone config create b2 b2 \
  account '<KEY_ID>' \
  key '<APPLICATION_KEY>'

sudo chmod 600 /root/.config/rclone/rclone.conf
sudo rclone lsd b2:zfs-backup        # empty for a new bucket
```

If you get `401 Unauthorized`, the key ID/key is wrong, the key is revoked, or
the bucket is outside the key's scope. A bucket-scoped key does not
necessarily have permission to list all buckets; `b2:zfs-backup` is the safe
target.

### C. Install the upload script, seed the chain, and enable the timer

```bash
sudo install -m 755 scripts/zfs-b2-upload.sh /usr/local/sbin/
sudo install -m 644 systemd/zfs-b2-upload.service systemd/zfs-b2-upload.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

Before the first upload, ensure a weekly snapshot exists. On a fresh install
you may not have one until Sunday:

```bash
sudo /usr/local/sbin/zfs-snapshot.sh
sudo zfs list -t snapshot -o name tank/backup | grep '@weekly-' \
  || sudo zfs snapshot "tank/backup@weekly-$(date +%F)"
```

Seed the chain and verify it before enabling the timer:

```bash
sudo /usr/local/sbin/zfs-b2-upload.sh --dry-run
sudo /usr/local/sbin/zfs-b2-upload.sh      # full base on the first run
sudo rclone lsl b2:zfs-backup
```

Expected: `uploaded N bytes to b2:zfs-backup/base.zfs (verified)` and `OK`.

The upload timer runs Mondays at 03:00 with `Persistent=true`, after the
Sunday weekly snapshot. The service orders itself after `zfs-snapshot.service`
and `network-online.target`. Enable it once the first upload succeeded:

```bash
sudo systemctl enable --now zfs-b2-upload.timer
```

### D. What the upload script does

- Selects the latest `@weekly-` snapshot and compares it with
  `/var/lib/zfs-backup/.base_snap` (the last uploaded snapshot).
- First run (or no valid state): sends a full `base.zfs`.
- Otherwise sends `deltas/YYYY-MM-DD.zfs` with `zfs send -w -i <previous>`.
- Verifies the uploaded object size against the bytes sent.
- **Caps the chain safely:** when `KEEP_DELTAS` increments already exist, it
  sends a fresh full `base.zfs`, then deletes the old delta chain. It never
  prunes individual deltas, because every increment requires all earlier
  objects. If deleting the old chain fails, it exits non-zero so the mismatch
  is visible.
- Modes: `--dry-run` prints the planned send; `--drill` restores the latest
  chain to a scratch dataset, decrypts, mounts, compares manifests, and
  cleans up.

Optional configuration (`/etc/zfs-backup.conf`; defaults shown):

| Variable | Default | Purpose |
|---|---|---|
| `DS` | `tank/backup` | dataset to send |
| `SRC_MOUNT` | `/backup` | live mount used by the drill comparison |
| `REMOTE` | `b2:zfs-backup` | rclone destination |
| `STATE_DIR` | `/var/lib/zfs-backup` | upload state (`.base_snap`) |
| `KEYFILE` | `/etc/zfs/zfs.key` | key used by `--drill` |
| `KEEP_DELTAS` | `8` | deltas before a fresh full base |
| `DAILY_KEEP` | `14` | daily snapshot retention |
| `WEEKLY_KEEP` | `8` | weekly snapshot retention |
| `MONTHLY_KEEP` | `12` | monthly snapshot retention |
| `YEARLY_KEEP` | `3` | yearly snapshot retention |
| `DRILL_DS` | `tank/drill` | scratch dataset for `--drill` |
| `DRILL_MOUNT` | `/tank/drill` | scratch mountpoint for `--drill` |

```bash
sudo install -m 644 examples/zfs-backup.conf /etc/zfs-backup.conf
```

### E. What lives in B2

```
b2:zfs-backup/
  base.zfs                  full raw send of a weekly snapshot
  deltas/YYYY-MM-DD.zfs     incremental raw sends, applied in filename order
```

- Only the **weekly** chain is offsite. `daily-*`, `monthly-*`, and `yearly-*`
  snapshots are local-only.
- Every object is ciphertext (`-w`); B2 cannot read it.
- A chain holds one base plus at most `KEEP_DELTAS` deltas. When the cap is
  reached, the next upload replaces the base and clears the chain.
- Never delete or rename objects in an active chain by hand; each delta
  requires the base and every earlier delta.

A base refresh replaces `base.zfs` and then deletes the old `deltas/`. Do not
start a restore while the Monday upload is doing this: between those two steps
the new base and the old deltas are inconsistent. If the base upload fails
before replacement, the old chain remains valid; if replacement succeeds but
deleting the old deltas fails, the script exits non-zero and tells you to
remove them.

`rclone lsl` can exit 0 with empty output for a missing object, and its object
name is the last field. The upload script checks for non-empty output and uses
`$NF`; if you reimplement it, do the same.

### F. Why weekly, not daily?

The upload script deliberately selects `@weekly-` snapshots. B2 is the
disaster copy: a one-week RPO is acceptable when local snapshots provide
instant daily recovery. Cost is dominated by the base object (one full stream
per dataset), and a weekly chain keeps ordering and chain management simple.
Mixing daily/weekly/monthly into one object namespace would break linear
replay. If you need daily offsite, give `daily-*` its own base/prefix or a
second remote rather than reusing `base.zfs`.

## 9. Step 6 — Restore drills

```bash
sudo /usr/local/sbin/zfs-b2-upload.sh --dry-run   # show the planned send
sudo /usr/local/sbin/zfs-b2-upload.sh --drill     # real restore test
```

The drill downloads the chain, receives it into `DRILL_DS`, loads the key,
mounts it, compares the file manifest against `SRC_MOUNT`, and destroys the
scratch dataset. Success ends with `DRILL OK`; failure ends with
`DRILL FAILED`.

What it proves:

- chain completeness and ordering;
- stream integrity (ZFS receive verifies checksums) and decryptability;
- mountability and that the manifest matches the live volume.

What it does **not** prove:

- The manifest compares file names and sizes, not content hashes. A same-size
  content change passes. Hash individual files when content matters.
- It compares the restored weekly state with the **current** `/backup`. If
  rsync added, removed, or resized files after the uploaded snapshot, counts
  can differ and the drill reports failure even though the offsite copy is
  intact. For a strict check, run the drill immediately after an upload,
  before the next 01:15 rsync, or verify specific files by hash.

Run the drill monthly, after any pipeline change, and after modifying the
scripts or units. B2 egress is free up to 3x your average stored data volume
(monthly), so a monthly drill is cheap.

## 10. Step 7 — Disaster recovery

Use this when the original host is gone. You need the B2 application key, the
ZFS dataset key (byte-exact, with its recorded SHA-256), the bucket name, and a
machine with enough storage. Step 8 covers rebuilding only the pool/dataset.

```bash
# 1. Install ZFS and rclone on the recovery host.
sudo dnf install -y https://zfsonlinux.org/fedora/zfs-release-3-1$(rpm --eval "%{dist}").noarch.rpm
sudo dnf install -y zfs rclone && sudo modprobe zfs

# 2. Restore the dataset key from an offline copy and verify it.
sudo install -d -m 755 /etc/zfs
sudo install -m 400 -o root -g root /path/to/zfs.key /etc/zfs/zfs.key
sudo sha256sum /etc/zfs/zfs.key        # must equal the recorded hash

# 3. Restore B2 access.
sudo rclone config create b2 b2 account '<KEY_ID>' key '<APPLICATION_KEY>'
sudo chmod 600 /root/.config/rclone/rclone.conf
sudo rclone lsd b2:zfs-backup

# 4. Create the pool (geometry/name may differ; receiving remaps the dataset).
#    See Step 1 for details; this wipes the named vdevs.
sudo zpool create -o ashift=12 tank raidz1 \
  /dev/disk/by-id/<disk1> /dev/disk/by-id/<disk2> \
  /dev/disk/by-id/<disk3> /dev/disk/by-id/<disk4>

# 5. Receive base + deltas in chronological order.
sudo rclone cat b2:zfs-backup/base.zfs \
  | sudo zfs receive -u -o mountpoint=/backup tank/backup
for d in $(sudo rclone lsl b2:zfs-backup/deltas/ | awk '{print $NF}' | sort); do
  sudo rclone cat "b2:zfs-backup/deltas/$d" | sudo zfs receive tank/backup
done

# 6. Decrypt, mount, make snapshots browsable.
sudo zfs load-key -L file:///etc/zfs/zfs.key tank/backup
sudo zfs mount tank/backup
sudo zfs set snapdir=visible tank/backup

# 7. Verify.
sudo zfs get keystatus,mountpoint tank/backup
sudo zfs list -t snapshot tank/backup
sudo zpool scrub tank

# 8. Reinstall scripts/units, seed the chain state, then enable the timers.
sudo install -m 755 scripts/zfs-snapshot.sh scripts/zfs-b2-upload.sh /usr/local/sbin/
sudo install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo install -d -m 755 /var/lib/zfs-backup
sudo zfs list -H -o name -t snapshot tank/backup | grep '@weekly-' | sort -r | head -1 \
  | sudo tee /var/lib/zfs-backup/.base_snap >/dev/null
sudo systemctl enable --now zfs-snapshot.timer zfs-b2-upload.timer

# 9. Copy the restored data back into the user's home.
sudo rsync -a /backup/<hostname>/home/<user>/Documents/ /home/<user>/Documents/

# 10. Re-prove the chain.
sudo /usr/local/sbin/zfs-b2-upload.sh --drill
```

Notes:

- If the pool is not named `tank`, either create it as `tank` or set `DS`,
  `SRC_MOUNT`, `DRILL_DS`, and `DRILL_MOUNT` in `/etc/zfs-backup.conf` before
  running the scripts. Receiving into `<pool>/backup` works, but the scripts'
  defaults point at `tank/backup`.
- To force a fresh full base after recovery, remove
  `/var/lib/zfs-backup/.base_snap`; otherwise keeping the seeded state
  continues the existing chain.
- The restored chain reproduces every `weekly-*` snapshot it contains.
  `daily-*`, `monthly-*`, and `yearly-*` are local-only and are not
  reconstructed.
- After a disaster you have weekly granularity, not daily. Daily history exists
  only on the lost host's local snapshots.

### Single file from B2 (older than local retention)

Receiving materializes the whole volume state; there is no partial extraction
from a stream. Scratch space must be about the size of the dataset.

```bash
sudo rclone cat b2:zfs-backup/base.zfs \
  | sudo zfs receive -u -o mountpoint=/tank/recover tank/recover
for d in $(sudo rclone lsl b2:zfs-backup/deltas/ | awk '{print $NF}' | sort); do
  sudo rclone cat "b2:zfs-backup/deltas/$d" | sudo zfs receive tank/recover
done
sudo zfs load-key -L file:///etc/zfs/zfs.key tank/recover
sudo zfs mount tank/recover

# Copy to the original location, not just within /backup.
sudo cp -a "/tank/recover/<hostname>/home/<user>/Documents/<file>" /tmp/
sudo rsync -a /tmp/<file> "/home/<user>/Documents/"

sudo zfs unmount tank/recover
sudo zfs destroy -r tank/recover
```

For everyday single files, use the local snapshots in Step 4: no download and
no scratch space.

## 11. Step 8 — Rebuild the local volume

Use this when the pool or dataset is lost/damaged, or when moving the volume to
new disks. It rebuilds the local container; data comes from B2 (Step 7) or from
the original files.

### A. Try importing first

```bash
sudo zpool import -d /dev/disk/by-id          # list importable pools
sudo zpool import -d /dev/disk/by-id tank     # import by name
sudo zpool status -x
```

If the pool imports `DEGRADED`, replace the failed disk and let it resilver
before rebuilding. Record the old layout with `zpool status` and identify disks
by `/dev/disk/by-id/...`, not transient `/dev/sdX` names.

### B. Choose the key

- **Old key** — required to read the existing B2 chain. Raw streams cannot be
  decrypted with a different key.
- **New key** — only for starting a fresh chain and abandoning the old offsite
  objects. Old objects become unreadable.

Restore the old key from an offline copy (verify against the recorded
SHA-256), or generate a new one:

```bash
sudo install -d -m 755 /etc/zfs

# old key:
sudo install -m 400 -o root -g root /path/to/zfs.key /etc/zfs/zfs.key

# OR new key (fresh chain only):
sudo dd if=/dev/urandom of=/etc/zfs/zfs.key bs=32 count=1 status=none
sudo chmod 400 /etc/zfs/zfs.key

sudo wc -c /etc/zfs/zfs.key          # must be 32
```

If the key is lost and no copy exists, the old dataset and offsite chain are
unrecoverable.

### C. Recreate the pool, then the dataset

Create the pool as in Step 1. Then choose a path:

**A. Recover the existing offsite chain (old key).** Do **not** pre-create
`tank/backup`; receive the base into it and apply deltas in order. Follow
Step 7 steps 5-7. Keep `/var/lib/zfs-backup/.base_snap` if it names a snapshot
that the restored chain contains; remove it to force a fresh full base.

**B. Start empty (old or new key).**

```bash
sudo zfs create -o encryption=aes-256-gcm \
  -o keyformat=raw \
  -o keylocation=file:///etc/zfs/zfs.key \
  -o compression=zstd \
  -o atime=off \
  -o snapdir=visible \
  -o mountpoint=/backup \
  tank/backup

sudo zfs get encryption,keyformat,keylocation,keystatus tank/backup
sudo rm -f /var/lib/zfs-backup/.base_snap   # force a fresh base
```

The first upload overwrites `base.zfs` and deletes the old delta chain. If the
old chain must be preserved, point `REMOTE` at a different bucket/path before
uploading.

### D. Repopulate from the original files (empty-volume path)

```bash
USER_NAME="$(id -un)"
HOST_NAME="$(hostname -s)"

sudo install -d -o "$USER_NAME" -g "$USER_NAME" \
  "/backup/$HOST_NAME/home/$USER_NAME/Documents"

rsync -a "/home/$USER_NAME/Documents/" \
  "/backup/$HOST_NAME/home/$USER_NAME/Documents/"
```

Repeat for other critical paths (Step 3). If you restored from B2, skip this
step.

### E. Resume snapshots and uploads

```bash
sudo install -m 755 scripts/zfs-snapshot.sh scripts/zfs-b2-upload.sh /usr/local/sbin/
sudo install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload

sudo /usr/local/sbin/zfs-snapshot.sh
sudo zfs list -t snapshot -o name tank/backup | grep '@weekly-' \
  || sudo zfs snapshot "tank/backup@weekly-$(date +%F)"

sudo /usr/local/sbin/zfs-b2-upload.sh --dry-run
sudo /usr/local/sbin/zfs-b2-upload.sh
sudo /usr/local/sbin/zfs-b2-upload.sh --drill

# Enable the timers only after the first upload and drill succeed.
sudo systemctl enable --now zfs-snapshot.timer zfs-b2-upload.timer
```

### F. Rebuild only the dataset (pool intact)

If the pool is healthy and only `tank/backup` is damaged, destroy and recreate
the dataset. **This deletes every local snapshot.**

```bash
sudo zfs unmount tank/backup
sudo zfs destroy tank/backup
```

Then follow C-E. If the old offsite chain matters, restore it with path A
instead of starting empty; do not create `tank/backup` first.

### G. Post-rebuild checks

- `sudo zpool status -x` reports `all pools are healthy`.
- `sudo zfs get keystatus tank/backup` reports `available`.
- `/backup` is mounted and contains the expected host/user trees.
- `sudo /usr/local/sbin/zfs-b2-upload.sh --drill` prints `DRILL OK`.
- `systemctl list-timers 'zfs-*'` shows both timers scheduled.
- A copy of `/etc/zfs/zfs.key` exists in the password manager and on an
  offline medium, with its SHA-256 recorded.

## 12. Maintenance

```bash
sudo systemctl enable --now zfs-scrub-weekly@tank.timer     # shipped scrub timer
sudo systemctl enable --now zfs-trim-weekly@tank.timer      # NVMe TRIM
sudo zpool status -x                                        # health; all healthy
sudo zpool scrub tank                                       # manual scrub
sudo zfs list -t snapshot                                   # retention state
sudo nvme smart-log -H /dev/nvme0n1                         # drive health (all disks)
systemctl list-timers 'zfs-*' --no-pager
```

Scrub verifies all checksums and self-heals from parity when possible. TRIM
keeps NVMe performance. Alert on `zpool status` not being `ONLINE` and on
failed `zfs-b2-upload.service`/`zfs-snapshot.service` units; a simple
`systemd` OnFailure unit or external monitoring works.

## 13. Key custody and FAQ

**Key format:** exactly 32 raw random bytes, mode 0400 root. No header, no
text, no passphrase — the file content is the wrapping key. (Human-memorable
alternative: `keyformat=passphrase` + `keylocation=prompt` or a keyfile;
prompts at boot unless stored in a file.)

**Key deleted?** The current session is unaffected because the key is cached in
the kernel. After reboot the `zfs-load-key@` unit fails, `/backup` does not
mount, and boot itself is fine. Restore the byte-identical file (verify
SHA-256). Different bytes mean permanently unreadable data. Keep at least two
offsite copies.

**Is local restoration encrypted-but-recoverable?** Yes: `zfs load-key` (from
the keyfile or prompt) plus `zfs mount`. `zfs change-key` can rewrap the DEK to
a new key without re-encrypting data.

**What happens on reboot with a keyfile?** Fully unattended: systemd import ->
`zfs-load-key@` reads the keyfile -> mount. No password is stored anywhere
except the root-only keyfile.

**What must survive a disaster?** The offsite key copy and its SHA-256, the B2
application key, and the bucket name. Everything else is rebuildable.

**Provider notes (verify current pricing):**

| Provider | ~$/TB-month | Restore egress |
|---|---|---|
| Backblaze B2 | ~$6.95 | free up to 3x storage, then per-GB |
| Wasabi | ~$7.99 | $0 |
| AWS S3 Glacier Deep Archive | ~$0.99 | per-GB + retrieval (minutes-days) |
| GCS Coldline/Archive | ~$4 / ~$1.20 | per-GB + retrieval |

## 14. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| Drill succeeds with 0 files, or snapshots are empty | Step 3 was skipped; rsync never populated `/backup`. Copy data in, snapshot, upload. |
| `rsync: permission denied` writing `/backup/...` | Target subdirectory not owned by the cron user; rerun the `install -d -o ...` commands. |
| `--delete` removed files from the mirror | Source path typo or an intentional deletion; restore from a local snapshot (Step 4). |
| `ERROR: no @weekly- snapshot found` | No weekly snapshot yet; run the snapshot script on Sunday or create one manually (§8C). |
| `ERROR: b2:zfs-backup/base.zfs not found` | Wrong bucket/remote or empty bucket; check `rclone lsl b2:zfs-backup`. |
| `401 Unauthorized` from rclone | Key revoked/wrong or bucket outside the key scope. A bucket-scoped key may lack `listBuckets`; use `rclone lsl b2:zfs-backup`, or enable List All Bucket Names. |
| `cannot load key ... Incorrect key provided` | Wrong dataset key; restore the matching `/etc/zfs/zfs.key`. |
| Clone mount fails / `keystatus=unavailable` | Load the key first: `zfs load-key -L file:///etc/zfs/zfs.key tank/backup`. |
| `zfs rollback` says more recent snapshots exist | Use clone-and-copy for a single file; `-r` would destroy the newer snapshots. |
| `cannot receive incremental stream: most recent snapshot ... does not match` | A delta was skipped or applied out of order. Destroy the scratch dataset and replay from `base.zfs` in filename order. |
| `ERROR: new base uploaded but old deltas remain` | The new base is valid but stale deltas would break restores; delete `b2:zfs-backup/deltas/` manually, then re-drill. |
| `size mismatch: sent N, remote M` | Upload truncated; re-run the upload (base is overwritten, delta is re-sent). |
| `destination exists` / `filesystem already exists` | Target dataset exists; destroy the scratch/target dataset first (`zfs destroy -r`). |
| No `zfs-load-key@` or `backup.mount` units | `/etc/zfs/zfs-list.cache/tank` is missing; see the zed cache fix in §5C. |
| `systemctl daemon-reload` unmounts `/backup` | Expected: systemd owns the generated mount units; use `systemctl` for mounts. |
| `rclone lsl` parsed with `$2` gives receive failures | The object name is the **last** field (`$NF`); the script already does this. |
| Drill reports different file counts | Live `/backup` changed after the weekly snapshot; run the drill right after an upload or hash-check specific files. |
| `zpool status` shows DEGRADED | Replace the failed disk and wait for resilver; scrub the pool and re-check. |
| `zfs receive` says `failed to read from stream` | Wrong object path/order or corrupt download; re-fetch from `base.zfs` and replay deltas in order. |

---

*Validated end-to-end: pool -> encryption -> rsync ingestion -> snapshots ->
B2 chain (full + incremental, safe base refresh) -> drill with content
manifest -> local restore, disaster recovery, and local rebuild. All scripts
are generic; the only secrets in your deployment are the keyfile and the B2
credentials, both outside this repository.*
