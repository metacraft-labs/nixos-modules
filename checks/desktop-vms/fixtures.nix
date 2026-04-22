# Test fixtures for desktop-vms XML generation.
#
# Each attribute is a set of parameters to generateDomainXml.
# The generated XML is compared against golden files in ./golden/.
{
  # Minimal Windows VM with defaults
  basic-windows = {
    name = "test-windows";
    uuid = "00000000-0000-0000-0000-000000000001";
    memory = "8G";
    vcpus = 4;
    diskVolume = "test-windows.qcow2";
    osType = "windows";
    tpm = true;
    secureBoot = true;
    ovmfCodePath = "/nix/store/placeholder-ovmf/FV/OVMF_CODE.fd";
    ovmfVarsPath = "/nix/store/placeholder-ovmf/FV/OVMF_VARS.fd";
    nvramPath = "/var/lib/libvirt/qemu/nvram/test-windows_VARS.fd";
  };

  # GPU passthrough with videoModel = "none" — no virtual display adapter
  gpu-passthrough = {
    name = "test-gpu-passthrough";
    uuid = "00000000-0000-0000-0000-000000000002";
    memory = "16G";
    vcpus = 8;
    diskVolume = "test-gpu.qcow2";
    osType = "windows";
    tpm = true;
    secureBoot = true;
    ovmfCodePath = "/nix/store/placeholder-ovmf/FV/OVMF_CODE.fd";
    ovmfVarsPath = "/nix/store/placeholder-ovmf/FV/OVMF_VARS.fd";
    nvramPath = "/var/lib/libvirt/qemu/nvram/test-gpu_VARS.fd";
    videoModel = "none";
    display = "looking-glass";
    pciDevices = [
      "08:00.0"
      "08:00.1"
    ];
    macAddress = "52:54:00:aa:bb:cc";
    maxPhysAddrBits = 39;
    extraQemuArgs = [
      "-object"
      "input-linux,id=kbd,evdev=/dev/input/event0,repeat=on,grab-toggle=ctrl-ctrl"
    ];
  };

  # Multi-head QXL with custom VRAM
  qxl-multi-head = {
    name = "test-qxl";
    uuid = "00000000-0000-0000-0000-000000000003";
    memory = "4G";
    vcpus = 2;
    diskVolume = "test-qxl.qcow2";
    osType = "windows";
    tpm = false;
    secureBoot = false;
    ovmfCodePath = "/nix/store/placeholder-ovmf/FV/OVMF_CODE.fd";
    ovmfVarsPath = "/nix/store/placeholder-ovmf/FV/OVMF_VARS.fd";
    nvramPath = "/var/lib/libvirt/qemu/nvram/test-qxl_VARS.fd";
    videoModel = "qxl";
    videoHeads = 4;
    videoRam = 524288;
    videoVram = 524288;
    videoVgamem = 262144;
  };

  # Linux VM with VirtIO video and shared folders
  linux-virtio = {
    name = "test-linux";
    uuid = "00000000-0000-0000-0000-000000000004";
    memory = "4G";
    vcpus = 4;
    diskVolume = "test-linux.qcow2";
    osType = "linux";
    tpm = false;
    secureBoot = false;
    ovmfCodePath = "/nix/store/placeholder-ovmf/FV/OVMF_CODE.fd";
    ovmfVarsPath = "/nix/store/placeholder-ovmf/FV/OVMF_VARS.fd";
    nvramPath = "/var/lib/libvirt/qemu/nvram/test-linux_VARS.fd";
    videoModel = "virtio";
    sharedFolders = {
      projects = "/home/user/projects";
      documents = "/home/user/documents";
    };
  };

  # VM with CPU pinning and hugepages
  pinned-hugepages = {
    name = "test-pinned";
    uuid = "00000000-0000-0000-0000-000000000005";
    memory = "32G";
    vcpus = 8;
    diskVolume = "test-pinned.qcow2";
    osType = "windows";
    tpm = true;
    secureBoot = true;
    ovmfCodePath = "/nix/store/placeholder-ovmf/FV/OVMF_CODE.fd";
    ovmfVarsPath = "/nix/store/placeholder-ovmf/FV/OVMF_VARS.fd";
    nvramPath = "/var/lib/libvirt/qemu/nvram/test-pinned_VARS.fd";
    cpuPinning = [
      "0-1"
      "2-3"
      "4-5"
      "6-7"
      "8-9"
      "10-11"
      "12-13"
      "14-15"
    ];
    hugepages = true;
    memballoon = {
      enable = true;
      autodeflate = true;
      freePageReporting = true;
      statsInterval = 10;
    };
  };
}
