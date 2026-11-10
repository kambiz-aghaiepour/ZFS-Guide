# Reconstruction Runbook and Offsite Vault Inventory

Operational companion to the [main guide](../README.md). Use this when the
backup host, pool, or dataset is lost, when moving the volume to new disks, or
when proving that the offsite material is sufficient to recover.

It covers:

- what must be kept in an offsite, encrypted vault;
- how to verify that material before a disaster;
- full reconstruction from B2, dataset-only rebuild, and fresh-volume setup;
- single-file recovery and a clean-room vault test;
- the mistakes that turn a recoverable backup into an unrecoverable one.

This file contains no secrets. Use placeholders (`<KEY_ID>`,
`<APPLICATION_KEY>`, `<hostname>`, `<user>`, `<pool>`) and keep the actual
values in the vault.

---

## 1. Offsite vault inventory

### Minimum kit to restore data

1. `/etc/zfs/zfs.key` — byte-exact, 32 raw bytes.
2. SHA-256 of `zfs.key` — to verify the restored key.
3. B2 **keyID** and **applicationKey**.
4. Bucket name, remote name, and object path (`b2:zfs-backup`).
5. A minimal rclone `[b2]` stanza, or the exact `rclone config create` command.
6. The reconstruction procedure (this repository, or an offline copy).

### Additional material for full account and host recovery

7. Backblaze account email/password and 2FA recovery codes.
8. Password-manager master password, emergency kit, and 2FA recovery codes
   (without these, the vault itself is inaccessible).
9. Pool layout, dataset properties, OS/OpenZFS/rclone versions, and disk
   identifiers.
10. Host credentials (SSH/GPG keys, service accounts) if "full DR" includes
    rebuilding the host, not only the backup volume.
11. A billing/account note; an expired payment method can put the bucket at
    risk even when the data and keys are intact.

| Material | Form | Why | Secret |
|---|---|---|---|
| `zfs.key` | byte-exact file attachment | decrypts raw B2 streams; wrong bytes are unrecoverable | **yes** |
| `zfs.key` SHA-256 | text | verify the restored key | no |
| B2 keyID | text | rclone `account` value | semi |
| B2 applicationKey | text/secret | rclone `key` value; bucket read/write/delete | **yes** |
| Bucket/remote/path | text | reconstruct the remote | no |
| Backblaze account login + 2FA recovery | text | create/rotate an app key, manage bucket/billing | **yes** |
| Vault master password / emergency kit + 2FA recovery | offline | open the vault after a host loss | **yes** |
| Minimal `[b2]` rclone stanza | text | convenience; the two values above are the real assets | contains secret |
| Repo URL + commit, or offline README/scripts | text/archive | exact, tested procedure | no |
| Pool/dataset export + versions | text | rebuild the same layout/properties | mostly no |
| Host SSH/GPG keys | text/archive | full host rebuild | **yes** |

### How to store the key

- Prefer a **file attachment** so the bytes are not reformatted.
- If the vault is text-only, store base64 plus the SHA-256 and the exact decode
  command:
  ```bash
  base64 -d zfs.key.b64 > /tmp/zfs.key
  sudo install -m 400 -o root -g root /tmp/zfs.key /etc/zfs/zfs.key
  rm -f /tmp/zfs.key
  sudo wc -c /etc/zfs/zfs.key          # must be 32
  sudo sha256sum /etc/zfs/zfs.key      # must match the vault
  ```
- Never rely on a copy inside the vault's own backup that can only be opened
  with a recovery key stored in that same vault.

### What not to store where

- Do not commit keys, rclone configs, or account recovery codes to git.
- Do not store the only B2 credentials inside `tank/backup` or the B2 bucket
  itself; that is circular for bootstrap.
- Do not include unrelated remotes (OAuth tokens for other services) in the
  DR kit. A minimal `[b2]` stanza is safer than a full `rclone.conf`.
- Do not keep the only copy of the vault emergency kit inside the vault.

### Trust separation

Keeping `zfs.key` and the B2 credentials in the same vault is convenient but
means one vault compromise yields both the ciphertext and the decryption key.
For higher assurance, split them across two vaults or access-controlled
locations, and make sure both are reachable during a disaster. At minimum use a
strong master password, 2FA, an offline emergency kit, and audit access.

### Rotation

- **B2 application key:** create a new bucket-scoped key, update root's
  `/root/.config/rclone/rclone.conf`, verify `rclone lsd b2:zfs-backup`, then
  revoke the old key. No data re-encryption is needed.
- **ZFS dataset key:** existing raw B2 streams remain encrypted with the key
  that produced them. Changing the dataset key does **not** re-encrypt the old
  chain. Keep the old key until a new full `base.zfs` has been uploaded with the
  new key and verified; update the vault only after that.
- Update the vault immediately after any rotation, and record the date.

---

## 2. Decision tree

```
Is the original host available?
├─ no  -> build a recovery host, install OpenZFS + rclone, continue below
└─ yes -> continue below

Can the existing pool be imported?
├─ yes -> does tank/backup exist and open with the key?
│         ├─ yes -> restore files from the live volume/snapshots, resume automation
│         └─ no  -> dataset-only rebuild (README Step 8F)
└─ no  -> create the pool

After the pool exists:
├─ recover the existing B2 chain (old key, base + deltas)
└─ start a fresh encrypted dataset (repopulate, new full base)
```

Do not run `zpool create` before checking `zpool import`; it destroys the
existing pool labels on the named devices.

---

## 3. Prerequisites

- Linux with systemd; root access.
- OpenZFS 2.x with raw encrypted-send support.
- rclone.
- Network access to Backblaze B2.
- Storage for the pool; for a single-file B2 restore, scratch space roughly
  equal to the dataset size.
- The vault material from §1.
- The scripts and units from this repository (or an offline checkout).

The detailed install and pool commands are in the main guide:
[Step 0](../README.md#3-step-0--install-openzfs),
[Step 1](../README.md#4-step-1--create-the-pool), and
[Step 2](../README.md#5-step-2--encryption-and-the-dataset).

---

## 4. Full reconstruction from zero

### 4.1 Restore and verify the dataset key

```bash
sudo install -d -m 755 /etc/zfs
sudo install -m 400 -o root -g root /path/to/zfs.key /etc/zfs/zfs.key
sudo wc -c /etc/zfs/zfs.key          # must be 32
sudo sha256sum /etc/zfs/zfs.key      # compare with the vault record
```

If the hash does not match, stop. Different bytes cannot decrypt the old
streams.

### 4.2 Restore B2 access

Prefer the minimal stanza:

```ini
[b2]
type = b2
account = <KEY_ID>
key = <APPLICATION_KEY>
```

```bash
sudo install -d -m 700 /root/.config/rclone
sudo install -m 600 -o root -g root /path/to/rclone.conf /root/.config/rclone/rclone.conf
sudo rclone lsd b2:zfs-backup
```

Or create the remote directly:

```bash
sudo rclone config create b2 b2 account '<KEY_ID>' key '<APPLICATION_KEY>'
sudo chmod 600 /root/.config/rclone/rclone.conf
sudo rclone lsd b2:zfs-backup
```

- The systemd units run as root, so the remote must be in root's config.
- A bucket-scoped key may not have `listBuckets`; `rclone lsd b2:zfs-backup`
  is the safe check, not `rclone lsd b2:`.
- If the config was stored with rclone config encryption, supply its password
  through the same mechanism used on the original host and keep that password
  in the vault too.

### 4.3 Try importing an existing pool first

```bash
sudo zpool import -d /dev/disk/by-id          # list importable pools
sudo zpool import -d /dev/disk/by-id <pool>   # import by name
sudo zpool status -x
```

If the pool imports `DEGRADED`, replace the failed disk and let it resilver
before continuing. If it imports healthy and `tank/backup` is present and
decryptable, you may not need to receive the B2 chain at all: verify the
dataset, restore files, and resume automation.

### 4.4 Create the pool if it cannot be imported

Follow [Step 1](../README.md#4-step-1--create-the-pool). Use stable
`/dev/disk/by-id/...` names and the vdev layout recorded in the vault. This
wipes the named devices; confirm they are the intended disks.

### 4.5 Receive the encrypted chain

Do **not** pre-create `tank/backup`; `zfs receive` creates it. If a previous
receive attempt left a partial target, destroy it explicitly before starting
again:

```bash
# Only if this is a failed/partial receive target, not a good local dataset:
# sudo zfs destroy -r tank/backup

sudo rclone cat b2:zfs-backup/base.zfs \
  | sudo zfs receive -u -o mountpoint=/backup tank/backup

for d in $(sudo rclone lsl b2:zfs-backup/deltas/ | awk '{print $NF}' | sort); do
  sudo rclone cat "b2:zfs-backup/deltas/$d" | sudo zfs receive tank/backup
done

sudo zfs load-key -L file:///etc/zfs/zfs.key tank/backup
sudo zfs mount tank/backup
sudo zfs set snapdir=visible tank/backup
```

- Apply every delta in filename order. Skipping one breaks the chain.
- If a delta fails, destroy the partial target and replay from `base.zfs`; do
  not resume by skipping the failed object.
- If the pool is not named `tank`, receive into `<pool>/backup` and set `DS`,
  `SRC_MOUNT`, `DRILL_DS`, and `DRILL_MOUNT` in `/etc/zfs-backup.conf`.
- A received raw stream creates its own encryption root; the restored dataset
  does not depend on the original pool name, but it still requires the same
  dataset key.

### 4.6 Verify before restoring data

```bash
sudo zfs get keystatus,mountpoint,encryption,compression tank/backup
sudo zfs list -t snapshot tank/backup
sudo zpool scrub <pool>
sudo find /backup -xdev -type f | wc -l
```

- `keystatus` must be `available`.
- The weekly snapshots carried by the chain should be present.
- Hash at least one known file against the source or the vault's recorded
  expectation.
- After installing the scripts, run `--drill` to re-prove the chain.

The chain reconstructs the weekly snapshots it contains. `daily-*`,
`monthly-*`, and `yearly-*` snapshots are local-only and are **not**
reconstructed.

### 4.7 Copy data back to the original locations

Restoring from `/backup` into `/home` is a separate step from receiving the
chain:

```bash
# dry run first
rsync -an "/backup/<hostname>/home/<user>/Documents/" "/home/<user>/Documents/"
rsync -a  "/backup/<hostname>/home/<user>/Documents/" "/home/<user>/Documents/"
```

If the host already contains newer data, restore into a staging directory
first and merge deliberately rather than overwriting. `-a` preserves
permissions and timestamps; use `sudo rsync` for root-owned files and fix
ownership if needed.

### 4.8 Resume automation

Install the tested scripts and units from the repository root:

```bash
sudo install -m 755 scripts/zfs-snapshot.sh scripts/zfs-b2-upload.sh /usr/local/sbin/
sudo install -m 644 systemd/*.service systemd/*.timer /etc/systemd/system/
sudo systemctl daemon-reload
```

Seed the upload state with the newest restored weekly snapshot **before**
enabling the timers:

```bash
sudo install -d -m 755 /var/lib/zfs-backup
sudo zfs list -H -o name -t snapshot tank/backup | grep '@weekly-' | sort -r | head -1 \
  | sudo tee /var/lib/zfs-backup/.base_snap >/dev/null
```

Then create a snapshot, test, upload, drill, and enable the timers:

```bash
sudo /usr/local/sbin/zfs-snapshot.sh

sudo /usr/local/sbin/zfs-b2-upload.sh --dry-run
sudo /usr/local/sbin/zfs-b2-upload.sh
sudo /usr/local/sbin/zfs-b2-upload.sh --drill

sudo systemctl enable --now zfs-snapshot.timer zfs-b2-upload.timer
```

If the restored chain has no weekly snapshot, the state file is empty and the
next upload sends a fresh full base. To force a fresh base deliberately,
remove `/var/lib/zfs-backup/.base_snap`.

### 4.9 Final checks

- `sudo zpool status -x` reports `all pools are healthy`.
- `sudo zfs get keystatus tank/backup` reports `available`.
- `/backup` is mounted and contains the expected host/user trees.
- A known file hashes correctly.
- `--drill` prints `DRILL OK`.
- `systemctl list-timers 'zfs-*'` shows both timers.
- The vault copy of `zfs.key` and the B2 credentials are unchanged and
  verified.

---

## 5. Dataset-only reconstruction (pool intact)

If the pool is healthy and only `tank/backup` is damaged, destroy and recreate
the dataset. **This deletes every local snapshot.**

```bash
sudo zfs unmount tank/backup
sudo zfs destroy tank/backup
```

Then either receive the old B2 chain (§4.5) without pre-creating the dataset,
or create an empty encrypted dataset and repopulate it. Keep or remove
`.base_snap` accordingly: keep it if the restored chain contains the last
uploaded weekly snapshot; remove it to force a fresh full base. Finish with
§4.6–§4.8.

See also [README Step 8F](../README.md#f-rebuild-only-the-dataset-pool-intact).

---

## 6. Fresh volume or new chain

Use this when starting clean or deliberately abandoning the old chain.

1. Choose the key:
   - **Old key:** the new dataset can read old streams, but do not overwrite
     them unless intended.
   - **New key:** old B2 objects become unreadable. Preserve them by pointing
     `REMOTE` at a different bucket/path, or accept that the old chain is
     abandoned.
2. Create the encrypted dataset as in
   [Step 2](../README.md#5-step-2--encryption-and-the-dataset).
3. Remove stale state to force a full base:
   ```bash
   sudo rm -f /var/lib/zfs-backup/.base_snap
   ```
4. Repopulate from the original files (rsync) or restore from B2.
5. Run the first snapshot/upload and verify with `--dry-run` and `--drill`
   before enabling the timers.

The first upload replaces `base.zfs` and deletes the old delta chain. If the
old chain must be preserved, use a different `REMOTE` before uploading.

---

## 7. Single-file recovery

For a file older than local retention, receive the B2 chain into a scratch
dataset, decrypt, mount, copy the file to its original location, then clean up.
Scratch space must be about the size of the dataset; there is no partial
extraction from a stream.

See [README single-file from B2](../README.md#single-file-from-b2-older-than-local-retention)
for the commands, and
[Step 4](../README.md#7-step-4--snapshots-and-local-restores) for the faster
local snapshot path.

---

## 8. Clean-room test of the vault

A vault is not proven until it has recovered data without the original host.
Do this quarterly and after any credential/key change.

1. Use a spare VM, container, or host with no access to the original system.
2. Install rclone; restore the B2 stanza/credentials; run
   `rclone lsd b2:zfs-backup`.
3. Install OpenZFS; restore `zfs.key`; verify the 32-byte length and SHA-256.
4. Receive `base.zfs` plus at least one delta into a scratch dataset, load the
   key, mount it, and hash a known file. A full-chain drill is better.
5. Verify the password-manager emergency kit opens the vault on a separate
   device, and confirm the Backblaze account login/2FA recovery path.
6. Record the date, result, and any missing item in the vault; fix gaps
   immediately.

Do not test recovery by deleting production backups.

---

## 9. Common failure modes

| Symptom | Cause / fix |
|---|---|
| `cannot load key ... Incorrect key provided` | Wrong `zfs.key`; restore the byte-exact copy and verify SHA-256. |
| `zfs load-key` says the key is the wrong length | Key was truncated/reformatted; it must be exactly 32 raw bytes. |
| `rclone` returns `401 Unauthorized` | App key revoked/wrong, or the bucket is outside its scope. Use `rclone lsd b2:zfs-backup`. |
| `rclone lsd b2:` fails but the bucket works | Bucket-scoped key lacks `listBuckets`; list the bucket directly. |
| `cannot receive incremental stream ... does not match` | A delta was skipped/out of order, or the target is from a different chain. Destroy it and replay from `base.zfs` in filename order. |
| `destination exists` / `filesystem already exists` | `zfs receive` creates the dataset; do not pre-create it. Destroy the failed target first. |
| `ERROR: new base uploaded but old deltas remain` | Stale deltas would break restores. Delete `b2:zfs-backup/deltas/` manually, then re-drill. |
| Upload starts but the restored chain is invalid | A base refresh was interrupted between replacing `base.zfs` and deleting old deltas. Do not restore during the weekly upload window; clean up and re-upload. |
| Timers run before state is seeded | Seed `.base_snap` first, or remove it to force a known full base; enable timers last. |
| Restored dataset is not at `/backup` | Pool name or mountpoint differs; receive with `-o mountpoint=/backup` and set `DS`/`SRC_MOUNT` in `/etc/zfs-backup.conf`. |
| `rclone lsl` receive failures | Parse the last field (`$NF`), not the date field. |
| Restoring over newer home data | Restore to staging first and merge; `rsync --delete` can remove newer files. |
| Vault cannot be opened | Emergency kit/master password/2FA recovery is missing or stored only inside the vault. Fix the recovery path. |
| Vault compromise | Rotate the B2 app key immediately; rotate the ZFS key only after understanding old-stream compatibility (§1 Rotation). |
| B2 data unavailable | Check account status/billing, bucket existence, app-key scope, and versioning/lifecycle settings. |

---

## 10. References

- [Main guide](../README.md)
- [Step 2 — encryption and key custody](../README.md#5-step-2--encryption-and-the-dataset)
- [Step 4 — local restores](../README.md#7-step-4--snapshots-and-local-restores)
- [Step 7 — disaster recovery](../README.md#10-step-7--disaster-recovery)
- [Step 8 — rebuild the local volume](../README.md#11-step-8--rebuild-the-local-volume)
- [Key custody and FAQ](../README.md#13-key-custody-and-faq)
- [Snapshot script](../scripts/zfs-snapshot.sh)
- [B2 upload/drill script](../scripts/zfs-b2-upload.sh)
- [Optional config](../examples/zfs-backup.conf)
- [rsync cron template](../examples/rsync-documents.cron)
