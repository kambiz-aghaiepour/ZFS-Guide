#!/bin/bash
# zfs-recovery-kit.sh - create or restore a ZFS/B2 recovery kit.
#
# The kit contains the files needed to re-establish local access and B2
# integration:
#   /etc/zfs/zfs.key
#   /root/.config/rclone/rclone.conf
#   /etc/zfs-backup.conf (optional)
#
# It also contains MANIFEST and SHA256SUMS. The .tar.gz holds plaintext
# secrets; encrypt it before storing it offsite.

set -euo pipefail
umask 077

SCRIPT_NAME="${0##*/}"
WORK_DIR=""
ARCHIVE=""
ENTRIES=()

usage() {
    cat <<EOF
Usage:
  $SCRIPT_NAME --create
  $SCRIPT_NAME --restore <kit.tar.gz>
  $SCRIPT_NAME --help

--create    Create a timestamped recovery kit in \${HOME:-/root}.
            Includes /etc/zfs/zfs.key, /root/.config/rclone/rclone.conf,
            and /etc/zfs-backup.conf when present.
--restore   Inspect a kit and restore the files to their target locations.
            Aborts if any target file already exists.
--help      Show this help. Running with no arguments prints this help.

The archive contains plaintext credentials. Encrypt it (age/GPG) before
storing it offsite. Backblaze account recovery codes and the password-manager
emergency kit are not included; keep those in the vault separately.
--restore must run as root.
EOF
}

warn() { echo "WARNING: $*" >&2; }
die() { echo "ERROR: $*" >&2; exit 1; }

cleanup() {
    if [ -n "${WORK_DIR:-}" ]; then
        rm -rf "$WORK_DIR"
    fi
}
trap cleanup EXIT

require_root() {
    [ "$(id -u)" -eq 0 ] || die "must run as root"
}

require_commands() {
    local c
    for c in tar gzip sha256sum install mktemp date uname awk grep wc dirname sort cut head chmod rm sed mkdir id cat; do
        command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
    done
}

create_kit() {
    require_commands
    require_root

    local key=/etc/zfs/zfs.key
    local rclone_conf=/root/.config/rclone/rclone.conf
    local backup_conf=/etc/zfs-backup.conf
    local home="${HOME:-/root}"
    local ts prefix out stage
    local key_bytes

    [ -f "$key" ] || die "$key not found; cannot create a recovery kit"
    [ -f "$rclone_conf" ] || die "$rclone_conf not found; cannot create a recovery kit"
    [ ! -L "$key" ] || die "$key is a symlink; refusing"
    [ ! -L "$rclone_conf" ] || die "$rclone_conf is a symlink; refusing"
    [ -s "$rclone_conf" ] || die "$rclone_conf is empty; cannot create a recovery kit"

    key_bytes=$(wc -c < "$key")
    [ "$key_bytes" -eq 32 ] || die "$key is $key_bytes bytes; expected exactly 32"

    if ! grep -q '^\[b2\]' "$rclone_conf"; then
        warn "$rclone_conf has no [b2] section; verify the remote name in $backup_conf or the script defaults"
    fi

    [ -d "$home" ] || die "output directory does not exist: $home"

    ts=$(date -u +%Y%m%dT%H%M%SZ)
    prefix="zfs-recovery-kit-$ts"
    out="$home/$prefix.tar.gz"
    [ ! -e "$out" ] || die "output already exists: $out"

    WORK_DIR=$(mktemp -d)
    stage="$WORK_DIR"

    install -d -m 755 "$stage/$prefix/etc/zfs"
    install -d -m 700 "$stage/$prefix/root/.config/rclone"
    install -m 400 "$key" "$stage/$prefix/etc/zfs/zfs.key"
    install -m 600 "$rclone_conf" "$stage/$prefix/root/.config/rclone/rclone.conf"

    local members=( "$prefix/etc/zfs/zfs.key" "$prefix/root/.config/rclone/rclone.conf" )
    local have_conf=0
    if [ -f "$backup_conf" ]; then
        [ ! -L "$backup_conf" ] || die "$backup_conf is a symlink; refusing"
        install -m 644 "$backup_conf" "$stage/$prefix/etc/zfs-backup.conf"
        members+=( "$prefix/etc/zfs-backup.conf" )
        have_conf=1
    else
        warn "$backup_conf not found; kit will rely on script defaults"
    fi

    {
        echo "format=1"
        echo "created_utc=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "hostname=$(uname -n)"
        echo "zfs_version=$(/usr/sbin/zfs version 2>/dev/null | head -n1 || echo unknown)"
        echo "rclone_version=$(/usr/bin/rclone version 2>/dev/null | head -n1 || echo unknown)"
        echo "files:"
        local m target mode
        for m in "${members[@]}"; do
            case "$m" in
                */etc/zfs/zfs.key) target=/etc/zfs/zfs.key; mode=0400 ;;
                */root/.config/rclone/rclone.conf) target=/root/.config/rclone/rclone.conf; mode=0600 ;;
                */etc/zfs-backup.conf) target=/etc/zfs-backup.conf; mode=0644 ;;
                *) target="$m"; mode=unknown ;;
            esac
            printf '  %s -> %s mode=%s sha256=%s\n' \
                "$target" "$m" "$mode" "$(sha256sum "$stage/$m" | awk '{print $1}')"
        done
        echo "notes: archive contains plaintext secrets; encrypt before offsite storage"
    } > "$stage/$prefix/MANIFEST"

    ( cd "$stage" && sha256sum "${members[@]}" > "$prefix/SHA256SUMS" )

    tar -czf "$out" -C "$stage" "$prefix"
    chmod 600 "$out"

    echo "Created recovery kit: $out"
    echo "Archive SHA-256: $(sha256sum "$out" | awk '{print $1}')"
    echo
    echo "Contents:"
    tar -tzf "$out" | sed 's/^/  /'
    echo
    warn "the archive contains plaintext credentials; encrypt it (age/GPG) before storing it offsite"
    warn "B2 account recovery codes and the password-manager emergency kit are not in the kit; store them in the vault separately"
}

list_has() {
    local want="$1" e
    for e in "${ENTRIES[@]}"; do
        if [ "$e" = "$want" ]; then
            return 0
        fi
    done
    return 1
}

extract_member() {
    local member="$1"
    mkdir -p "$WORK_DIR/out/$(dirname "$member")"
    tar -xzf "$ARCHIVE" -C "$WORK_DIR/out" "$member"
    [ -f "$WORK_DIR/out/$member" ] || die "archive member is not a regular file: $member"
    [ ! -L "$WORK_DIR/out/$member" ] || die "archive member is a symlink: $member"
}

restore_kit() {
    local archive="$1"
    require_commands
    require_root

    [ -f "$archive" ] || die "archive not found: $archive"
    [ ! -L "$archive" ] || die "archive is a symlink; refusing: $archive"

    ARCHIVE="$archive"
    WORK_DIR=$(mktemp -d)

    if ! tar -tzf "$archive" > "$WORK_DIR/entries" 2> "$WORK_DIR/tar.err"; then
        cat "$WORK_DIR/tar.err" >&2
        die "not a valid .tar.gz archive: $archive"
    fi

    mapfile -t ENTRIES < "$WORK_DIR/entries"
    [ "${#ENTRIES[@]}" -gt 0 ] || die "archive is empty: $archive"

    local tops top e
    mapfile -t tops < <(printf '%s\n' "${ENTRIES[@]}" | cut -d/ -f1 | sort -u)
    [ "${#tops[@]}" -eq 1 ] || die "archive must contain exactly one top-level directory"
    top="${tops[0]}"
    case "$top" in
        ""|.|-*) die "invalid top-level directory in archive: $top" ;;
    esac

    for e in "${ENTRIES[@]}"; do
        case "$e" in
            ""|/*|..|../*|*/../*|*/..) die "unsafe path in archive: $e" ;;
        esac
        case "$e" in
            "$top"|"$top"/*) ;;
            *) die "archive entry outside top-level directory: $e" ;;
        esac
    done

    local key_member="$top/etc/zfs/zfs.key"
    local rclone_member="$top/root/.config/rclone/rclone.conf"
    local conf_member="$top/etc/zfs-backup.conf"
    local manifest_member="$top/MANIFEST"
    local sums_member="$top/SHA256SUMS"
    local missing=0 m

    for m in "$key_member" "$rclone_member"; do
        if ! list_has "$m"; then
            warn "missing required file: ${m#"$top"/}"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "archive is incomplete; aborting without restoring"

    local have_conf=0 have_manifest=0 have_sums=0
    if list_has "$conf_member"; then
        have_conf=1
    else
        warn "optional file not present: /etc/zfs-backup.conf; restored scripts will use defaults"
    fi
    if list_has "$manifest_member"; then
        have_manifest=1
    else
        warn "MANIFEST not present; skipping metadata"
    fi
    if list_has "$sums_member"; then
        have_sums=1
    else
        warn "SHA256SUMS not present; skipping integrity verification"
    fi

    mkdir -p "$WORK_DIR/out"
    extract_member "$key_member"
    extract_member "$rclone_member"
    if [ "$have_conf" -eq 1 ]; then
        extract_member "$conf_member"
    fi
    if [ "$have_manifest" -eq 1 ]; then
        extract_member "$manifest_member"
    fi
    if [ "$have_sums" -eq 1 ]; then
        extract_member "$sums_member"
    fi

    local key_bytes
    key_bytes=$(wc -c < "$WORK_DIR/out/$key_member")
    if [ "$key_bytes" -ne 32 ]; then
        warn "zfs.key is $key_bytes bytes; expected exactly 32"
        die "invalid key; aborting without restoring"
    fi

    [ -s "$WORK_DIR/out/$rclone_member" ] || {
        warn "rclone.conf is empty"
        die "invalid rclone config; aborting without restoring"
    }
    if ! grep -q '^\[b2\]' "$WORK_DIR/out/$rclone_member"; then
        warn "restored rclone.conf has no [b2] section; verify the remote name in /etc/zfs-backup.conf or the script defaults"
    fi

    echo "Archive SHA-256: $(sha256sum "$archive" | awk '{print $1}')"
    echo "Compare this with the archive hash recorded in the vault."
    if [ "$have_sums" -eq 1 ]; then
        if ! ( cd "$WORK_DIR/out" && sha256sum -c "$sums_member" > "$WORK_DIR/sha.log" 2>&1 ); then
            cat "$WORK_DIR/sha.log" >&2
            die "checksum verification failed; aborting without restoring"
        fi
        echo "Checksums verified."
    fi

    if [ "$have_manifest" -eq 1 ]; then
        local created
        created=$(grep '^created_utc=' "$WORK_DIR/out/$manifest_member" | cut -d= -f2- || true)
        [ -n "$created" ] && echo "Kit created (UTC): $created"
    fi

    local targets=( /etc/zfs/zfs.key /root/.config/rclone/rclone.conf )
    if [ "$have_conf" -eq 1 ]; then
        targets+=( /etc/zfs-backup.conf )
    fi

    local conflicts=0 t
    for t in "${targets[@]}"; do
        if [ -e "$t" ] || [ -L "$t" ]; then
            echo "ERROR: target already exists: $t" >&2
            conflicts=1
        fi
    done
    if [ "$conflicts" -ne 0 ]; then
        die "aborting: no files were restored"
    fi

    install -d -m 755 /etc/zfs
    install -d -m 700 /root/.config/rclone
    install -m 400 -o root -g root "$WORK_DIR/out/$key_member" /etc/zfs/zfs.key
    install -m 600 -o root -g root "$WORK_DIR/out/$rclone_member" /root/.config/rclone/rclone.conf
    if [ "$have_conf" -eq 1 ]; then
        install -m 644 -o root -g root "$WORK_DIR/out/$conf_member" /etc/zfs-backup.conf
    fi

    echo
    echo "Restored:"
    echo "  /etc/zfs/zfs.key (0400 root:root)"
    echo "  /root/.config/rclone/rclone.conf (0600 root:root)"
    if [ "$have_conf" -eq 1 ]; then
        echo "  /etc/zfs-backup.conf (0644 root:root)"
    fi
    echo
    echo "Next steps:"
    echo "  sudo sha256sum /etc/zfs/zfs.key"
    echo "  sudo rclone lsd b2:zfs-backup"
    echo "  follow docs/RECONSTRUCTION.md to receive the offsite chain"
}

case "${1:-}" in
    ""|--help|-h)
        usage
        exit 0
        ;;
    --create)
        if [ "$#" -ne 1 ]; then
            echo "ERROR: invalid arguments: --create takes no additional arguments and cannot be combined with --restore" >&2
            usage >&2
            exit 2
        fi
        create_kit
        ;;
    --restore)
        if [ "$#" -ne 2 ]; then
            echo "ERROR: invalid arguments: --restore requires exactly one .tar.gz file and cannot be combined with --create" >&2
            usage >&2
            exit 2
        fi
        case "$2" in
            --*)
                echo "ERROR: invalid argument: $2" >&2
                usage >&2
                exit 2
                ;;
        esac
        restore_kit "$2"
        ;;
    *)
        echo "ERROR: invalid argument: $1" >&2
        usage >&2
        exit 2
        ;;
esac
