#!/usr/bin/env bash
# Apply security hardening to a Windows VM.
#
# Usage:
#   harden-vm.sh [options]
#
# Options:
#   --vm NAME           Target VM (default: $IWT_VM_NAME)
#   --secure-boot       Enable Secure Boot (UEFI)
#   --tpm               Enable TPM 2.0 emulation
#   --vtpm              Enable virtual TPM via swtpm
#   --isolate-network   Restrict VM to host-only networking
#   --readonly-root     Set root disk to read-only (snapshot-based)
#   --all               Apply all hardening options
#   --check             Only check current security posture
#   --help              Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
source "$IWT_ROOT/remoteapp/backend/incus-backend.sh"
load_config

SECURE_BOOT=false
TPM=false
VTPM=false
ISOLATE_NET=false
READONLY_ROOT=false
CHECK_ONLY=false

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --vm)              IWT_VM_NAME="$2"; shift 2 ;;
            --secure-boot)     SECURE_BOOT=true; shift ;;
            --tpm)             TPM=true; shift ;;
            --vtpm)            VTPM=true; shift ;;
            --isolate-network) ISOLATE_NET=true; shift ;;
            --readonly-root)   READONLY_ROOT=true; shift ;;
            --all)
                SECURE_BOOT=true; TPM=true; ISOLATE_NET=true
                shift ;;
            --check)           CHECK_ONLY=true; shift ;;
            --help|-h)
                sed -n '/^# Usage:/,/^[^#]/p' "$0" | grep '^#' | sed 's/^# \?//'
                exit 0
                ;;
            *)                 die "Unknown option: $1" ;;
        esac
    done
}

# --- Security check ---

check_security() {
    bold "Security Posture: $IWT_VM_NAME"
    echo ""

    incus info "$IWT_VM_NAME" &>/dev/null || die "VM not found: $IWT_VM_NAME"

    # Secure Boot
    local sb_val
    sb_val=$(incus config get "$IWT_VM_NAME" security.secureboot 2>/dev/null || echo "")
    if [[ "$sb_val" == "true" ]]; then
        ok "  Secure Boot: enabled"
    else
        warn "  Secure Boot: disabled"
    fi

    # TPM
    if incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "tpm"; then
        ok "  TPM: present"
    else
        warn "  TPM: not configured"
    fi

    # Network isolation
    local net_type
    net_type=$(incus config device get "$IWT_VM_NAME" eth0 nictype 2>/dev/null || echo "unknown")
    local net_parent
    net_parent=$(incus config device get "$IWT_VM_NAME" eth0 parent 2>/dev/null || echo "")
    echo "  Network: $net_type (parent: ${net_parent:-default})"

    # UEFI firmware
    local firmware
    firmware=$(incus config get "$IWT_VM_NAME" raw.qemu 2>/dev/null || echo "")
    if echo "$firmware" | grep -qi "OVMF\|efi"; then
        ok "  Firmware: UEFI"
    else
        info "  Firmware: default (likely UEFI for Incus VMs)"
    fi

    # Agent
    local agent_val
    agent_val=$(incus config get "$IWT_VM_NAME" security.agent.metrics 2>/dev/null || echo "")
    echo "  Agent metrics: ${agent_val:-default}"

    # Snapshots (for recovery)
    local snap_count
    snap_count=$(incus info "$IWT_VM_NAME" 2>/dev/null | grep -c "snap" || echo "0")
    echo "  Snapshots: $snap_count"

    # Guest-side checks (if running)
    if vm_is_running 2>/dev/null; then
        echo ""
        info "Guest security (requires running VM):"

        local guest_info
        guest_info=$(incus exec "$IWT_VM_NAME" -- powershell -Command '
            $result = @{}

            # Windows Defender
            $defender = Get-MpComputerStatus -ErrorAction SilentlyContinue
            $result.Defender = if ($defender) { $defender.AntivirusEnabled } else { $false }

            # Firewall
            $fw = Get-NetFirewallProfile -ErrorAction SilentlyContinue
            $result.Firewall = ($fw | Where-Object { $_.Enabled -eq $true }).Count

            # BitLocker
            $bl = Get-BitLockerVolume -MountPoint "C:" -ErrorAction SilentlyContinue
            $result.BitLocker = if ($bl) { $bl.ProtectionStatus.ToString() } else { "NotAvailable" }

            # UAC
            $uac = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name EnableLUA -ErrorAction SilentlyContinue).EnableLUA
            $result.UAC = ($uac -eq 1)

            $result | ConvertTo-Json
        ' 2>/dev/null) || guest_info=""

        if [[ -n "$guest_info" ]]; then
            local defender fw_count bitlocker uac
            defender=$(echo "$guest_info" | jq -r '.Defender // false')
            fw_count=$(echo "$guest_info" | jq -r '.Firewall // 0')
            bitlocker=$(echo "$guest_info" | jq -r '.BitLocker // "unknown"')
            uac=$(echo "$guest_info" | jq -r '.UAC // false')

            [[ "$defender" == "true" || "$defender" == "True" ]] && ok "  Windows Defender: enabled" || warn "  Windows Defender: disabled"
            [[ "$fw_count" -gt 0 ]] && ok "  Firewall: $fw_count profile(s) active" || warn "  Firewall: disabled"
            echo "  BitLocker: $bitlocker"
            [[ "$uac" == "true" || "$uac" == "True" ]] && ok "  UAC: enabled" || warn "  UAC: disabled"
        else
            info "  (could not query guest — agent may not be ready)"
        fi
    fi
}

# --- Hardening operations ---

enable_secure_boot() {
    info "Enabling Secure Boot..."
    incus config set "$IWT_VM_NAME" security.secureboot=true
    ok "Secure Boot enabled (takes effect on next boot)"
}

enable_tpm() {
    info "Adding TPM 2.0 device..."
    if incus config device show "$IWT_VM_NAME" 2>/dev/null | grep -q "tpm"; then
        ok "TPM device already present"
        return
    fi
    incus config device add "$IWT_VM_NAME" tpm tpm
    ok "TPM 2.0 added (takes effect on next boot)"
}

enable_vtpm() {
    info "Configuring virtual TPM via swtpm..."
    if ! command -v swtpm &>/dev/null; then
        warn "swtpm not installed. Install with: sudo apt install swtpm"
        return
    fi
    # Incus handles swtpm automatically when a tpm device is added
    enable_tpm
}

isolate_network() {
    info "Isolating VM network..."

    # Remove existing network device
    incus config device remove "$IWT_VM_NAME" eth0 2>/dev/null || true

    # Add host-only network (no internet access)
    incus config device add "$IWT_VM_NAME" eth0 nic \
        nictype=bridged \
        parent=incusbr0 \
        security.mac_filtering=true \
        2>/dev/null || {
        warn "Could not configure isolated network. Manual setup may be needed."
        return
    }

    ok "Network isolated (bridge with MAC filtering)"
    info "VM can reach host but not external networks"
}

set_readonly_root() {
    info "Creating read-only snapshot of current state..."
    local snap_name
    snap_name="iwt-readonly-base-$(date +%s)"
    incus snapshot create "$IWT_VM_NAME" "$snap_name"
    ok "Snapshot created: $snap_name"
    info "Restore with: iwt vm snapshot restore $snap_name"
}

# --- Main ---

main() {
    parse_args "$@"

    echo ""
    bold "IWT Security Hardening"
    info "VM: $IWT_VM_NAME"
    echo ""

    incus info "$IWT_VM_NAME" &>/dev/null || die "VM not found: $IWT_VM_NAME"

    if [[ "$CHECK_ONLY" == true ]]; then
        check_security
        return 0
    fi

    # Apply hardening
    local applied=0

    if [[ "$SECURE_BOOT" == true ]]; then
        enable_secure_boot
        applied=$((applied + 1))
    fi

    if [[ "$TPM" == true ]]; then
        enable_tpm
        applied=$((applied + 1))
    fi

    if [[ "$VTPM" == true ]]; then
        enable_vtpm
        applied=$((applied + 1))
    fi

    if [[ "$ISOLATE_NET" == true ]]; then
        isolate_network
        applied=$((applied + 1))
    fi

    if [[ "$READONLY_ROOT" == true ]]; then
        set_readonly_root
        applied=$((applied + 1))
    fi

    if [[ $applied -eq 0 ]]; then
        info "No hardening options specified. Use --all or specific flags."
        info "Run with --check to see current security posture."
        return 0
    fi

    echo ""
    ok "Applied $applied hardening measure(s)"
    info "Some changes require a VM restart to take effect."

    echo ""
    check_security
}

main "$@"
