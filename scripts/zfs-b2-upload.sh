#!/bin/bash
# Weekly encrypted (raw) zfs send of a backup dataset to Backblaze B2.
# Modes:
#   (default)   upload latest weekly snapshot (full base.zfs or incremental deltas/YYYY-MM-DD.zfs)
#   --dry-run   print what would be sent, don't touch anything
#   --drill     restore latest chain from B2 into a scratch dataset, decrypt, mount, verify, cleanup
#
# Optional overrides: /etc/zfs-backup.conf.
# Environment variables work too, but the config file wins.

set -euo pipefail

DS="${DS:-tank/backup}"
REMOTE="${REMOTE:-b2:zfs-backup}"
STATE_DIR="${STATE_DIR:-/var/lib/zfs-backup}"
KEEP_DELTAS="${KEEP_DELTAS:-8}"
KEYFILE="${KEYFILE:-/etc/zfs/zfs.key}"
SRC_MOUNT="${SRC_MOUNT:-/backup}"
DRILL_DS="${DRILL_DS:-tank/drill}"
DRILL_MOUNT="${DRILL_MOUNT:-/tank/drill}"

CONF="${ZFS_BACKUP_CONF:-/etc/zfs-backup.conf}"
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

usage() { echo "usage: $0 [--dry-run|--drill]" >&2; exit 2; }

MODE=upload
case "${1:-}" in
    "" ) ;;
    --dry-run ) MODE=dry-run ;;
    --drill ) MODE=drill ;;
    * ) usage ;;
esac
[ $# -gt 1 ] && usage

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# rclone lsl on a missing object exits 0 with empty output, so test output.
remote_exists() { [ -n "$(/usr/bin/rclone --quiet lsl "$1" 2>/dev/null)" ]; }

drill() {
    local RC=0
    echo "== DRILL: restoring latest chain from $REMOTE =="
    if /usr/sbin/zfs list -H -o name "$DRILL_DS" >/dev/null 2>&1; then
        /usr/sbin/zfs destroy -r "$DRILL_DS"
    fi
    if ! remote_exists "$REMOTE/base.zfs"; then
        echo "ERROR: $REMOTE/base.zfs not found - nothing to restore" >&2
        exit 2
    fi
    echo "[1/5] receiving base.zfs"
    /usr/bin/rclone --quiet cat "$REMOTE/base.zfs" \
        | /usr/sbin/zfs receive -u -o "mountpoint=$DRILL_MOUNT" "$DRILL_DS" || RC=1
    mapfile -t DELTAS < <(/usr/bin/rclone --quiet lsl "$REMOTE/deltas/" 2>/dev/null | awk '{print $NF}' | sort)
    echo "[2/5] receiving ${#DELTAS[@]} delta(s)"
    for d in "${DELTAS[@]}"; do
        /usr/bin/rclone --quiet cat "$REMOTE/deltas/$d" \
            | /usr/sbin/zfs receive "$DRILL_DS" || RC=1
    done
    if [ "$RC" = "0" ]; then
        echo "[3/5] loading key"
        /usr/sbin/zfs load-key -L "file://$KEYFILE" "$DRILL_DS" || RC=1
        echo "[4/5] mounting and comparing content manifest"
        /usr/sbin/zfs mount "$DRILL_DS" || RC=1
        local LIVE_MANIFEST REST_MANIFEST
        LIVE_MANIFEST="$(cd "$SRC_MOUNT" && find . -xdev -type f -printf '%P|%s\n' | sort)"
        REST_MANIFEST="$(cd "$DRILL_MOUNT" && find . -xdev -type f -printf '%P|%s\n' | sort)"
        echo "files: live=$(printf '%s' "$LIVE_MANIFEST" | grep -c . || true) restored=$(printf '%s' "$REST_MANIFEST" | grep -c . || true)"
        [ "$LIVE_MANIFEST" = "$REST_MANIFEST" ] || RC=1
    fi
    echo "[5/5] cleanup"
    /usr/sbin/zfs unmount "$DRILL_DS" 2>/dev/null || true
    /usr/sbin/zfs destroy -r "$DRILL_DS" 2>/dev/null || true
    if [ "$RC" = "0" ]; then
        echo "DRILL OK"
    else
        echo "DRILL FAILED" >&2
    fi
    exit "$RC"
}

if [ "$MODE" = "drill" ]; then
    drill
fi

# Upload path: latest weekly snapshot (created by zfs-snapshot.sh on Sunday)
SNAP="$(/usr/sbin/zfs list -H -o name -t snapshot "$DS" | grep '@weekly-' | sort -r | head -n1 || true)"
if [ -z "$SNAP" ]; then
    echo "ERROR: no @weekly- snapshot found; create one with zfs-snapshot.sh on a Sunday or manually" >&2
    exit 2
fi

BASE_FILE="$STATE_DIR/.base_snap"
PREV=""
if [ -f "$BASE_FILE" ]; then
    PREV="$(cat "$BASE_FILE")"
    if ! /usr/sbin/zfs list -H -o name -t snapshot "$PREV" >/dev/null 2>&1; then
        echo "base snapshot $PREV no longer exists locally - doing full send"
        PREV=""
    fi
fi

if [ -n "$PREV" ] && [ "$PREV" = "$SNAP" ]; then
    echo "snapshot $SNAP already uploaded; nothing to do"
    exit 0
fi

# Never prune deltas from an active chain: every delta needs all earlier ones.
# Instead, cap the chain by sending a fresh full base once KEEP_DELTAS exist.
DELTA_COUNT=0
if [ -n "$PREV" ]; then
    DELTA_COUNT="$(/usr/bin/rclone --quiet lsl "$REMOTE/deltas/" 2>/dev/null | grep -c . || true)"
fi

if [ -n "$PREV" ] && [ "$DELTA_COUNT" -lt "$KEEP_DELTAS" ]; then
    OBJ="deltas/$(date +%F).zfs"
    SEND_ARGS=(-i "$PREV")
else
    OBJ="base.zfs"
    SEND_ARGS=()
fi

if [ "$MODE" = "dry-run" ]; then
    echo "DRY RUN: /usr/sbin/zfs send -w ${SEND_ARGS[*]} $SNAP | /usr/bin/rclone rcat $REMOTE/$OBJ"
    exit 0
fi

mkdir -p "$STATE_DIR"

echo "snapshot: $SNAP -> $REMOTE/$OBJ"
BYTES=$(/usr/sbin/zfs send -w "${SEND_ARGS[@]}" "$SNAP" \
    | tee >(/usr/bin/rclone --quiet rcat "$REMOTE/$OBJ") \
    | wc -c)
R_SIZE=$(/usr/bin/rclone --quiet lsl "$REMOTE/$OBJ" | awk '{print $1}')
if [ "${R_SIZE:-}" != "$BYTES" ]; then
    echo "ERROR: size mismatch: sent $BYTES, remote $R_SIZE" >&2
    exit 1
fi
echo "uploaded $BYTES bytes to $REMOTE/$OBJ (verified)"

echo "$SNAP" > "$BASE_FILE"
if [ "$OBJ" = "base.zfs" ]; then
    if ! /usr/bin/rclone delete --quiet "$REMOTE/deltas/"; then
        echo "ERROR: new base uploaded but old deltas remain; delete $REMOTE/deltas/ manually" >&2
        exit 1
    fi
    echo "old delta chain pruned (new base)"
fi
echo "OK"
