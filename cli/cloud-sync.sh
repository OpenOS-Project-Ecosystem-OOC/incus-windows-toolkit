#!/usr/bin/env bash
# Sync VM backups to cloud storage via rclone.
#
# Usage:
#   cloud-sync.sh <subcommand> [options]
#
# Subcommands:
#   push              Upload local backups to remote
#   pull              Download remote backups to local
#   list              List remote backups
#   config            Configure remote storage
#   status            Show sync status

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

BACKUP_DIR="${IWT_BACKUP_DIR:-$HOME/.local/share/iwt/backups}"
REMOTE_NAME="${IWT_CLOUD_REMOTE:-iwt-backups}"
REMOTE_PATH="${IWT_CLOUD_PATH:-iwt/backups}"

# --- Prerequisites ---

require_rclone() {
    if ! command -v rclone &>/dev/null; then
        die "rclone is required for cloud sync. Install: https://rclone.org/install/"
    fi
}

remote_configured() {
    rclone listremotes 2>/dev/null | grep -q "^${REMOTE_NAME}:" 2>/dev/null
}

# --- Push ---

cmd_push() {
    require_rclone
    mkdir -p "$BACKUP_DIR"

    if ! remote_configured; then
        die "Remote '${REMOTE_NAME}' not configured. Run: iwt cloud config"
    fi

    local file_filter="${1:-}"

    bold "Cloud Sync: Push"
    info "Local:  $BACKUP_DIR"
    info "Remote: ${REMOTE_NAME}:${REMOTE_PATH}"
    echo ""

    local count=0
    for f in "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.tar; do
        [[ -f "$f" ]] || continue

        # Apply filter if specified
        if [[ -n "$file_filter" ]] && ! echo "$(basename "$f")" | grep -q "$file_filter"; then
            continue
        fi

        local filename
        filename=$(basename "$f")
        local size
        size=$(stat -c%s "$f" 2>/dev/null || stat -f%z "$f" 2>/dev/null || echo "0")

        info "Uploading: $filename ($(human_size "$size"))"
        rclone copy "$f" "${REMOTE_NAME}:${REMOTE_PATH}/" \
            --progress --transfers 1 || {
            warn "Failed to upload: $filename"
            continue
        }
        count=$((count + 1))
    done

    # Also sync metadata files
    for f in "$BACKUP_DIR"/*.meta; do
        [[ -f "$f" ]] || continue
        rclone copy "$f" "${REMOTE_NAME}:${REMOTE_PATH}/" 2>/dev/null || true
    done

    echo ""
    if [[ $count -eq 0 ]]; then
        info "No backups to upload"
    else
        ok "Uploaded $count backup(s)"
    fi
}

# --- Pull ---

cmd_pull() {
    require_rclone
    mkdir -p "$BACKUP_DIR"

    if ! remote_configured; then
        die "Remote '${REMOTE_NAME}' not configured. Run: iwt cloud config"
    fi

    local file_filter="${1:-}"

    bold "Cloud Sync: Pull"
    info "Remote: ${REMOTE_NAME}:${REMOTE_PATH}"
    info "Local:  $BACKUP_DIR"
    echo ""

    if [[ -n "$file_filter" ]]; then
        info "Filter: $file_filter"
        rclone copy "${REMOTE_NAME}:${REMOTE_PATH}/" "$BACKUP_DIR/" \
            --include "*${file_filter}*" \
            --progress --transfers 1 || die "Pull failed"
    else
        rclone copy "${REMOTE_NAME}:${REMOTE_PATH}/" "$BACKUP_DIR/" \
            --progress --transfers 1 || die "Pull failed"
    fi

    ok "Pull complete"
}

# --- List remote ---

cmd_list() {
    require_rclone

    if ! remote_configured; then
        die "Remote '${REMOTE_NAME}' not configured. Run: iwt cloud config"
    fi

    bold "Remote Backups: ${REMOTE_NAME}:${REMOTE_PATH}"
    echo ""
    printf "  %-40s %-12s %s\n" "FILENAME" "SIZE" "MODIFIED"
    printf "  %-40s %-12s %s\n" "--------" "----" "--------"

    rclone lsf "${REMOTE_NAME}:${REMOTE_PATH}/" --format "psm" 2>/dev/null | \
    while IFS=';' read -r path size mod; do
        [[ -n "$path" ]] || continue
        # Skip metadata files in display
        [[ "$path" != *.meta ]] || continue
        printf "  %-40s %-12s %s\n" "$path" "$size" "$mod"
    done || info "  No remote backups found"

    echo ""

    # Show sync status
    local local_count remote_count
    local_count=$(find "$BACKUP_DIR" -name '*.tar*' 2>/dev/null | wc -l)
    remote_count=$(rclone lsf "${REMOTE_NAME}:${REMOTE_PATH}/" --include '*.tar*' 2>/dev/null | wc -l || echo "0")
    info "Local: $local_count backups | Remote: $remote_count backups"
}

# --- Config ---

cmd_config() {
    require_rclone

    local subcmd="${1:-interactive}"

    case "$subcmd" in
        show)
            bold "Cloud Sync Configuration"
            echo ""
            echo "  Remote name: $REMOTE_NAME"
            echo "  Remote path: $REMOTE_PATH"
            echo "  Local dir:   $BACKUP_DIR"
            echo ""

            if remote_configured; then
                ok "Remote '${REMOTE_NAME}' is configured"
                info "Remote type: $(rclone config show "$REMOTE_NAME" 2>/dev/null | grep 'type' | awk '{print $3}')"
            else
                warn "Remote '${REMOTE_NAME}' is not configured"
            fi
            ;;

        s3)
            info "Configuring S3-compatible remote..."
            echo ""
            echo "You'll need: access key, secret key, region, and bucket name."
            echo ""
            rclone config create "$REMOTE_NAME" s3 \
                provider "AWS" \
                env_auth "false" || die "S3 config failed"
            ok "S3 remote configured as '${REMOTE_NAME}'"
            ;;

        b2)
            info "Configuring Backblaze B2 remote..."
            rclone config create "$REMOTE_NAME" b2 || die "B2 config failed"
            ok "B2 remote configured as '${REMOTE_NAME}'"
            ;;

        interactive|setup)
            info "Launching rclone interactive config..."
            echo "Create a remote named: $REMOTE_NAME"
            echo ""
            rclone config
            ;;

        *)
            cat <<EOF
iwt cloud config - Configure cloud storage

Subcommands:
  show          Show current configuration
  s3            Configure S3-compatible storage
  b2            Configure Backblaze B2
  interactive   Launch rclone interactive config (default)

Environment variables:
  IWT_CLOUD_REMOTE    Remote name (default: iwt-backups)
  IWT_CLOUD_PATH      Remote path (default: iwt/backups)
  IWT_BACKUP_DIR      Local backup directory

Add to ~/.config/iwt/config:
  IWT_CLOUD_REMOTE=my-remote
  IWT_CLOUD_PATH=my-bucket/iwt
EOF
            ;;
    esac
}

# --- Status ---

cmd_status() {
    require_rclone

    bold "Cloud Sync Status"
    echo ""

    if ! remote_configured; then
        warn "Remote '${REMOTE_NAME}' not configured"
        info "Run: iwt cloud config"
        return 1
    fi

    ok "Remote: ${REMOTE_NAME} (configured)"
    info "Path: ${REMOTE_PATH}"

    local local_count local_size remote_count
    local_count=$(find "$BACKUP_DIR" -name '*.tar*' 2>/dev/null | wc -l)
    local_size=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}' || echo "0")
    remote_count=$(rclone lsf "${REMOTE_NAME}:${REMOTE_PATH}/" --include '*.tar*' 2>/dev/null | wc -l || echo "?")

    echo ""
    echo "  Local backups:  $local_count ($local_size)"
    echo "  Remote backups: $remote_count"

    # Check for unsynced files
    local unsynced=0
    for f in "$BACKUP_DIR"/*.tar.gz "$BACKUP_DIR"/*.tar; do
        [[ -f "$f" ]] || continue
        local fname
        fname=$(basename "$f")
        if ! rclone lsf "${REMOTE_NAME}:${REMOTE_PATH}/${fname}" &>/dev/null; then
            unsynced=$((unsynced + 1))
        fi
    done

    if [[ $unsynced -gt 0 ]]; then
        warn "$unsynced local backup(s) not yet synced"
        info "Run: iwt cloud push"
    else
        ok "All local backups synced"
    fi
}

# --- Help ---

usage() {
    cat <<EOF
iwt cloud - Sync backups to cloud storage

Subcommands:
  push [filter]     Upload local backups to remote
  pull [filter]     Download remote backups to local
  list              List remote backups
  config [type]     Configure remote storage (s3, b2, interactive)
  status            Show sync status

Options:
  filter            Optional filename filter (e.g., VM name)

Environment:
  IWT_CLOUD_REMOTE  rclone remote name (default: iwt-backups)
  IWT_CLOUD_PATH    Remote path (default: iwt/backups)

Examples:
  iwt cloud config s3
  iwt cloud push
  iwt cloud push win11
  iwt cloud pull
  iwt cloud list
  iwt cloud status
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        push)             cmd_push "$@" ;;
        pull)             cmd_pull "$@" ;;
        list|ls)          cmd_list ;;
        config)           cmd_config "$@" ;;
        status)           cmd_status ;;
        help|--help|-h)   usage ;;
        *)
            err "Unknown cloud subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
