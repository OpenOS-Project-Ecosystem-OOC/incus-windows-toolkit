#!/usr/bin/env bash
# Multi-VM orchestration for fleet management.
#
# Usage:
#   fleet.sh <subcommand> [options]
#
# Subcommands:
#   list              List all IWT-managed VMs
#   start-all         Start all stopped VMs
#   stop-all          Stop all running VMs
#   backup-all        Backup all VMs
#   status            Show status of all VMs
#   exec <cmd>        Run a command on all running VMs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$IWT_ROOT/cli/lib.sh"
load_config

# --- Helpers ---

# List all VMs (optionally filtered by status)
get_vms() {
    local filter="${1:-all}"
    local vm_list
    vm_list=$(incus list --format csv -c n,s,t 2>/dev/null | grep ",virtual-machine" || true)

    if [[ -z "$vm_list" ]]; then
        return
    fi

    case "$filter" in
        running)
            echo "$vm_list" | grep ",RUNNING," | cut -d',' -f1
            ;;
        stopped)
            echo "$vm_list" | grep ",STOPPED," | cut -d',' -f1
            ;;
        all)
            echo "$vm_list" | cut -d',' -f1
            ;;
    esac
}

# --- List ---

cmd_list() {
    bold "IWT-Managed VMs"
    echo ""
    printf "  %-20s %-10s %-8s %-10s %-10s %-15s\n" "NAME" "STATUS" "TEMPLATE" "CPU" "MEMORY" "IP"
    printf "  %-20s %-10s %-8s %-10s %-10s %-15s\n" "----" "------" "--------" "---" "------" "--"

    local vm_list
    vm_list=$(incus list --format csv -c n,s,t 2>/dev/null | grep ",virtual-machine" || true)

    if [[ -z "$vm_list" ]]; then
        info "  No VMs found"
        return
    fi

    local total=0 running=0
    while IFS=',' read -r name status _type; do
        total=$((total + 1))
        local template cpu mem ip

        template=$(incus config get "$name" user.iwt.template 2>/dev/null || echo "-")
        cpu=$(incus config get "$name" limits.cpu 2>/dev/null || echo "?")
        mem=$(incus config get "$name" limits.memory 2>/dev/null || echo "?")

        if [[ "$status" == "RUNNING" ]]; then
            running=$((running + 1))
            ip=$(incus list "$name" --format csv -c 4 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || echo "-")
            printf "  %-20s \033[32m%-10s\033[0m %-8s %-10s %-10s %-15s\n" "$name" "$status" "$template" "$cpu" "$mem" "$ip"
        else
            printf "  %-20s %-10s %-8s %-10s %-10s %-15s\n" "$name" "$status" "$template" "$cpu" "$mem" "-"
        fi
    done <<< "$vm_list"

    echo ""
    info "Total: $running running / $total VMs"
}

# --- Start all ---

cmd_start_all() {
    local vms
    vms=$(get_vms stopped)

    if [[ -z "$vms" ]]; then
        info "No stopped VMs to start"
        return
    fi

    local count=0
    while IFS= read -r vm; do
        [[ -n "$vm" ]] || continue
        info "Starting: $vm"
        incus start "$vm" && ok "  Started: $vm" || warn "  Failed to start: $vm"
        count=$((count + 1))
    done <<< "$vms"

    ok "Started $count VM(s)"
}

# --- Stop all ---

cmd_stop_all() {
    local force=false
    [[ "${1:-}" == "--force" || "${1:-}" == "-f" ]] && force=true

    local vms
    vms=$(get_vms running)

    if [[ -z "$vms" ]]; then
        info "No running VMs to stop"
        return
    fi

    local count=0
    while IFS= read -r vm; do
        [[ -n "$vm" ]] || continue
        info "Stopping: $vm"
        if [[ "$force" == true ]]; then
            incus stop "$vm" --force && ok "  Stopped: $vm" || warn "  Failed to stop: $vm"
        else
            incus stop "$vm" && ok "  Stopped: $vm" || warn "  Failed to stop: $vm"
        fi
        count=$((count + 1))
    done <<< "$vms"

    ok "Stopped $count VM(s)"
}

# --- Backup all ---

cmd_backup_all() {
    local output_dir="${IWT_BACKUP_DIR:-$HOME/.local/share/iwt/backups}"
    mkdir -p "$output_dir"

    local vms
    vms=$(get_vms all)

    if [[ -z "$vms" ]]; then
        info "No VMs to backup"
        return
    fi

    local count=0 failed=0
    while IFS= read -r vm; do
        [[ -n "$vm" ]] || continue
        info "Backing up: $vm"
        if "$IWT_ROOT/cli/backup.sh" create "$vm" 2>&1 | tail -1; then
            count=$((count + 1))
        else
            warn "  Failed to backup: $vm"
            failed=$((failed + 1))
        fi
    done <<< "$vms"

    echo ""
    ok "Backed up $count VM(s)"
    if [[ $failed -gt 0 ]]; then
        warn "$failed backup(s) failed"
    fi
}

# --- Status ---

cmd_status() {
    source "$IWT_ROOT/cli/monitor.sh"
    _top_snapshot
}

# --- Exec on all ---

cmd_exec_all() {
    [[ $# -gt 0 ]] || die "Usage: iwt fleet exec <command>"

    local vms
    vms=$(get_vms running)

    if [[ -z "$vms" ]]; then
        info "No running VMs"
        return
    fi

    while IFS= read -r vm; do
        [[ -n "$vm" ]] || continue
        bold "[$vm]"
        incus exec "$vm" -- "$@" 2>&1 | sed 's/^/  /' || warn "  Command failed on $vm"
        echo ""
    done <<< "$vms"
}

# --- Help ---

usage() {
    cat <<EOF
iwt fleet - Multi-VM orchestration

Subcommands:
  list              List all VMs with status and resources
  start-all         Start all stopped VMs
  stop-all          Stop all running VMs (--force for immediate)
  backup-all        Backup all VMs
  status            Overview of all VMs (same as monitor top)
  exec <cmd>        Run a command on all running VMs

Examples:
  iwt fleet list
  iwt fleet start-all
  iwt fleet stop-all --force
  iwt fleet backup-all
  iwt fleet exec cmd /c hostname
  iwt fleet exec powershell -Command "Get-Date"
EOF
}

# --- Main ---

main() {
    local subcmd="${1:-help}"
    shift || true

    case "$subcmd" in
        list|ls)        cmd_list ;;
        start-all)      cmd_start_all ;;
        stop-all)       cmd_stop_all "$@" ;;
        backup-all)     cmd_backup_all ;;
        status)         cmd_status ;;
        exec)           cmd_exec_all "$@" ;;
        help|--help|-h) usage ;;
        *)
            err "Unknown fleet subcommand: $subcmd"
            usage
            exit 1
            ;;
    esac
}

main "$@"
