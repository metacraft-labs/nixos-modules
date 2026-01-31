# NixOS Module for High-Performance Desktop VMs
#
# This module provides declarative configuration for high-performance desktop VMs
# using libvirt/QEMU with optimizations for gaming, development, and desktop workloads.
#
# Key features:
# - Two usage profiles: "always-on" (max performance) vs "occasional" (flexible memory)
# - CPU pinning for consistent performance
# - Hugepages memory backing for reduced latency (always-on profile)
# - Memory ballooning for dynamic sizing (occasional profile)
# - VirtIO-FS for fast host-guest file sharing
# - SPICE/VNC/Looking Glass display options
# - Windows 11 support with TPM 2.0 and Secure Boot
# - Per-VM resource allocation and configuration
#
# Example usage:
#   virtualisation.desktopVMs = {
#     enable = true;
#     profile = "always-on";  # or "occasional"
#     vms.windows-dev = {
#       enable = true;
#       memory = "16G";
#       vcpus = 8;
#       cpuPinning = [ "0-1" "2-3" "4-5" "6-7" "8-9" "10-11" "12-13" "14-15" ];
#       sharedFolders.projects = "/home/user/projects";
#       osType = "windows";
#     };
#   };
#
# Profile descriptions:
#   "always-on": Best for VMs that run frequently or continuously.
#     - Uses static hugepages (reserved at boot, best performance)
#     - Memory is permanently allocated to the VM subsystem
#     - No dynamic memory sizing (ballooning disabled)
#     - VMs can auto-start at boot
#
#   "occasional": Best for VMs that run infrequently.
#     - Uses Transparent Hugepages (dynamic, slightly lower performance)
#     - Memory is available to host when VM is not running
#     - Full memory ballooning support for dynamic sizing
#     - Host can reclaim unused VM memory
#
# References:
# - Libvirt documentation: https://libvirt.org/
# - QEMU performance tuning: https://www.qemu.org/docs/master/system/i386/cpu.html
# - VirtIO-FS: https://virtio-fs.gitlab.io/
# - Looking Glass: https://looking-glass.io/
# - Memory ballooning: https://www.libvirt.org/formatdomain.html#memory-balloon-device
{ ... }:
{
  flake.modules.nixos.desktop-vms =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      inherit (lib)
        mkEnableOption
        mkOption
        mkIf
        mkMerge
        mkDefault
        types
        mapAttrs
        mapAttrsToList
        filterAttrs
        optionalString
        literalExpression
        ;

      cfg = config.virtualisation.desktopVMs;

      # Import our library functions
      vmLib = import ./desktop-vms/lib.nix { inherit lib; };

      # OVMF paths for UEFI boot
      ovmfPackage = pkgs.OVMF.override { secureBoot = true; tpmSupport = true; };
      ovmfCodePath = "${ovmfPackage.fd}/FV/OVMF_CODE.fd";
      ovmfVarsPath = "${ovmfPackage.fd}/FV/OVMF_VARS.fd";

      # Profile-based defaults
      # These are applied via mkDefault so users can override individual settings
      profileDefaults = {
        # "always-on" profile: Maximum performance, static resource allocation
        # Best for: Gaming VMs, development workstations, VMs that run daily
        # Trade-off: Memory reserved even when VM is off
        always-on = {
          hugepages.enable = true;
          vm = {
            autoStart = true;
            memballoon = {
              enable = true;  # Keep memballoon for stats, but no dynamic sizing
              autodeflate = false;  # Not useful with hugepages
              freePageReporting = false;  # Not compatible with hugepages
              statsInterval = 5;
            };
          };
        };

        # "occasional" profile: Flexible memory, dynamic allocation
        # Best for: Testing VMs, infrequent use, memory-constrained hosts
        # Trade-off: ~2-3% lower performance than static hugepages
        occasional = {
          hugepages.enable = false;  # Use THP instead
          vm = {
            autoStart = false;
            memballoon = {
              enable = true;
              autodeflate = true;  # Release memory before OOM
              freePageReporting = true;  # Report free pages to host
              statsInterval = 5;
            };
          };
        };
      };

      # Get defaults for current profile
      currentProfileDefaults = profileDefaults.${cfg.profile};

      # Filter enabled VMs
      enabledVMs = filterAttrs (name: vmCfg: vmCfg.enable) cfg.vms;

      # Generate domain XML for a VM
      generateVmXml = name: vmCfg:
        vmLib.generateDomainXml {
          inherit name;
          uuid = vmCfg.uuid;
          memory = vmCfg.memory;
          vcpus = vmCfg.vcpus;
          cpuPinning = vmCfg.cpuPinning;
          hugepages = cfg.hugepages.enable;
          sharedFolders = vmCfg.sharedFolders;
          display = vmCfg.display;
          diskPool = vmCfg.storagePool;
          diskVolume = "${name}.qcow2";
          osType = vmCfg.osType;
          tpm = vmCfg.tpm;
          secureBoot = vmCfg.secureBoot;
          inherit ovmfCodePath ovmfVarsPath;
          nvramPath = "/var/lib/libvirt/qemu/nvram/${name}_VARS.fd";
          extraDevices = vmCfg.extraDevices;
          # Memballoon configuration
          memballoon = vmCfg.memballoon;
        };

      # Write domain XML to a file
      vmDomainXmlFile = name: vmCfg:
        pkgs.writeText "${name}-domain.xml" (generateVmXml name vmCfg);

      # Memballoon submodule for per-VM memory balloon configuration
      memballoonSubmodule = types.submodule {
        options = {
          enable = mkOption {
            type = types.bool;
            default = currentProfileDefaults.vm.memballoon.enable;
            description = ''
              Enable the virtio memory balloon device.

              The balloon device allows the host to reclaim unused memory from the guest.
              It also provides memory statistics to the host.

              Note: Memory ballooning is not effective when using static hugepages,
              as hugepages cannot be dynamically reclaimed.

              Reference: https://www.libvirt.org/formatdomain.html#memory-balloon-device
            '';
          };

          autodeflate = mkOption {
            type = types.bool;
            default = currentProfileDefaults.vm.memballoon.autodeflate;
            description = ''
              Automatically deflate the balloon (return memory to guest) when the
              guest is under memory pressure, before the OOM killer activates.

              This prevents the guest from crashing due to memory starvation when
              the balloon has been inflated.

              Only effective when not using static hugepages.
              Requires QEMU 2.1+ and libvirt 1.3.1+.

              Reference: https://www.qemu.org/docs/master/interop/virtio-balloon-stats.html
            '';
          };

          freePageReporting = mkOption {
            type = types.bool;
            default = currentProfileDefaults.vm.memballoon.freePageReporting;
            description = ''
              Enable free page reporting (also known as free page hinting).

              The guest periodically reports pages that are free to the host,
              allowing the host to reclaim them for other uses. This improves
              memory overcommit efficiency without actively inflating the balloon.

              Not compatible with static hugepages.
              Requires QEMU 5.1+ and libvirt 6.9+.

              Reference: https://www.qemu.org/docs/master/interop/virtio-balloon-stats.html
            '';
          };

          statsInterval = mkOption {
            type = types.int;
            default = currentProfileDefaults.vm.memballoon.statsInterval;
            description = ''
              Interval in seconds for collecting memory statistics from the guest.
              Set to 0 to disable statistics collection.

              Statistics can be viewed with: virsh dommemstat <domain>

              Available stats include:
              - actual: Current balloon size
              - unused: Free memory in guest (MemFree)
              - usable: Available memory in guest (MemAvailable)
              - rss: Resident set size on host
              - swap_in/swap_out: Swap activity
            '';
            example = 10;
          };
        };
      };

      # VM submodule type definition
      vmSubmodule = types.submodule ({ name, ... }: {
        options = {
          enable = mkEnableOption "this VM";

          uuid = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Fixed UUID for the VM. If not specified, libvirt will generate one.
              Use a fixed UUID if you need consistent VM identity across rebuilds.

              Generate with: uuidgen
            '';
            example = "550e8400-e29b-41d4-a716-446655440000";
          };

          memory = mkOption {
            type = types.str;
            default = "8G";
            description = ''
              Amount of memory allocated to the VM.
              Accepts formats like "8G", "8GiB", "16384M", "16384MiB".

              For the "always-on" profile with hugepages, ensure this is a multiple
              of the hugepage size. With 2MB hugepages, use values like 8G, 16G, 24G.

              For the "occasional" profile, the VM can dynamically adjust memory
              usage via ballooning.
            '';
            example = "16G";
          };

          vcpus = mkOption {
            type = types.int;
            default = 4;
            description = ''
              Number of virtual CPUs allocated to the VM.

              For best performance with CPU pinning, match this to the number
              of physical cores you want to dedicate (or 2x for hyperthreading).
            '';
            example = 8;
          };

          diskSize = mkOption {
            type = types.str;
            default = "100G";
            description = ''
              Size of the VM's primary disk image.
              Only used when creating a new disk; existing disks are not resized.
            '';
            example = "256G";
          };

          storagePool = mkOption {
            type = types.str;
            default = "default";
            description = ''
              Libvirt storage pool where the VM disk will be stored.
              The default pool uses /var/lib/libvirt/images.
            '';
          };

          cpuPinning = mkOption {
            type = types.nullOr (types.listOf types.str);
            default = null;
            description = ''
              CPU pinning configuration for consistent performance.
              Each element is a cpuset string for one vCPU.

              The list length should match the vcpus count.
              Use lscpu to identify your CPU topology and choose appropriate cores.

              For best performance, pin to physical cores on the same NUMA node
              and avoid cores shared with the host (e.g., core 0).
            '';
            example = literalExpression ''
              [
                "0-1"   # vCPU 0 can use host CPUs 0-1
                "2-3"   # vCPU 1 can use host CPUs 2-3
                "4-5"   # vCPU 2 can use host CPUs 4-5
                "6-7"   # vCPU 3 can use host CPUs 6-7
              ]
            '';
          };

          display = mkOption {
            type = types.enum [ "spice" "vnc" "looking-glass" ];
            default = "spice";
            description = ''
              Display technology for the VM.

              - spice: Best for remote access, supports clipboard/audio/USB
              - vnc: Simple remote display, widely compatible
              - looking-glass: Near-native performance for local display
                (requires additional Looking Glass setup on host and guest)

              Reference: https://looking-glass.io/
            '';
          };

          sharedFolders = mkOption {
            type = types.attrsOf types.path;
            default = { };
            description = ''
              VirtIO-FS shared folders for fast host-guest file sharing.
              Keys are mount names visible to the guest, values are host paths.

              In Windows guests, use WinFsp and virtio-fs driver to mount.
              In Linux guests, mount with: mount -t virtiofs <name> /mnt/point

              Reference: https://virtio-fs.gitlab.io/
            '';
            example = literalExpression ''
              {
                projects = "/home/user/projects";
                downloads = "/home/user/Downloads";
              }
            '';
          };

          osType = mkOption {
            type = types.enum [ "windows" "linux" "macos" ];
            default = "windows";
            description = ''
              Operating system type, used for OS-specific optimizations.

              - windows: Enables Hyper-V enlightenments, Windows clock, TPM
              - linux: Standard KVM optimizations
              - macos: macOS-specific tweaks (experimental)
            '';
          };

          tpm = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Enable TPM 2.0 emulation via swtpm.
              Required for Windows 11 without registry bypass.

              The module automatically enables swtpm when any VM needs TPM.
            '';
          };

          secureBoot = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Enable UEFI Secure Boot.
              Requires OVMF with Secure Boot support.

              Some older operating systems may not support Secure Boot.
            '';
          };

          autoStart = mkOption {
            type = types.bool;
            default = currentProfileDefaults.vm.autoStart;
            description = ''
              Start this VM automatically when the host boots.

              Default depends on the profile:
              - "always-on": true (VM is expected to run continuously)
              - "occasional": false (VM started manually when needed)
            '';
          };

          memballoon = mkOption {
            type = memballoonSubmodule;
            default = { };
            description = ''
              Memory balloon device configuration for dynamic memory management.

              The balloon device allows the host to reclaim unused memory from guests
              and provides memory statistics. Settings depend on the profile:

              - "always-on" profile: Balloon enabled for stats only, no dynamic sizing
                (hugepages prevent memory reclamation)
              - "occasional" profile: Full ballooning with autodeflate and free page
                reporting for efficient memory sharing

              Reference: https://www.libvirt.org/formatdomain.html#memory-balloon-device
            '';
          };

          extraDevices = mkOption {
            type = types.lines;
            default = "";
            description = ''
              Additional libvirt XML device definitions to include.
              Use this for PCI passthrough, additional disks, etc.
            '';
            example = literalExpression ''
              '''
                <!-- GPU passthrough example -->
                <hostdev mode="subsystem" type="pci" managed="yes">
                  <source>
                    <address domain="0x0000" bus="0x01" slot="0x00" function="0x0"/>
                  </source>
                </hostdev>
              '''
            '';
          };
        };
      });

    in
    {
      options.virtualisation.desktopVMs = {
        enable = mkEnableOption ''
          high-performance desktop VM infrastructure.

          This enables libvirtd with QEMU/KVM, OVMF for UEFI boot,
          swtpm for TPM emulation, and virtiofsd for shared folders.
        '';

        profile = mkOption {
          type = types.enum [ "always-on" "occasional" ];
          default = "occasional";
          description = ''
            Usage profile that sets sensible defaults for VM configuration.

            **"always-on"** - Best for VMs that run frequently or continuously:
            - Static hugepages for maximum performance (~2-5% faster)
            - Memory permanently reserved at boot (unavailable to host)
            - VMs auto-start at boot by default
            - Memory ballooning disabled (incompatible with hugepages)
            - Best for: gaming VMs, daily-use development workstations

            **"occasional"** - Best for VMs that run infrequently:
            - Transparent Hugepages for dynamic allocation
            - Memory available to host when VM is not running
            - VMs started manually by default
            - Full memory ballooning with autodeflate and free page reporting
            - Best for: testing, occasional use, memory-constrained hosts

            Individual settings can be overridden regardless of profile.
          '';
          example = "always-on";
        };

        hugepages = {
          enable = mkOption {
            type = types.bool;
            default = currentProfileDefaults.hugepages.enable;
            description = ''
              Use static hugepages for VM memory backing.

              **Benefits:**
              - Lower memory access latency (reduced TLB misses)
              - ~2-5% performance improvement for memory-intensive workloads
              - Memory cannot be swapped (consistent performance)

              **Trade-offs:**
              - Memory reserved at boot, unavailable to host even when VM is off
              - Incompatible with memory ballooning (no dynamic sizing)
              - Incompatible with KSM (Kernel Same-page Merging)

              Default depends on profile:
              - "always-on": true
              - "occasional": false (uses Transparent Hugepages instead)

              When disabled, QEMU uses Transparent Hugepages (THP) which provide
              most of the performance benefit while allowing dynamic memory management.
            '';
          };

          size = mkOption {
            type = types.str;
            default = "2M";
            description = ''
              Hugepage size. Common values:
              - "2M": Standard x86_64 hugepages (most compatible)
              - "1G": Gigabyte pages (best performance, requires CPU support)

              Check support with: grep -i huge /proc/meminfo
            '';
          };

          count = mkOption {
            type = types.int;
            default = 0;
            description = ''
              Number of hugepages to allocate at boot.

              Calculate: memory_in_bytes / hugepage_size
              Example: 24GB with 2MB pages = 24 * 1024 / 2 = 12288 pages

              **Warning:** These pages are reserved at boot and permanently
              unavailable to the rest of the system, even when VMs are not running.

              Set to 0 to auto-calculate based on total VM memory (not yet implemented,
              must specify explicitly).
            '';
            example = 12288;
          };
        };

        firewallPorts = {
          spice = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Open firewall ports for SPICE connections (5900-5999).
              Enable if you need remote access to VM displays.
            '';
          };

          vnc = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Open firewall ports for VNC connections (5900-5999).
              Usually not needed if using SPICE.
            '';
          };
        };

        defaultStoragePool = mkOption {
          type = types.str;
          default = "default";
          description = ''
            Default libvirt storage pool for VM disks.
            Individual VMs can override this with storagePool option.
          '';
        };

        defaultStoragePath = mkOption {
          type = types.path;
          default = "/var/lib/libvirt/images";
          description = ''
            Path for the default storage pool.
          '';
        };

        vms = mkOption {
          type = types.attrsOf vmSubmodule;
          default = { };
          description = ''
            Per-VM configuration. Each attribute defines a VM with its
            resource allocation, display settings, and OS-specific options.
          '';
          example = literalExpression ''
            {
              windows-dev = {
                enable = true;
                memory = "16G";
                vcpus = 8;
                diskSize = "200G";
                cpuPinning = [ "0-1" "2-3" "4-5" "6-7" "8-9" "10-11" "12-13" "14-15" ];
                sharedFolders.projects = "/home/user/projects";
                osType = "windows";
                tpm = true;
              };

              linux-test = {
                enable = true;
                memory = "4G";
                vcpus = 2;
                osType = "linux";
                tpm = false;
                secureBoot = false;
              };
            }
          '';
        };
      };

      config = mkIf cfg.enable (mkMerge [
        # Base libvirt configuration
        # Using mkDefault for settings that users might override
        {
          # Enable libvirtd
          virtualisation.libvirtd = {
            enable = mkDefault true;
            qemu = {
              package = mkDefault pkgs.qemu_kvm;
              runAsRoot = mkDefault true;
              swtpm.enable = mkDefault true;
              ovmf = {
                enable = mkDefault true;
                packages = mkDefault [ ovmfPackage ];
              };
              # VirtIO-FS requires memory backing access
              verbatimConfig = mkDefault ''
                memory_backing_dir = "/dev/shm"
              '';
            };
            # Use nftables backend for firewall
            extraConfig = mkDefault ''
              firewall_backend="nftables"
            '';
          };

          # Enable SPICE USB redirection
          virtualisation.spiceUSBRedirection.enable = true;

          # Required packages for VM management
          environment.systemPackages = with pkgs; [
            virt-viewer     # SPICE/VNC viewer
            spice-gtk       # SPICE client library
            virt-manager    # GUI for VM management
            libguestfs      # VM disk inspection tools
            quickemu        # For downloading Windows ISOs
          ];

          # Polkit rules for non-root VM management
          security.polkit.extraConfig = ''
            polkit.addRule(function(action, subject) {
              if (action.id == "org.libvirt.unix.manage" &&
                  subject.isInGroup("libvirtd")) {
                return polkit.Result.YES;
              }
            });
          '';
        }

        # Hugepages configuration (for "always-on" profile or explicit enable)
        (mkIf cfg.hugepages.enable {
          # Kernel parameters for hugepages
          boot.kernelParams = [
            "hugepagesz=${cfg.hugepages.size}"
            "hugepages=${toString cfg.hugepages.count}"
          ];

          # Systemd service to configure hugepages after boot (as backup)
          systemd.services.configure-hugepages = {
            description = "Configure hugepages for VMs";
            wantedBy = [ "multi-user.target" ];
            before = [ "libvirtd.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "configure-hugepages" ''
                # Ensure hugepages are available
                echo ${toString cfg.hugepages.count} > /proc/sys/vm/nr_hugepages || true
                # Verify
                ACTUAL=$(cat /proc/sys/vm/nr_hugepages)
                echo "Hugepages configured: $ACTUAL (requested: ${toString cfg.hugepages.count})"
              '';
            };
          };

          # Mount hugetlbfs for libvirt
          fileSystems."/dev/hugepages" = {
            device = "hugetlbfs";
            fsType = "hugetlbfs";
            options = [ "mode=1770" "gid=libvirtd" ];
          };
        })

        # Firewall configuration
        (mkIf (cfg.firewallPorts.spice || cfg.firewallPorts.vnc) {
          networking.firewall.allowedTCPPortRanges = [
            { from = 5900; to = 5999; }  # SPICE/VNC port range
          ];
        })

        # VirtIO-FS configuration (when any VM has shared folders)
        (mkIf (builtins.any (vm: vm.sharedFolders != { }) (builtins.attrValues enabledVMs)) {
          # Enable virtiofsd
          # Note: virtiofsd is included with qemu, but we ensure it's available
          systemd.services.virtiofsd = {
            description = "VirtIO-FS daemon for VM shared folders";
            after = [ "local-fs.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "simple";
              # virtiofsd is typically started by libvirt per-VM, this is a placeholder
              ExecStart = "${pkgs.coreutils}/bin/true";
              RemainAfterExit = true;
            };
          };
        })

        # Storage pool setup
        {
          systemd.services.libvirt-storage-pool = {
            description = "Create default libvirt storage pool";
            wantedBy = [ "multi-user.target" ];
            after = [ "libvirtd.service" ];
            requires = [ "libvirtd.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "create-storage-pool" ''
                # Ensure directory exists
                mkdir -p ${cfg.defaultStoragePath}
                chmod 755 ${cfg.defaultStoragePath}

                # Create pool if it doesn't exist
                if ! ${pkgs.libvirt}/bin/virsh pool-info ${cfg.defaultStoragePool} &>/dev/null; then
                  ${pkgs.libvirt}/bin/virsh pool-define-as ${cfg.defaultStoragePool} dir --target ${cfg.defaultStoragePath}
                  ${pkgs.libvirt}/bin/virsh pool-autostart ${cfg.defaultStoragePool}
                fi

                # Start pool if not active
                ${pkgs.libvirt}/bin/virsh pool-start ${cfg.defaultStoragePool} || true
                ${pkgs.libvirt}/bin/virsh pool-refresh ${cfg.defaultStoragePool} || true
              '';
            };
          };

          # Default network setup
          systemd.services.libvirt-default-network = {
            description = "Ensure libvirt default network is active";
            wantedBy = [ "multi-user.target" ];
            after = [ "libvirtd.service" "libvirt-storage-pool.service" ];
            requires = [ "libvirtd.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "setup-default-network" ''
                # Start default network if not active
                ${pkgs.libvirt}/bin/virsh net-autostart default || true
                ${pkgs.libvirt}/bin/virsh net-start default || true
              '';
            };
          };
        }

        # Per-VM domain definitions
        {
          # Create systemd services to define VMs
          systemd.services = mapAttrs (name: vmCfg: {
            description = "Define libvirt domain for ${name}";
            wantedBy = [ "multi-user.target" ];
            after = [ "libvirtd.service" "libvirt-storage-pool.service" "libvirt-default-network.service" ];
            requires = [ "libvirtd.service" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = pkgs.writeShellScript "define-${name}" ''
                set -e

                # Check if domain already exists
                if ${pkgs.libvirt}/bin/virsh dominfo ${name} &>/dev/null; then
                  echo "Domain ${name} already exists"
                  exit 0
                fi

                # Create disk volume if it doesn't exist
                ${pkgs.libvirt}/bin/virsh pool-refresh ${vmCfg.storagePool} || true
                if ! ${pkgs.libvirt}/bin/virsh vol-info ${name}.qcow2 --pool ${vmCfg.storagePool} &>/dev/null; then
                  echo "Creating disk volume for ${name}..."
                  ${pkgs.libvirt}/bin/virsh vol-create-as ${vmCfg.storagePool} ${name}.qcow2 ${vmCfg.diskSize} --format qcow2
                fi

                # Create NVRAM directory
                mkdir -p /var/lib/libvirt/qemu/nvram

                # Define the domain
                echo "Defining domain ${name}..."
                ${pkgs.libvirt}/bin/virsh define ${vmDomainXmlFile name vmCfg}

                ${optionalString vmCfg.autoStart ''
                  # Enable autostart
                  ${pkgs.libvirt}/bin/virsh autostart ${name}
                ''}

                echo "Domain ${name} defined successfully"
              '';
            };
          }) enabledVMs;

          # Generate VM management scripts
          environment.systemPackages = mapAttrsToList (name: vmCfg:
            pkgs.writeShellScriptBin "vm-${name}" ''
              #!/usr/bin/env bash
              set -e

              case "$1" in
                start)
                  virsh start ${name}
                  echo "VM ${name} started"
                  ;;
                stop)
                  virsh shutdown ${name}
                  echo "Shutdown signal sent to ${name}"
                  ;;
                force-stop)
                  virsh destroy ${name}
                  echo "VM ${name} forcefully stopped"
                  ;;
                view)
                  virt-viewer --connect qemu:///system ${name} &
                  ;;
                console)
                  virsh console ${name}
                  ;;
                status)
                  virsh dominfo ${name}
                  ;;
                memstats)
                  virsh dommemstat ${name}
                  ;;
                setmem)
                  if [ -z "$2" ]; then
                    echo "Usage: vm-${name} setmem <size>"
                    echo "Example: vm-${name} setmem 16G"
                    exit 1
                  fi
                  virsh setmem ${name} "$2" --live
                  echo "Memory set to $2 for ${name}"
                  ;;
                ssh)
                  # Try to get IP and SSH (for VMs with QEMU guest agent)
                  IP=$(virsh domifaddr ${name} --source agent 2>/dev/null | grep -oP '(\d+\.){3}\d+' | head -1)
                  if [ -n "$IP" ]; then
                    ssh "$IP"
                  else
                    echo "Could not determine VM IP. Ensure QEMU guest agent is installed."
                    exit 1
                  fi
                  ;;
                *)
                  echo "Usage: vm-${name} {start|stop|force-stop|view|console|status|memstats|setmem|ssh}"
                  exit 1
                  ;;
              esac
            ''
          ) enabledVMs;
        }

        # Export helper packages and functions
        {
          # Make Windows helpers available
          environment.systemPackages = [
            # Add quickget for downloading Windows ISOs
            pkgs.quickemu
          ];
        }
      ]);
    };
}
