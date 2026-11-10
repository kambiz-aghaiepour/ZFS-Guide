#!/bin/bash
# Snapshot a ZFS backup dataset: daily (keep 14), weekly (keep 8),
# monthly (keep 12), yearly (keep 3).
#
# Optional overrides: /etc/zfs-backup.conf (DS, *_KEEP).
# Environment variables work too, but the config file wins.

set -euo pipefail

DS="${DS:-tank/backup}"
DAILY_KEEP="${DAILY_KEEP:-14}"
WEEKLY_KEEP="${WEEKLY_KEEP:-8}"
MONTHLY_KEEP="${MONTHLY_KEEP:-12}"
YEARLY_KEEP="${YEARLY_KEEP:-3}"

CONF="${ZFS_BACKUP_CONF:-/etc/zfs-backup.conf}"
if [ -r "$CONF" ]; then
    # shellcheck disable=SC1090
    . "$CONF"
fi

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

TODAY=$(date +%F)
DOW=$(date +%u)   # 7 = Sunday
DOM=$(date +%d)
MON=$(date +%m)

snap() { # snap <kind> <name> <keep>
    local kind="$1" name="$2" keep="$3"
    local full="${DS}@${name}"
    if ! /usr/sbin/zfs list -H -o name -t snapshot "$full" >/dev/null 2>&1; then
        /usr/sbin/zfs snapshot "$full" && echo "created $full"
    else
        echo "exists: $full"
    fi
    local to_delete
    mapfile -t to_delete < <(/usr/sbin/zfs list -H -o name -t snapshot "$DS" \
        | grep "@${kind}-" | sort -r | tail -n +$((keep + 1)) || true)
    for s in "${to_delete[@]}"; do
        /usr/sbin/zfs destroy "$s" && echo "destroyed $s"
    done
    echo "$kind snapshots kept: $(/usr/sbin/zfs list -H -o name -t snapshot "$DS" | grep -c "@${kind}-" || true)"
}

snap daily "daily-${TODAY}" "$DAILY_KEEP"
if [ "$DOW" = "7" ]; then
    snap weekly "weekly-${TODAY}" "$WEEKLY_KEEP"
fi
if [ "$DOM" = "01" ]; then
    snap monthly "monthly-${TODAY}" "$MONTHLY_KEEP"
fi
if [ "$MON" = "01" ] && [ "$DOM" = "01" ]; then
    snap yearly "yearly-${TODAY}" "$YEARLY_KEEP"
fi
exit 0
