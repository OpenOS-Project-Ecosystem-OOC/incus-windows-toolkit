#!/usr/bin/env bash
# Set up VFIO GPU passthrough on the host.
# Binds a GPU to the vfio-pci driver so it can be passed to a VM.
#
# Usage:
#   setup-vfio.sh <PCI_ADDRESS>
#   setup-vfio.sh 0000:01:00.0
#   setup-vfio.sh --list          List GPUs and their IOMMU groups
#   setup-vfio.sh --check         Check VFIO prerequisites
#
# This script must be run as root.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$IWT_ROOT/cli/lib.sh"

require_root() {
    if [[ $EUID -ne 0 ]]; then
        die "This script must be run as root (sudo)"
    fi
}

list_gpus() {
    info "GPUs and IOMMU groups:"
    echo ""

    if [[ ! -d /sys/kernel/iommu_groups ]]; then
        warn "IOMMU not enabled. Enable in BIOS and add intel_iommu=on or amd_iommu=on to kernel cmdline."
        echo ""
        info "GPUs (without IOMMU info):"
        lspci -nn | grep -iE 'vga|3d|display' | sed 's/^/  /'
        return
    fi

    for group_dir in /sys/kernel/iommu_groups/*/devices/*; do
        [[ -e "$group_dir" ]] || continue
        local pci_addr
        pci_addr=$(basename "$group_dir")
        local desc
        desc=$(lspci -nns "$pci_addr" 2>/dev/null || echo "")

        # Only show VGA/3D/display devices
        if echo "$desc" | grep -qiE 'vga|3d|display'; then
            local group
            group=$(echo "$group_dir" | grep -oP 'iommu_groups/\K[0-9]+')
            local driver
            driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci_addr/driver" 2>/dev/null)" 2>/dev/null || echo "none")
            printf "  %-14s Group %-3s Driver: %-12s %s\n" "$pci_addr" "$group" "$driver" "$desc"

            # Show other devices in the same IOMMU group
            local group_path="/sys/kernel/iommu_groups/$group/devices"
            for peer in "$group_path"/*; do
                local peer_addr
                peer_addr=$(basename "$peer")
                if [[ "$peer_addr" != "$pci_addr" ]]; then
                    local peer_desc
                    peer_desc=$(lspci -nns "$peer_addr" 2>/dev/null || echo "")
                    local peer_driver
                    peer_driver=$(basename "$(readlink "/sys/bus/pci/devices/$peer_addr/driver" 2>/dev/null)" 2>/dev/null || echo "none")
                    printf "    %-12s Group %-3s Driver: %-12s %s\n" "$peer_addr" "$group" "$peer_driver" "$peer_desc"
                fi
            done
        fi
    done
}

check_prerequisites() {
    info "Checking VFIO prerequisites..."
    echo ""

    # IOMMU
    if grep -qE '(intel_iommu=on|amd_iommu=on)' /proc/cmdline 2>/dev/null; then
        ok "IOMMU enabled in kernel cmdline"
    else
        err "IOMMU not in kernel cmdline"
        echo "  Add to /etc/default/grub: GRUB_CMDLINE_LINUX=\"intel_iommu=on iommu=pt\""
        echo "  Then: sudo update-grub && sudo reboot"
    fi

    # IOMMU groups
    if [[ -d /sys/kernel/iommu_groups ]]; then
        local count
        count=$(find /sys/kernel/iommu_groups -maxdepth 1 -mindepth 1 -type d | wc -l)
        ok "IOMMU groups: $count"
    else
        err "No IOMMU groups"
    fi

    # vfio modules
    for mod in vfio vfio_pci vfio_iommu_type1; do
        if lsmod | grep -q "^$mod"; then
            ok "Module loaded: $mod"
        else
            warn "Module not loaded: $mod (modprobe $mod)"
        fi
    done
}

bind_vfio() {
    local pci_addr="$1"

    require_root

    # Validate PCI address exists
    if [[ ! -d "/sys/bus/pci/devices/$pci_addr" ]]; then
        die "PCI device not found: $pci_addr"
    fi

    local desc
    desc=$(lspci -nns "$pci_addr" 2>/dev/null || echo "unknown")
    info "Device: $pci_addr $desc"

    # Get vendor:product ID
    local vendor_product
    vendor_product=$(echo "$desc" | grep -oP '\[\K[0-9a-f]{4}:[0-9a-f]{4}' | head -1)
    [[ -n "$vendor_product" ]] || die "Cannot determine vendor:product ID"

    local vendor_id="${vendor_product%%:*}"
    local product_id="${vendor_product##*:}"

    # Check current driver
    local current_driver
    current_driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci_addr/driver" 2>/dev/null)" 2>/dev/null || echo "none")

    if [[ "$current_driver" == "vfio-pci" ]]; then
        ok "Already bound to vfio-pci"
        return
    fi

    info "Current driver: $current_driver"
    info "Binding to vfio-pci..."

    # Load vfio modules
    modprobe vfio-pci 2>/dev/null || true

    # Unbind from current driver
    if [[ "$current_driver" != "none" ]]; then
        echo "$pci_addr" > "/sys/bus/pci/devices/$pci_addr/driver/unbind" 2>/dev/null || true
    fi

    # Bind to vfio-pci
    echo "$vendor_id $product_id" > /sys/bus/pci/drivers/vfio-pci/new_id 2>/dev/null || true
    echo "$pci_addr" > /sys/bus/pci/drivers/vfio-pci/bind 2>/dev/null || true

    # Verify
    local new_driver
    new_driver=$(basename "$(readlink "/sys/bus/pci/devices/$pci_addr/driver" 2>/dev/null)" 2>/dev/null || echo "none")

    if [[ "$new_driver" == "vfio-pci" ]]; then
        ok "Bound $pci_addr to vfio-pci"
        echo ""
        info "To make persistent, add to /etc/modprobe.d/vfio.conf:"
        echo "  options vfio-pci ids=$vendor_id:$product_id"
    else
        die "Failed to bind to vfio-pci (current driver: $new_driver)"
    fi
}

# --- Main ---

case "${1:-help}" in
    --list)   list_gpus ;;
    --check)  check_prerequisites ;;
    --help|-h|help)
        echo "Usage: setup-vfio.sh <PCI_ADDRESS> | --list | --check"
        echo ""
        echo "  <PCI_ADDRESS>   Bind a GPU to vfio-pci (requires root)"
        echo "  --list          List GPUs and IOMMU groups"
        echo "  --check         Check VFIO prerequisites"
        ;;
    *)        bind_vfio "$1" ;;
esac
