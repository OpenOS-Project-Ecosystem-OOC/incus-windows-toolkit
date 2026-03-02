#!/usr/bin/env bash
# Generate .desktop files for Windows applications so they appear in
# Linux application menus (GNOME, KDE, etc.).
#
# Usage:
#   generate-desktop-entries.sh [--extract-icons] [--output-dir DIR] [--vm NAME]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BACKEND_DIR="$SCRIPT_DIR/../backend"

source "$IWT_ROOT/cli/lib.sh"
source "$BACKEND_DIR/incus-backend.sh"

APPS_CONF="$SCRIPT_DIR/apps.conf"
OUTPUT_DIR="$HOME/.local/share/applications/iwt"
ICON_DIR="$HOME/.local/share/icons/iwt"
EXTRACT_ICONS=false

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --extract-icons) EXTRACT_ICONS=true; shift ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        --vm)            IWT_VM_NAME="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: generate-desktop-entries.sh [--extract-icons] [--output-dir DIR] [--vm NAME]"
            exit 0
            ;;
        *)               die "Unknown option: $1" ;;
    esac
done

mkdir -p "$OUTPUT_DIR" "$ICON_DIR"

if [[ ! -f "$APPS_CONF" ]]; then
    warn "No apps.conf found at $APPS_CONF"
    info "Creating starter configuration..."

    cat > "$APPS_CONF" <<'EOF'
# IWT RemoteApp Application Definitions
# Format: Display Name|Windows EXE Path|Icon Name|FreeDesktop Categories
#
# Add your applications below. Use 'iwt remoteapp discover' to auto-detect.
# Lines starting with # are comments.

Notepad|C:\Windows\System32\notepad.exe|accessories-text-editor|Utility;TextEditor
Calculator|C:\Windows\System32\calc.exe|accessories-calculator|Utility;Calculator
Command Prompt|C:\Windows\System32\cmd.exe|utilities-terminal|System;TerminalEmulator
PowerShell|C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe|utilities-terminal|System;TerminalEmulator
File Explorer|C:\Windows\explorer.exe|system-file-manager|System;FileManager
Paint|C:\Windows\System32\mspaint.exe|applications-graphics|Graphics
WordPad|C:\Program Files\Windows NT\Accessories\wordpad.exe|accessories-text-editor|Office;WordProcessor
EOF
    ok "Created starter apps.conf"
    info "Edit $APPS_CONF to add your applications, then re-run."
fi

count=0
skipped=0

while IFS='|' read -r name exe_path icon_name categories; do
    # Skip comments and empty lines
    [[ "$name" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$name" ]] && continue

    # Sanitize name for filename
    local_name=$(echo "$name" | tr ' ' '-' | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9-')
    desktop_file="$OUTPUT_DIR/iwt-${local_name}.desktop"

    # Try to extract icon from the VM if requested
    local_icon="${icon_name:-application-x-executable}"
    if [[ "$EXTRACT_ICONS" == true && -n "$exe_path" ]]; then
        extracted=$(vm_extract_icon "$exe_path" "$ICON_DIR" 2>/dev/null || true)
        if [[ -n "$extracted" && -f "$extracted" ]]; then
            local_icon="$extracted"
            info "  Extracted icon for: $name"
        fi
    fi

    cat > "$desktop_file" <<EOF
[Desktop Entry]
Type=Application
Name=$name (Windows)
Comment=Windows application via IWT RemoteApp
Exec=$BACKEND_DIR/launch-app.sh --vm $IWT_VM_NAME "$exe_path"
Icon=${local_icon}
Categories=${categories:-Windows;}
StartupNotify=true
StartupWMClass=iwt-${local_name}
Keywords=windows;iwt;${local_name};
EOF

    chmod +x "$desktop_file"
    count=$((count + 1))
done < "$APPS_CONF"

# Update desktop database
if command -v update-desktop-database &>/dev/null; then
    update-desktop-database "$OUTPUT_DIR" 2>/dev/null || true
fi

ok "Generated $count .desktop entries in $OUTPUT_DIR"
if [[ $skipped -gt 0 ]]; then
    warn "Skipped $skipped entries (see errors above)"
fi
