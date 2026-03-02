#!/usr/bin/env bash
# Curated Windows app store — install apps via winget inside a VM.
#
# Usage:
#   app-store.sh <subcommand> [options]
#
# Subcommands:
#   list              List available app bundles
#   show <bundle>     Show apps in a bundle
#   install <bundle>  Install an app bundle in the VM
#   search <query>    Search winget for apps inside the VM
#   install-app <id>  Install a single winget app by ID

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

# --- App bundles ---
# Format: BUNDLE_<name>=("winget_id|display_name" ...)

# Bundles are accessed via indirect expansion (BUNDLE_${name}[@])
# shellcheck disable=SC2034
declare -a BUNDLE_dev=(
    "Git.Git|Git"
    "Microsoft.VisualStudioCode|VS Code"
    "Microsoft.WindowsTerminal|Windows Terminal"
    "Python.Python.3.12|Python 3.12"
    "OpenJS.NodeJS.LTS|Node.js LTS"
    "Docker.DockerDesktop|Docker Desktop"
)

# shellcheck disable=SC2034
declare -a BUNDLE_gaming=(
    "Valve.Steam|Steam"
    "EpicGames.EpicGamesLauncher|Epic Games"
    "Discord.Discord|Discord"
    "Nvidia.GeForceExperience|GeForce Experience"
)

# shellcheck disable=SC2034
declare -a BUNDLE_office=(
    "Mozilla.Firefox|Firefox"
    "Google.Chrome|Chrome"
    "7zip.7zip|7-Zip"
    "Notepad++.Notepad++|Notepad++"
    "VideoLAN.VLC|VLC"
    "TheDocumentFoundation.LibreOffice|LibreOffice"
)

# shellcheck disable=SC2034
declare -a BUNDLE_creative=(
    "GIMP.GIMP|GIMP"
    "KDE.Krita|Krita"
    "Inkscape.Inkscape|Inkscape"
    "Audacity.Audacity|Audacity"
    "OBSProject.OBSStudio|OBS Studio"
    "BlenderFoundation.Blender|Blender"
)

# shellcheck disable=SC2034
declare -a BUNDLE_sysadmin=(
    "PuTTY.PuTTY|PuTTY"
    "WinSCP.WinSCP|WinSCP"
    "WiresharkFoundation.Wireshark|Wireshark"
    "Microsoft.PowerShell|PowerShell 7"
    "Microsoft.Sysinternals.ProcessExplorer|Process Explorer"
    "voidtools.Everything|Everything Search"
)

# shellcheck disable=SC2034
declare -a BUNDLE_security=(
    "KeePassXCTeam.KeePassXC|KeePassXC"
    "GnuPG.Gpg4win|Gpg4win"
    "WireGuard.WireGuard|WireGuard"
    "Bitwarden.Bitwarden|Bitwarden"
)

# All bundle names
ALL_BUNDLES=(dev gaming office creative sysadmin security)

# --- Bundle operations ---

get_bundle_ref() {
    local name="$1"
    local var="BUNDLE_${name}[@]"
    if [[ -n "${!var+x}" ]]; then
        echo "${!var}"
    fi
}

cmd_list() {
    bold "App Bundles"
    echo ""
    printf "  %-12s %-6s %s\n" "BUNDLE" "APPS" "DESCRIPTION"
    printf "  %-12s %-6s %s\n" "------" "----" "-----------"

    local descriptions=(
        "dev:Development tools (Git, VS Code, Node.js, Python)"
        "gaming:Gaming platforms (Steam, Epic, Discord)"
        "office:Productivity apps (Firefox, Chrome, VLC, LibreOffice)"
        "creative:Creative tools (GIMP, Krita, Blender, OBS)"
        "sysadmin:System admin tools (PuTTY, Wireshark, PowerShell 7)"
        "security:Security tools (KeePassXC, WireGuard, Bitwarden)"
    )

    for entry in "${descriptions[@]}"; do
        local bname="${entry%%:*}"
        local desc="${entry#*:}"
        local var="BUNDLE_${bname}[@]"
        local count=0
        for _ in "${!var}"; do count=$((count + 1)); done
        printf "  %-12s %-6s %s\n" "$bname" "$count" "$desc"
    done

    echo ""
    info "Install with: iwt apps install <bundle>"
    info "Show contents: iwt apps show <bundle>"
}

cmd_show() {
    local bundle_name="${1:?Usage: iwt apps show <bundle>}"

    local var="BUNDLE_${bundle_name}[@]"
    if [[ -z "${!var+x}" ]]; then
        die "Unknown bundle: $bundle_name (available: ${ALL_BUNDLES[*]})"
    fi

    bold "Bundle: $bundle_name"
    echo ""
    printf "  %-40s %s\n" "WINGET ID" "NAME"
    printf "  %-40s %s\n" "---------" "----"

    for entry in "${!var}"; do
        local id="${entry%%|*}"
        local name="${entry#*|}"
        printf "  %-40s %s\n" "$id" "$name"
    done
}

cmd_install_bundle() {
    local bundle_name="${1:?Usage: iwt apps install <bundle>}"

    local var="BUNDLE_${bundle_name}[@]"
    if [[ -z "${!var+x}" ]]; then
        die "Unknown bundle: $bundle_name (available: ${ALL_BUNDLES[*]})"
    fi

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running"
    fi
    vm_wait_for_agent

    bold "Installing bundle: $bundle_name"
    echo ""

    # First ensure winget is available
    info "Checking winget availability..."
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        try { winget --version } catch { Write-Host 'winget not found'; exit 1 }
    " 2>/dev/null || {
        warn "winget not available. Attempting to install App Installer..."
        incus exec "$IWT_VM_NAME" -- powershell -Command "
            Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe 2>\$null
        " 2>/dev/null || warn "Could not install winget automatically"
    }

    local installed=0 failed=0
    for entry in "${!var}"; do
        local id="${entry%%|*}"
        local name="${entry#*|}"

        info "Installing: $name ($id)"
        if incus exec "$IWT_VM_NAME" -- powershell -Command "
            winget install --id '$id' --accept-source-agreements --accept-package-agreements --silent 2>\$null
            exit \$LASTEXITCODE
        " 2>/dev/null; then
            ok "  Installed: $name"
            installed=$((installed + 1))
        else
            warn "  Failed: $name (may already be installed)"
            failed=$((failed + 1))
        fi
    done

    echo ""
    ok "Bundle '$bundle_name': $installed installed, $failed failed/skipped"
}

cmd_search() {
    local query="${1:?Usage: iwt apps search <query>}"

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running"
    fi
    vm_wait_for_agent

    info "Searching winget for: $query"
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        winget search '$query' --accept-source-agreements 2>\$null
    " 2>/dev/null || die "winget search failed"
}

cmd_install_app() {
    local app_id="${1:?Usage: iwt apps install-app <winget-id>}"

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running"
    fi
    vm_wait_for_agent

    info "Installing: $app_id"
    incus exec "$IWT_VM_NAME" -- powershell -Command "
        winget install --id '$app_id' --accept-source-agreements --accept-package-agreements --silent 2>\$null
        exit \$LASTEXITCODE
    " 2>/dev/null || die "Installation failed"

    ok "Installed: $app_id"
}

# --- Help ---

usage() {
    cat <<EOF
iwt apps - Windows app store (winget-based)

Subcommands:
  list                List available app bundles
  show <bundle>       Show apps in a bundle
  install <bundle>    Install all apps in a bundle
  search <query>      Search winget for apps
  install-app <id>    Install a single app by winget ID

Options:
  --vm NAME           Target VM (default: \$IWT_VM_NAME)

Bundles: ${ALL_BUNDLES[*]}

Examples:
  iwt apps list
  iwt apps show dev
  iwt apps install gaming
  iwt apps search "visual studio"
  iwt apps install-app Microsoft.VisualStudioCode
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    # Handle --vm flag anywhere
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm) IWT_VM_NAME="$2"; shift 2 ;;
            *)    break ;;
        esac
    done

    case "$subcmd" in
        list|ls)          cmd_list ;;
        show)             cmd_show "$@" ;;
        install)          cmd_install_bundle "$@" ;;
        search)           cmd_search "$@" ;;
        install-app)      cmd_install_app "$@" ;;
        help|--help|-h)   usage ;;
        *)
            err "Unknown apps subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
