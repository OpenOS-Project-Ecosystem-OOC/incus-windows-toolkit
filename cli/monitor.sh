#!/usr/bin/env bash
# VM monitoring and resource statistics.
#
# Usage:
#   monitor.sh <subcommand> [options]
#
# Subcommands:
#   status [name]     Detailed VM status with resource usage
#   stats [name]      Resource statistics (CPU, memory, disk, network)
#   top               Live resource view of all VMs (refreshes every 2s)
#   disk [name]       Disk usage breakdown
#   uptime [name]     VM uptime and boot history
#   health            System-wide health check

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

# --- VM status ---

cmd_status() {
    local vm_name="${1:-$IWT_VM_NAME}"

    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    local info
    info=$(incus info "$vm_name" 2>/dev/null)

    bold "VM: $vm_name"
    echo ""

    # Status
    local status
    status=$(echo "$info" | grep "^Status:" | awk '{print $2}')
    case "$status" in
        Running) ok "  Status: Running" ;;
        Stopped) info "  Status: Stopped" ;;
        *)       info "  Status: $status" ;;
    esac

    # Type
    local vm_type
    vm_type=$(echo "$info" | grep "^Type:" | awk '{print $2}')
    echo "  Type: $vm_type"

    # Architecture
    local arch
    arch=$(echo "$info" | grep "^Architecture:" | awk '{print $2}')
    echo "  Architecture: $arch"

    # Profiles
    local profiles
    profiles=$(echo "$info" | grep "^Profiles:" | sed 's/^Profiles:[[:space:]]*//')
    echo "  Profiles: $profiles"

    # Created
    local created
    created=$(echo "$info" | grep "^Created:" | sed 's/^Created:[[:space:]]*//')
    echo "  Created: $created"

    # Template
    local template
    template=$(incus config get "$vm_name" user.iwt.template 2>/dev/null || echo "")
    if [[ -n "$template" ]]; then
        echo "  Template: $template"
    fi

    # PID
    local pid
    pid=$(echo "$info" | grep "^PID:" | awk '{print $2}')
    if [[ -n "$pid" && "$pid" != "0" ]]; then
        echo "  PID: $pid"
    fi

    if [[ "$status" == "Running" ]]; then
        echo ""
        cmd_stats "$vm_name"
    fi
}

# --- Resource stats ---

cmd_stats() {
    local vm_name="${1:-$IWT_VM_NAME}"

    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    local info
    info=$(incus info "$vm_name" 2>/dev/null)

    local status
    status=$(echo "$info" | grep "^Status:" | awk '{print $2}')

    if [[ "$status" != "Running" ]]; then
        info "$vm_name is not running"
        return 0
    fi

    bold "Resources: $vm_name"
    echo ""

    # CPU
    local cpu_limit
    cpu_limit=$(incus config get "$vm_name" limits.cpu 2>/dev/null || echo "?")
    echo "  CPU: $cpu_limit vCPU(s)"

    # Memory
    local mem_limit
    mem_limit=$(incus config get "$vm_name" limits.memory 2>/dev/null || echo "?")

    # Try to get actual memory usage from state
    local mem_usage mem_peak
    mem_usage=$(incus info "$vm_name" 2>/dev/null | grep -A2 "Memory usage:" | grep "Memory" | awk '{print $NF}' || echo "")
    mem_peak=$(incus info "$vm_name" 2>/dev/null | grep "Memory (peak):" | awk '{print $NF}' || echo "")

    if [[ -n "$mem_usage" ]]; then
        echo "  Memory: ${mem_usage} / ${mem_limit} (peak: ${mem_peak:-?})"
    else
        echo "  Memory: limit ${mem_limit}"
    fi

    # Disk
    local disk_info
    disk_info=$(incus config device get "$vm_name" root size 2>/dev/null || echo "?")
    echo "  Disk: $disk_info allocated"

    # Network
    local net_state
    net_state=$(incus info "$vm_name" 2>/dev/null | grep -A20 "^Network usage:" || true)
    if [[ -n "$net_state" ]]; then
        echo ""
        info "Network:"
        echo "$net_state" | grep -E "Bytes|Packets" | sed 's/^/  /'
    fi

    # IP address
    local ip
    ip=$(incus list "$vm_name" --format csv -c 4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "")
    if [[ -n "$ip" ]]; then
        echo ""
        echo "  IP: $ip"
    fi
}

# --- Top (live view) ---

cmd_top() {
    local interval="${1:-2}"

    if ! command -v watch &>/dev/null; then
        # Fallback: single snapshot
        _top_snapshot
        return
    fi

    watch -n "$interval" -t "$0" _top_snapshot_internal
}

_top_snapshot() {
    bold "IWT VM Monitor"
    echo ""
    printf "  %-20s %-10s %-6s %-10s %-10s %-15s\n" "NAME" "STATUS" "CPU" "MEMORY" "DISK" "IP"
    printf "  %-20s %-10s %-6s %-10s %-10s %-15s\n" "----" "------" "---" "------" "----" "--"

    local vm_list
    vm_list=$(incus list --format csv -c n,s,t 2>/dev/null | grep ",virtual-machine" || true)

    if [[ -z "$vm_list" ]]; then
        info "  No VMs found"
        return
    fi

    while IFS=',' read -r name status _type; do
        local cpu mem disk ip
        cpu=$(incus config get "$name" limits.cpu 2>/dev/null || echo "?")
        mem=$(incus config get "$name" limits.memory 2>/dev/null || echo "?")
        disk=$(incus config device get "$name" root size 2>/dev/null || echo "?")

        if [[ "$status" == "RUNNING" ]]; then
            ip=$(incus list "$name" --format csv -c 4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "-")
            printf "  %-20s \033[32m%-10s\033[0m %-6s %-10s %-10s %-15s\n" "$name" "$status" "$cpu" "$mem" "$disk" "$ip"
        else
            printf "  %-20s %-10s %-6s %-10s %-10s %-15s\n" "$name" "$status" "$cpu" "$mem" "$disk" "-"
        fi
    done <<< "$vm_list"

    echo ""
    local running total
    running=$(echo "$vm_list" | grep -c "RUNNING" || echo "0")
    total=$(echo "$vm_list" | wc -l)
    info "VMs: $running running / $total total"
}

# Internal entry point for watch
_top_snapshot_internal() {
    _top_snapshot
}

# --- Disk usage ---

cmd_disk() {
    local vm_name="${1:-$IWT_VM_NAME}"

    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    bold "Disk Usage: $vm_name"
    echo ""

    # Root disk
    local root_size
    root_size=$(incus config device get "$vm_name" root size 2>/dev/null || echo "unknown")
    local root_pool
    root_pool=$(incus config device get "$vm_name" root pool 2>/dev/null || echo "default")
    echo "  Root disk: $root_size (pool: $root_pool)"

    # Snapshots
    local snap_count
    snap_count=$(incus info "$vm_name" 2>/dev/null | grep -c "snap[0-9]\|iwt-snap" || echo "0")
    echo "  Snapshots: $snap_count"

    # Additional devices
    local devices
    devices=$(incus config device list "$vm_name" 2>/dev/null || true)
    if [[ -n "$devices" ]]; then
        echo ""
        info "Devices:"
        while IFS= read -r dev; do
            [[ -n "$dev" ]] || continue
            local dev_type
            dev_type=$(incus config device get "$vm_name" "$dev" type 2>/dev/null || echo "?")
            local dev_source
            dev_source=$(incus config device get "$vm_name" "$dev" source 2>/dev/null || echo "")
            if [[ -n "$dev_source" ]]; then
                printf "  %-15s %-8s %s\n" "$dev" "$dev_type" "$dev_source"
            else
                printf "  %-15s %s\n" "$dev" "$dev_type"
            fi
        done <<< "$devices"
    fi

    # Cache directory size
    if [[ -d "$IWT_CACHE_DIR" ]]; then
        echo ""
        local cache_size
        cache_size=$(du -sh "$IWT_CACHE_DIR" 2>/dev/null | awk '{print $1}')
        echo "  IWT cache: $cache_size ($IWT_CACHE_DIR)"
    fi

    # Backup directory size
    local backup_dir="${IWT_BACKUP_DIR:-$HOME/.local/share/iwt/backups}"
    if [[ -d "$backup_dir" ]]; then
        local backup_size
        backup_size=$(du -sh "$backup_dir" 2>/dev/null | awk '{print $1}')
        local backup_count
        backup_count=$(find "$backup_dir" -name '*.tar*' 2>/dev/null | wc -l)
        echo "  Backups: $backup_size ($backup_count files)"
    fi
}

# --- Uptime ---

cmd_uptime() {
    local vm_name="${1:-$IWT_VM_NAME}"

    incus info "$vm_name" &>/dev/null || die "VM '$vm_name' not found"

    bold "Uptime: $vm_name"
    echo ""

    local status
    status=$(incus info "$vm_name" 2>/dev/null | grep "^Status:" | awk '{print $2}')

    local created
    created=$(incus info "$vm_name" 2>/dev/null | grep "^Created:" | sed 's/^Created:[[:space:]]*//')
    echo "  Created: $created"

    local last_used
    last_used=$(incus info "$vm_name" 2>/dev/null | grep "^Last Used:" | sed 's/^Last Used:[[:space:]]*//')
    echo "  Last used: $last_used"

    echo "  Status: $status"

    # Snapshot history
    local snaps
    snaps=$(incus info "$vm_name" 2>/dev/null | grep -A1 "Snapshots:" | tail -1 || true)
    if [[ -n "$snaps" && "$snaps" != *"Snapshots:"* ]]; then
        echo ""
        info "Recent snapshots:"
        incus info "$vm_name" 2>/dev/null | sed -n '/^Snapshots:/,/^$/p' | tail -n +2 | head -5 | sed 's/^/  /'
    fi
}

# --- System health ---

cmd_health() {
    bold "IWT System Health"
    echo ""

    # Incus daemon
    if incus info &>/dev/null 2>&1; then
        ok "Incus daemon: reachable"
    else
        err "Incus daemon: not reachable"
    fi

    # KVM
    if [[ -e /dev/kvm ]]; then
        ok "KVM: available"
    else
        err "KVM: /dev/kvm not found"
    fi

    # Storage pools
    local pools
    pools=$(incus storage list --format csv 2>/dev/null | wc -l || echo "0")
    echo "  Storage pools: $pools"

    # Networks
    local networks
    networks=$(incus network list --format csv 2>/dev/null | wc -l || echo "0")
    echo "  Networks: $networks"

    # VM count
    local vm_total vm_running
    vm_total=$(incus list --format csv -c t 2>/dev/null | grep -c "virtual-machine" || echo "0")
    vm_running=$(incus list --format csv -c s,t 2>/dev/null | grep "RUNNING,virtual-machine" | wc -l || echo "0")
    echo "  VMs: $vm_running running / $vm_total total"

    # Disk space
    echo ""
    info "Host disk:"
    df -h / 2>/dev/null | tail -1 | awk '{printf "  Used: %s / %s (%s)\n", $3, $2, $5}'

    # Memory
    info "Host memory:"
    free -h 2>/dev/null | grep "^Mem:" | awk '{printf "  Used: %s / %s\n", $3, $2}' || true

    echo ""
    ok "Health check complete"
}

# --- Help ---

usage() {
    cat <<EOF
iwt vm monitor - VM monitoring and resource statistics

Subcommands:
  status [name]     Detailed VM status with resource usage
  stats [name]      Resource statistics (CPU, memory, disk, network)
  top               Live resource view of all VMs
  disk [name]       Disk usage breakdown
  uptime [name]     VM uptime and boot history
  health            System-wide health check

Options:
  --vm NAME         Target VM (default: \$IWT_VM_NAME)

Examples:
  iwt vm monitor status win11
  iwt vm monitor stats
  iwt vm monitor top
  iwt vm monitor disk win11
  iwt vm monitor health
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        status)           cmd_status "$@" ;;
        stats)            cmd_stats "$@" ;;
        top)              cmd_top "$@" ;;
        disk)             cmd_disk "$@" ;;
        uptime)           cmd_uptime "$@" ;;
        health)           cmd_health ;;
        _top_snapshot_internal) _top_snapshot ;;
        help|--help|-h)   usage ;;
        *)
            err "Unknown monitor subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
