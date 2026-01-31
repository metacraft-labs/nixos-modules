# Desktop VMs Module

A NixOS module for declarative, high-performance desktop virtual machines using libvirt/QEMU/KVM.

## Features

- **Two usage profiles**: Choose between maximum performance or flexible memory management
- **CPU pinning**: Dedicate host CPU cores to VMs for consistent performance
- **Hugepages**: Optional static hugepage allocation for reduced memory latency
- **Memory ballooning**: Dynamic memory sizing with autodeflate and free page reporting
- **VirtIO-FS**: Fast host-guest file sharing
- **Display options**: SPICE, VNC, or Looking Glass
- **Windows 11 support**: TPM 2.0 emulation and Secure Boot
- **Convenience scripts**: Auto-generated `vm-<name>` commands for each VM

## Quick Start

```nix
# In your NixOS configuration
{ config, ... }:
{
  virtualisation.desktopVMs = {
    enable = true;
    profile = "occasional";  # or "always-on"

    vms.my-windows-vm = {
      enable = true;
      memory = "16G";
      vcpus = 4;
      osType = "windows";
    };
  };
}
```

## Profiles

The `profile` option provides sensible defaults for common use cases:

### `"occasional"` (default)

Best for VMs that run infrequently or on memory-constrained hosts.

| Setting | Value | Rationale |
|---------|-------|-----------|
| `hugepages.enable` | `false` | Memory available when VM is off |
| `autoStart` | `false` | VMs started manually |
| `memballoon.autodeflate` | `true` | Prevents guest OOM crashes |
| `memballoon.freePageReporting` | `true` | Host can reclaim unused pages |

**Trade-offs:**
- ~2-3% lower performance than static hugepages
- Memory dynamically allocated/freed
- Full ballooning support

### `"always-on"`

Best for VMs that run frequently or continuously (gaming, development workstations).

| Setting | Value | Rationale |
|---------|-------|-----------|
| `hugepages.enable` | `true` | Maximum performance |
| `autoStart` | `true` | VMs start at boot |
| `memballoon.autodeflate` | `false` | N/A with hugepages |
| `memballoon.freePageReporting` | `false` | N/A with hugepages |

**Trade-offs:**
- Memory permanently reserved at boot
- No dynamic sizing (ballooning ineffective)
- Best TLB performance

## Configuration Reference

### Global Options

```nix
virtualisation.desktopVMs = {
  enable = true;

  # Usage profile (sets defaults for other options)
  profile = "occasional";  # or "always-on"

  # Static hugepages configuration
  # Default: enabled for "always-on", disabled for "occasional"
  hugepages = {
    enable = true;
    size = "2M";      # or "1G" for gigabyte pages
    count = 8192;     # total_vm_memory / hugepage_size
  };

  # Firewall ports
  firewallPorts = {
    spice = true;     # Open 5900-5999 for SPICE
    vnc = false;      # Open 5900-5999 for VNC
  };

  # Storage configuration
  defaultStoragePool = "default";
  defaultStoragePath = "/var/lib/libvirt/images";
};
```

### Per-VM Options

```nix
virtualisation.desktopVMs.vms.my-vm = {
  enable = true;

  # Identity
  uuid = "550e8400-e29b-41d4-a716-446655440000";  # optional, fixed UUID

  # Resources
  memory = "16G";
  vcpus = 8;
  diskSize = "200G";
  storagePool = "default";

  # CPU pinning (optional, for performance)
  cpuPinning = [
    "0-1"   # vCPU 0 -> host CPUs 0-1
    "2-3"   # vCPU 1 -> host CPUs 2-3
    "4-5"   # vCPU 2 -> host CPUs 4-5
    "6-7"   # vCPU 3 -> host CPUs 6-7
  ];

  # Display
  display = "spice";  # or "vnc" or "looking-glass"

  # Shared folders (VirtIO-FS)
  sharedFolders = {
    projects = "/home/user/projects";
    downloads = "/home/user/Downloads";
  };

  # OS type (affects optimizations)
  osType = "windows";  # or "linux" or "macos"

  # Windows 11 requirements
  tpm = true;
  secureBoot = true;

  # Startup behavior (default depends on profile)
  autoStart = false;

  # Memory balloon configuration
  memballoon = {
    enable = true;
    autodeflate = true;        # Release memory before OOM
    freePageReporting = true;  # Report free pages to host
    statsInterval = 5;         # Stats polling in seconds (0 = disabled)
  };

  # Additional libvirt XML (for PCI passthrough, etc.)
  extraDevices = ''
    <hostdev mode="subsystem" type="pci" managed="yes">
      <source>
        <address domain="0x0000" bus="0x01" slot="0x00" function="0x0"/>
      </source>
    </hostdev>
  '';
};
```

## VM Management

Each enabled VM gets a convenience script `vm-<name>`:

```bash
# Basic operations
vm-my-vm start        # Start the VM
vm-my-vm stop         # Graceful shutdown
vm-my-vm force-stop   # Force stop (like pulling power)
vm-my-vm status       # Show VM info

# Display
vm-my-vm view         # Open virt-viewer
vm-my-vm console      # Serial console

# Memory (only effective with "occasional" profile)
vm-my-vm memstats     # View memory statistics
vm-my-vm setmem 8G    # Adjust memory dynamically

# Network
vm-my-vm ssh          # SSH to VM (requires QEMU guest agent)
```

You can also use standard virsh commands:

```bash
virsh list --all           # List all VMs
virsh start my-vm          # Start VM
virsh shutdown my-vm       # Graceful shutdown
virsh dommemstat my-vm     # Memory statistics
virsh setmem my-vm 8G      # Adjust memory
```

## Hugepages Calculation

For static hugepages, calculate the count based on total VM memory:

```
count = total_vm_memory_bytes / hugepage_size_bytes
```

Examples with 2MB pages:
- 8GB VM: `8 * 1024 / 2 = 4096` pages
- 16GB VM: `16 * 1024 / 2 = 8192` pages
- 24GB VM: `24 * 1024 / 2 = 12288` pages

**Warning:** Hugepages are reserved at boot and unavailable to the host, even when VMs are not running.

## VirtIO-FS Setup

### Linux Guest

```bash
# Mount a shared folder
sudo mount -t virtiofs projects /mnt/projects

# Add to /etc/fstab for persistent mount
projects /mnt/projects virtiofs defaults 0 0
```

### Windows Guest

1. Install [WinFsp](https://winfsp.dev/)
2. Install the virtio-fs driver from [virtio-win](https://github.com/virtio-win/virtio-win-pkg-scripts)
3. Start the VirtioFsSvc service
4. Shared folders appear as network drives

## Memory Ballooning

Memory ballooning allows dynamic adjustment of VM memory. It works by "inflating" a balloon inside the guest to reclaim memory.

### Viewing Statistics

```bash
vm-my-vm memstats
# or
virsh dommemstat my-vm
```

Key statistics:
- `actual`: Current memory available to guest
- `unused`: Free memory (MemFree)
- `usable`: Available memory (MemAvailable)
- `rss`: Host memory used by QEMU process
- `swap_in/swap_out`: Guest swap activity

### Dynamic Sizing

```bash
# Reduce memory to 8GB
vm-my-vm setmem 8G

# Increase back to 16GB
vm-my-vm setmem 16G
```

**Note:** Ballooning is not effective with static hugepages. Use the `"occasional"` profile for dynamic memory sizing.

### Autodeflate

When `autodeflate = true`, the balloon automatically releases memory when the guest experiences memory pressure, preventing OOM crashes.

### Free Page Reporting

When `freePageReporting = true`, the guest periodically reports free pages to the host, allowing the host to reclaim them without actively inflating the balloon.

## Troubleshooting

### VM won't start with hugepages

Check available hugepages:
```bash
grep -i huge /proc/meminfo
```

Ensure the count is sufficient. If not, hugepages may have failed to allocate at boot due to memory fragmentation. Try rebooting.

### Memory ballooning has no effect

With static hugepages, memory cannot be dynamically reclaimed. Switch to `profile = "occasional"` or explicitly set `hugepages.enable = false`.

### VirtIO-FS not working

1. Ensure the guest has virtio-fs drivers installed
2. Check that virtiofsd is running on the host
3. Verify the shared folder path exists on the host

### SPICE display not connecting

1. Check firewall: `sudo iptables -L | grep 590`
2. Ensure `firewallPorts.spice = true`
3. Try connecting locally first: `virt-viewer --connect qemu:///system my-vm`

## See Also

- [Virtualisation Overview](./index.md) - Overview of all VM modules
- [VM Images](./vm-images.md) - Building VM images for CI/CD and testing
- [Automation Engine](./automation-engine.md) - GUI automation for unattended installation

## References

- [Libvirt Domain XML Format](https://libvirt.org/formatdomain.html)
- [Memory Balloon Device](https://libvirt.org/formatdomain.html#memory-balloon-device)
- [QEMU Performance Tuning](https://www.qemu.org/docs/master/system/i386/cpu.html)
- [VirtIO-FS](https://virtio-fs.gitlab.io/)
- [Looking Glass](https://looking-glass.io/)
- [Hugepages on Linux](https://www.kernel.org/doc/html/latest/admin-guide/mm/hugetlbpage.html)
