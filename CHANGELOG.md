# Changelog

## v1.0.0

Initial release of the Incus Windows Toolkit.

### Image Pipeline
- Download Windows ISOs from Microsoft (10, 11, Server 2019-2025)
- ARM64 ISO acquisition via UUP dump API with local conversion
- Build Incus-ready images with VirtIO driver injection
- Bloatware removal (tiny11-style) using wimlib
- Unattended answer file generation
- VirtIO driver management (`iwt image drivers`)

### VM Management
- Create VMs from templates: gaming, dev, server, minimal
- Start, stop, status, list operations
- Full RDP desktop sessions via FreeRDP
- Guest tool installation (WinFsp, VirtIO guest tools) via agent
- First-boot PowerShell hooks from templates or user scripts

### Device Passthrough
- GPU: VFIO passthrough, Looking Glass (IVSHMEM), SR-IOV, mdev
- USB: hotplug attach/detach by vendor:product ID
- Shared folders: virtiofs/9p with WinFsp drive letter mounting

### Networking
- Port forwarding (add, remove, list)
- NIC management (add, remove)

### Snapshots
- Create, restore, delete snapshots
- Auto-snapshot scheduling with expiry

### Backup & Export
- Full VM backup as compressed tarball
- Export as reusable Incus image
- Import from backup or image file

### RemoteApp
- Launch Windows apps as seamless Linux windows
- Generate .desktop entries for Linux app menus
- App discovery and icon extraction

### Fleet Management
- Multi-VM orchestration (start-all, stop-all, backup-all)
- Fleet status overview
- Execute commands across all running VMs

### Monitoring
- VM resource statistics (CPU, memory, disk, network)
- Disk usage breakdown
- Uptime and boot history
- System health check

### Profiles
- x86_64: windows-desktop, windows-server
- ARM64: windows-desktop, windows-server
- GPU overlays: vfio-passthrough, looking-glass, sriov-gpu, mdev-virtual-gpu

### User Interface
- CLI with bash/zsh completion
- Interactive TUI (dialog/whiptail)
- `iwt doctor` prerequisite checker

### Packaging
- `make install/uninstall` with DESTDIR support
- Man page source (pandoc)
- AUR PKGBUILD, Debian control, RPM spec
