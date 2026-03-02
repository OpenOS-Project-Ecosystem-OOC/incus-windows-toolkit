#!/usr/bin/env bash
# Launch a Windows application as a seamless Linux window via RemoteApp.
#
# Usage:
#   launch-app.sh [--vm NAME] <app-name-or-exe-path> [freerdp-args...]
#
# Examples:
#   launch-app.sh notepad
#   launch-app.sh --vm win11 "C:\Program Files\Microsoft Office\root\Office16\WINWORD.EXE"
#   launch-app.sh excel /drive:home,/home/user

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$SCRIPT_DIR/incus-backend.sh"

# Parse --vm flag if present
while [[ $# -gt 0 ]]; do
    case "$1" in
        --vm)
            IWT_VM_NAME="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: launch-app.sh [--vm NAME] <app-name-or-exe-path> [freerdp-args...]"
            exit 0
            ;;
        *)
            break
            ;;
    esac
done

APP="${1:?Usage: launch-app.sh [--vm NAME] <app-name-or-exe-path>}"
shift

# Ensure VM is running
if ! vm_is_running; then
    info "VM '$IWT_VM_NAME' not running. Starting..."
    vm_start
fi

# Wait for RDP
vm_wait_for_rdp

# If the argument doesn't look like a Windows path, try to find the exe
if [[ "$APP" != *\\* && "$APP" != */* ]]; then
    if [[ "$APP" != *.exe ]]; then
        APP="${APP}.exe"
    fi
    info "Looking up: $APP"
    found_path=$(vm_find_exe "$APP" 2>/dev/null || true)
    if [[ -n "$found_path" ]]; then
        APP="$found_path"
        info "Found: $APP"
    fi
fi

info "Launching: $APP"
rdp_launch_remoteapp "$APP" "$@"
