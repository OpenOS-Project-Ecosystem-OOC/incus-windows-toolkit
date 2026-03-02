#!/usr/bin/env bash
# Incus backend for RemoteApp integration.
# Provides functions to query VM state, get RDP connection info,
# and manage the Windows VM lifecycle through Incus.
#
# Sourced by the remoteapp launcher and CLI -- not run directly.

set -euo pipefail

# Source shared library if not already loaded
if [[ -z "${IWT_ROOT:-}" ]]; then
    IWT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
fi
if ! declare -f info &>/dev/null; then
    source "$IWT_ROOT/cli/lib.sh"
fi

# --- Configuration ---

IWT_VM_NAME="${IWT_VM_NAME:-windows}"
IWT_RDP_PORT="${IWT_RDP_PORT:-3389}"
IWT_RDP_USER="${IWT_RDP_USER:-User}"
IWT_RDP_PASS="${IWT_RDP_PASS:-}"
IWT_RDP_TIMEOUT="${IWT_RDP_TIMEOUT:-120}"
IWT_AGENT_TIMEOUT="${IWT_AGENT_TIMEOUT:-60}"

# --- VM lifecycle ---

vm_exists() {
    incus info "$IWT_VM_NAME" &>/dev/null
}

vm_is_running() {
    local status
    status=$(incus info "$IWT_VM_NAME" 2>/dev/null | grep "^Status:" | awk '{print $2}')
    [[ "$status" == "RUNNING" ]]
}

vm_start() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist. Create it with: iwt vm create --name $IWT_VM_NAME"
    fi

    if vm_is_running; then
        info "VM '$IWT_VM_NAME' is already running"
        return 0
    fi

    info "Starting VM: $IWT_VM_NAME"
    incus start "$IWT_VM_NAME"
    vm_wait_for_agent
}

vm_stop() {
    if ! vm_exists; then
        die "VM '$IWT_VM_NAME' does not exist"
    fi

    if ! vm_is_running; then
        info "VM '$IWT_VM_NAME' is already stopped"
        return 0
    fi

    info "Stopping VM: $IWT_VM_NAME"
    incus stop "$IWT_VM_NAME"
    ok "VM stopped"
}

vm_wait_for_agent() {
    info "Waiting for incus-agent (timeout: ${IWT_AGENT_TIMEOUT}s)..."
    local attempts=0
    while ! incus exec "$IWT_VM_NAME" -- cmd /c "echo ready" &>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $IWT_AGENT_TIMEOUT ]]; then
            die "Timed out waiting for agent after ${IWT_AGENT_TIMEOUT}s"
        fi
        sleep 1
    done
    ok "Agent ready"
}

# --- Network info ---

vm_get_ip() {
    # Get the first IPv4 address from the VM (skip loopback)
    local ip
    ip=$(incus info "$IWT_VM_NAME" 2>/dev/null | \
        grep -A1 "inet:" | grep -oP '\d+\.\d+\.\d+\.\d+' | \
        grep -v '^127\.' | head -1)

    if [[ -z "$ip" ]]; then
        # Fallback: try the network leases
        ip=$(incus network list-leases incusbr0 2>/dev/null | \
            grep "$IWT_VM_NAME" | awk '{print $3}' | head -1)
    fi

    echo "$ip"
}

vm_wait_for_rdp() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP address. Is the VM running?"

    info "Waiting for RDP on ${ip}:${IWT_RDP_PORT} (timeout: ${IWT_RDP_TIMEOUT}s)..."
    local attempts=0
    while ! timeout 1 bash -c "echo >/dev/tcp/$ip/$IWT_RDP_PORT" 2>/dev/null; do
        attempts=$((attempts + 1))
        if [[ $attempts -ge $IWT_RDP_TIMEOUT ]]; then
            die "RDP not available after ${IWT_RDP_TIMEOUT}s. Check that RDP is enabled in the VM."
        fi
        # Print progress every 10 seconds
        if [[ $((attempts % 10)) -eq 0 ]]; then
            info "  Still waiting... (${attempts}s)"
        fi
        sleep 1
    done
    ok "RDP ready at ${ip}:${IWT_RDP_PORT}"
}

# --- RDP connection ---

# Detect available FreeRDP binary
_freerdp_cmd() {
    if command -v xfreerdp3 &>/dev/null; then
        echo "xfreerdp3"
    elif command -v xfreerdp &>/dev/null; then
        echo "xfreerdp"
    else
        die "FreeRDP not found. Install xfreerdp3 or xfreerdp."
    fi
}

rdp_connect_full() {
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP"

    local rdp_cmd
    rdp_cmd=$(_freerdp_cmd)

    info "Connecting to $ip via $rdp_cmd"
    "$rdp_cmd" /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /microphone:sys:pulse \
        /clipboard \
        +auto-reconnect \
        /auto-reconnect-max-retries:5 \
        "$@"
}

rdp_launch_remoteapp() {
    # Launch a single Windows application as a seamless Linux window
    local app_name="$1"
    shift
    local ip
    ip=$(vm_get_ip)
    [[ -n "$ip" ]] || die "Cannot determine VM IP"

    local rdp_cmd
    rdp_cmd=$(_freerdp_cmd)

    info "Launching RemoteApp: $app_name"
    "$rdp_cmd" /v:"$ip":"$IWT_RDP_PORT" \
        /u:"$IWT_RDP_USER" \
        ${IWT_RDP_PASS:+/p:"$IWT_RDP_PASS"} \
        /app:"||$app_name" \
        /dynamic-resolution \
        /gfx:AVC444 \
        /sound:sys:pulse \
        /clipboard \
        +auto-reconnect \
        /auto-reconnect-max-retries:5 \
        "$@"
}

# --- App discovery ---

vm_list_installed_apps() {
    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it first."
    fi

    incus exec "$IWT_VM_NAME" -- powershell -Command '
        $paths = @(
            "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )
        Get-ItemProperty $paths -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -and $_.DisplayName -notmatch "Update|Hotfix|KB\d+" } |
            Select-Object DisplayName, InstallLocation |
            Sort-Object DisplayName |
            ForEach-Object {
                $loc = if ($_.InstallLocation) { $_.InstallLocation } else { "(unknown)" }
                "$($_.DisplayName)|$loc"
            }
    '
}

vm_find_exe() {
    local exe_name="$1"

    if ! vm_is_running; then
        die "VM '$IWT_VM_NAME' is not running. Start it first."
    fi

    incus exec "$IWT_VM_NAME" -- powershell -Command "
        \$paths = @(
            'C:\\Program Files',
            'C:\\Program Files (x86)',
            'C:\\Windows\\System32',
            'C:\\Windows\\SysWOW64'
        )
        foreach (\$p in \$paths) {
            \$found = Get-ChildItem -Path \$p -Filter '$exe_name' -Recurse -ErrorAction SilentlyContinue -Depth 3 | Select-Object -First 1
            if (\$found) { Write-Output \$found.FullName; return }
        }
    "
}

# --- Icon extraction ---

vm_extract_icon() {
    # Extract an application icon from the VM and save it locally.
    # Returns the local path to the extracted icon.
    local exe_path="$1"
    local output_dir="${2:-$HOME/.local/share/icons/iwt}"

    mkdir -p "$output_dir"

    local icon_name
    icon_name=$(basename "$exe_path" .exe | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
    local icon_file="$output_dir/${icon_name}.png"

    if [[ -f "$icon_file" ]]; then
        echo "$icon_file"
        return 0
    fi

    if ! vm_is_running; then
        warn "VM not running; cannot extract icon"
        echo ""
        return 1
    fi

    # Use PowerShell to extract the icon and base64 encode it
    local b64
    b64=$(incus exec "$IWT_VM_NAME" -- powershell -Command "
        Add-Type -AssemblyName System.Drawing
        try {
            \$icon = [System.Drawing.Icon]::ExtractAssociatedIcon('$exe_path')
            if (\$icon) {
                \$bmp = \$icon.ToBitmap()
                \$ms = New-Object System.IO.MemoryStream
                \$bmp.Save(\$ms, [System.Drawing.Imaging.ImageFormat]::Png)
                [Convert]::ToBase64String(\$ms.ToArray())
            }
        } catch {}
    " 2>/dev/null || true)

    if [[ -n "$b64" ]]; then
        echo "$b64" | base64 -d > "$icon_file"
        echo "$icon_file"
    else
        echo ""
    fi
}
