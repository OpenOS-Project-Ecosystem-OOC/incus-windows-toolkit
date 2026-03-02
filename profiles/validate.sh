#!/usr/bin/env bash
# Validate IWT profile YAML files for structural correctness.
# Checks that required fields are present and values are sane.
#
# Usage: validate.sh [profile.yaml ...]
#        validate.sh  (validates all profiles)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IWT_ROOT="$(dirname "$SCRIPT_DIR")"
source "$IWT_ROOT/cli/lib.sh"

errors=0
warnings=0
checked=0

validate_profile() {
    local file="$1"
    local name
    name=$(basename "$file" .yaml)
    local arch_dir
    arch_dir=$(basename "$(dirname "$file")")

    checked=$((checked + 1))

    # Check YAML syntax (basic -- look for required keys)
    if ! grep -q "^description:" "$file"; then
        err "$file: missing 'description' field"
        errors=$((errors + 1))
    fi

    # GPU overlay profiles only need description + devices
    if [[ "$arch_dir" != "gpu" ]]; then
        if ! grep -q "^config:" "$file"; then
            err "$file: missing 'config' section"
            errors=$((errors + 1))
            return
        fi
    fi

    if ! grep -q "^devices:" "$file" && ! grep -q "devices:" "$file"; then
        err "$file: missing 'devices' section"
        errors=$((errors + 1))
        return
    fi

    # GPU overlay profiles have different requirements than base profiles
    local is_gpu_overlay=false
    if [[ "$arch_dir" == "gpu" ]]; then
        is_gpu_overlay=true
    fi

    if [[ "$is_gpu_overlay" == true ]]; then
        # GPU profiles must have a gpu device
        if ! grep -q "gpu:" "$file" && ! grep -q "gputype:" "$file"; then
            err "$file: GPU profile missing 'gpu' device"
            errors=$((errors + 1))
        fi

        # Validate gputype is a known value
        local gputype
        gputype=$(grep "gputype:" "$file" | awk '{print $2}' | head -1)
        if [[ -n "$gputype" ]]; then
            case "$gputype" in
                physical|mdev|sriov) ;;
                *)
                    err "$file: unknown gputype '$gputype' (must be physical, mdev, or sriov)"
                    errors=$((errors + 1))
                    ;;
            esac
        fi
    else
        # Base profile checks
        local required_configs=(
            "security.secureboot"
            "limits.cpu"
            "limits.memory"
        )

        for key in "${required_configs[@]}"; do
            if ! grep -q "$key:" "$file"; then
                err "$file: missing config key '$key'"
                errors=$((errors + 1))
            fi
        done

        # Check required devices
        if ! grep -q "root:" "$file"; then
            err "$file: missing 'root' disk device"
            errors=$((errors + 1))
        fi

        if ! grep -q "eth0:" "$file" && ! grep -q "nic" "$file"; then
            warn "$file: no network device found"
            warnings=$((warnings + 1))
        fi

        # Architecture-specific checks
        if [[ "$arch_dir" == "x86_64" ]]; then
            if ! grep -q "hv_" "$file"; then
                warn "$file: x86_64 profile missing Hyper-V enlightenments (hv_*)"
                warnings=$((warnings + 1))
            fi
        fi

        if [[ "$arch_dir" == "arm64" ]]; then
            if grep -q "hv_" "$file"; then
                err "$file: ARM64 profile should not have Hyper-V enlightenments"
                errors=$((errors + 1))
            fi
        fi

        # Desktop profiles should have a display device
        if [[ "$name" == *desktop* ]]; then
            if ! grep -q "display:" "$file" && ! grep -q "gpu" "$file"; then
                warn "$file: desktop profile missing display/gpu device"
                warnings=$((warnings + 1))
            fi
        fi

        # TPM check for Windows 11
        if ! grep -q "tpm:" "$file"; then
            warn "$file: missing TPM device (required for Windows 11)"
            warnings=$((warnings + 1))
        fi
    fi

    ok "$arch_dir/$name"
}

# Determine which files to validate
files=()
if [[ $# -gt 0 ]]; then
    files=("$@")
else
    while IFS= read -r -d '' f; do
        files+=("$f")
    done < <(find "$SCRIPT_DIR" -name '*.yaml' -print0 | sort -z)
fi

if [[ ${#files[@]} -eq 0 ]]; then
    die "No profile files found"
fi

info "Validating ${#files[@]} profile(s)..."
echo ""

for f in "${files[@]}"; do
    validate_profile "$f"
done

echo ""
info "Checked: $checked | Errors: $errors | Warnings: $warnings"

if [[ $errors -gt 0 ]]; then
    exit 1
fi
