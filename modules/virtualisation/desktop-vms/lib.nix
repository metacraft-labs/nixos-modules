# Shared utilities for desktop VM configuration
#
# This module provides helper functions for generating libvirt XML domain
# definitions without requiring the NixVirt flake as a dependency.
#
# References:
# - Libvirt domain XML format: https://libvirt.org/formatdomain.html
# - QEMU/KVM documentation: https://www.qemu.org/docs/master/
# - VirtIO-FS: https://virtio-fs.gitlab.io/
{ lib }:

let
  inherit (lib)
    concatMapStringsSep
    concatStringsSep
    mapAttrsToList
    optionalString
    isList
    isAttrs
    isString
    isBool
    isInt
    ;

  # Convert Nix attribute set to XML attributes string
  # Example: { foo = "bar"; baz = "qux"; } -> "foo=\"bar\" baz=\"qux\""
  attrsToXmlAttrs =
    attrs:
    concatStringsSep " " (
      mapAttrsToList (
        k: v:
        if v == null then
          ""
        else if isBool v then
          (if v then "${k}=\"yes\"" else "${k}=\"no\"")
        else
          "${k}=\"${toString v}\""
      ) attrs
    );

  # Render a simple XML element with attributes and optional content
  # Example: xmlElement "cpu" { mode = "host-passthrough"; } null -> "<cpu mode=\"host-passthrough\"/>"
  xmlElement =
    name: attrs: content:
    let
      attrStr = attrsToXmlAttrs attrs;
      attrPart = optionalString (attrStr != "") " ${attrStr}";
    in
    if content == null || content == "" then
      "<${name}${attrPart}/>"
    else
      "<${name}${attrPart}>${content}</${name}>";

  # Render XML element with nested children
  xmlElementNested =
    name: attrs: children:
    let
      attrStr = attrsToXmlAttrs attrs;
      attrPart = optionalString (attrStr != "") " ${attrStr}";
      childrenStr = if isList children then concatStringsSep "\n    " children else children;
    in
    ''
      <${name}${attrPart}>
        ${childrenStr}
      </${name}>'';

in
rec {
  inherit attrsToXmlAttrs xmlElement xmlElementNested;

  # Parse memory string like "8G", "16384M", "8GiB" into { count, unit } format
  # Libvirt expects memory in unit format: <memory unit="GiB">8</memory>
  # Reference: https://libvirt.org/formatdomain.html#memory-allocation
  parseMemory =
    memStr:
    let
      # Match patterns like "8G", "8GiB", "16384M", "16384MiB"
      matches = builtins.match "([0-9]+)([GMKgmk]i?[Bb]?)" memStr;
    in
    if matches == null then
      throw "Invalid memory format: ${memStr}. Expected format: 8G, 16GiB, 8192M, etc."
    else
      {
        count = lib.strings.toInt (builtins.elemAt matches 0);
        unit =
          let
            unitStr = builtins.elemAt matches 1;
            # Normalize to libvirt units: GiB, MiB, KiB
            normalized = lib.strings.toLower unitStr;
          in
          if lib.hasPrefix "g" normalized then
            "GiB"
          else if lib.hasPrefix "m" normalized then
            "MiB"
          else if lib.hasPrefix "k" normalized then
            "KiB"
          else
            "GiB"; # Default to GiB
      };

  # Parse disk size string like "100G", "500GiB" into bytes for qcow2 creation
  parseDiskSize =
    sizeStr:
    let
      matches = builtins.match "([0-9]+)([GMTgmt]i?[Bb]?)" sizeStr;
    in
    if matches == null then
      throw "Invalid disk size format: ${sizeStr}. Expected format: 100G, 500GiB, 1T, etc."
    else
      {
        count = lib.strings.toInt (builtins.elemAt matches 0);
        unit =
          let
            unitStr = builtins.elemAt matches 1;
            normalized = lib.strings.toLower unitStr;
          in
          if lib.hasPrefix "t" normalized then
            "T"
          else if lib.hasPrefix "g" normalized then
            "G"
          else if lib.hasPrefix "m" normalized then
            "M"
          else
            "G";
      };

  # Generate CPU pinning XML for cputune section
  # Input: [ "0-1" "2-3" "4-5" "6-7" ] (cpuset strings per vCPU)
  # Output: XML vcpupin elements
  # Reference: https://libvirt.org/formatdomain.html#cpu-tuning
  generateCpuPinningXml =
    cpuPinning:
    if cpuPinning == null then
      ""
    else
      let
        pinnings = lib.imap0 (
          i: cpuset:
          xmlElement "vcpupin" {
            vcpu = i;
            inherit cpuset;
          } null
        ) cpuPinning;
      in
      xmlElementNested "cputune" { } pinnings;

  # Generate memory backing XML for hugepages and shared memory
  # Reference: https://libvirt.org/formatdomain.html#memory-backing
  generateMemoryBackingXml =
    {
      hugepages ? false,
      shared ? false,
    }:
    let
      children =
        [ ]
        ++ lib.optional hugepages (xmlElement "hugepages" { } null)
        ++ lib.optional shared (xmlElement "access" { mode = "shared"; } null);
    in
    if children == [ ] then "" else xmlElementNested "memoryBacking" { } children;

  # Generate VirtIO-FS filesystem XML for shared folders
  # Reference: https://libvirt.org/formatdomain.html#filesystems
  # Reference: https://virtio-fs.gitlab.io/
  generateVirtioFsXml =
    sharedFolders:
    if sharedFolders == { } then
      ""
    else
      concatMapStringsSep "\n" (
        name:
        let
          hostPath = sharedFolders.${name};
        in
        ''
          <filesystem type="mount" accessmode="passthrough">
            <driver type="virtiofs"/>
            <source dir="${hostPath}"/>
            <target dir="${name}"/>
          </filesystem>''
      ) (builtins.attrNames sharedFolders);

  # Generate SPICE graphics configuration
  # Reference: https://libvirt.org/formatdomain.html#graphical-framebuffers
  generateSpiceGraphicsXml =
    {
      port ? 5900,
      listen ? "127.0.0.1",
      autoport ? true,
    }:
    ''
      <graphics type="spice" port="${toString port}" autoport="${
        if autoport then "yes" else "no"
      }" listen="${listen}">
        <listen type="address" address="${listen}"/>
        <image compression="auto_glz"/>
        <streaming mode="filter"/>
        <gl enable="no"/>
      </graphics>'';

  # Generate VNC graphics configuration
  generateVncGraphicsXml =
    {
      port ? 5900,
      listen ? "127.0.0.1",
      autoport ? true,
    }:
    ''
      <graphics type="vnc" port="${toString port}" autoport="${
        if autoport then "yes" else "no"
      }" listen="${listen}">
        <listen type="address" address="${listen}"/>
      </graphics>'';

  # Generate Looking Glass shared memory configuration
  # Reference: https://looking-glass.io/docs/stable/install_host/libvirt/
  generateLookingGlassXml =
    {
      memoryMB ? 64,
    }:
    ''
      <shmem name="looking-glass">
        <model type="ivshmem-plain"/>
        <size unit="M">${toString memoryMB}</size>
      </shmem>'';

  # Generate TPM device configuration for Windows 11 compatibility
  # Reference: https://libvirt.org/formatdomain.html#tpm-device
  generateTpmXml =
    {
      enable ? true,
    }:
    if !enable then
      ""
    else
      ''
        <tpm model="tpm-crb">
          <backend type="emulator" version="2.0"/>
        </tpm>'';

  # Generate secure boot loader configuration
  # Reference: https://libvirt.org/formatdomain.html#bios-bootloader
  generateSecureBootXml =
    {
      enable ? true,
      ovmfCodePath,
      ovmfVarsPath,
      nvramPath,
    }:
    if enable then
      ''
        <os>
          <type arch="x86_64" machine="q35">hvm</type>
          <loader readonly="yes" secure="yes" type="pflash">${ovmfCodePath}</loader>
          <nvram template="${ovmfVarsPath}">${nvramPath}</nvram>
          <boot dev="hd"/>
        </os>''
    else
      ''
        <os>
          <type arch="x86_64" machine="q35">hvm</type>
          <loader readonly="yes" type="pflash">${ovmfCodePath}</loader>
          <nvram template="${ovmfVarsPath}">${nvramPath}</nvram>
          <boot dev="hd"/>
        </os>'';

  # Generate network interface configuration with VirtIO
  # Reference: https://libvirt.org/formatdomain.html#network-interfaces
  generateNetworkXml =
    {
      bridge ? "virbr0",
      mac ? null,
    }:
    let
      macAttr = if mac != null then "<mac address=\"${mac}\"/>" else "";
    in
    ''
      <interface type="network">
        ${macAttr}
        <source network="default"/>
        <model type="virtio"/>
      </interface>'';

  # Generate VirtIO disk configuration
  # Reference: https://libvirt.org/formatdomain.html#hard-drives-floppy-disks-cdroms
  generateDiskXml =
    {
      pool ? "default",
      volume,
      bus ? "virtio",
      cache ? "writeback",
    }:
    ''
      <disk type="volume" device="disk">
        <driver name="qemu" type="qcow2" cache="${cache}"/>
        <source pool="${pool}" volume="${volume}"/>
        <target dev="vda" bus="${bus}"/>
      </disk>'';

  # Generate CDROM device configuration
  generateCdromXml =
    {
      path,
      index ? 0,
    }:
    ''
      <disk type="file" device="cdrom">
        <driver name="qemu" type="raw"/>
        <source file="${path}"/>
        <target dev="sdc" bus="sata"/>
        <readonly/>
      </disk>'';

  # Generate video device configuration
  # Reference: https://libvirt.org/formatdomain.html#video-devices
  generateVideoXml =
    {
      type ? "virtio",
    }:
    ''
      <video>
        <model type="${type}"/>
      </video>'';

  # Generate a complete libvirt domain XML for a desktop VM
  #
  # This function combines all the individual XML generators to produce
  # a complete domain definition suitable for libvirt.
  #
  # Parameters:
  #   name: VM name
  #   uuid: Optional UUID (generated if not provided)
  #   memory: Memory size string (e.g., "8G", "16GiB")
  #   vcpus: Number of virtual CPUs
  #   cpuPinning: Optional list of cpuset strings for CPU pinning
  #   hugepages: Enable hugepages memory backing
  #   sharedFolders: Attribute set of { mountName = "/host/path"; }
  #   display: "spice", "vnc", or "looking-glass"
  #   diskPool: Libvirt storage pool name
  #   diskVolume: Libvirt volume name (qcow2 file)
  #   osType: "windows", "linux", or "macos"
  #   tpm: Enable TPM 2.0 emulation
  #   secureBoot: Enable UEFI Secure Boot
  #   ovmfCodePath: Path to OVMF_CODE.fd
  #   ovmfVarsPath: Path to OVMF_VARS.fd template
  #   nvramPath: Path for NVRAM storage
  #   memballoon: Memory balloon configuration
  #     - enable: Enable memballoon device
  #     - autodeflate: Enable autodeflate on OOM
  #     - freePageReporting: Enable free page reporting
  #     - statsInterval: Statistics polling interval in seconds (0 to disable)
  #
  # Returns: String containing the complete libvirt domain XML
  generateDomainXml =
    {
      name,
      uuid ? null,
      memory,
      vcpus,
      cpuPinning ? null,
      hugepages ? false,
      sharedFolders ? { },
      display ? "spice",
      diskPool ? "default",
      diskVolume,
      osType ? "windows",
      tpm ? true,
      secureBoot ? true,
      ovmfCodePath,
      ovmfVarsPath,
      nvramPath,
      extraDevices ? "",
      memballoon ? {
        enable = true;
        autodeflate = false;
        freePageReporting = false;
        statsInterval = 5;
      },
    }:
    let
      memParsed = parseMemory memory;

      # Generate UUID if not provided
      uuidLine = if uuid != null then "<uuid>${uuid}</uuid>" else "";

      # Memory configuration
      memoryXml = ''
        <memory unit="${memParsed.unit}">${toString memParsed.count}</memory>
        <currentMemory unit="${memParsed.unit}">${toString memParsed.count}</currentMemory>'';

      # vCPU configuration
      vcpuXml = "<vcpu placement=\"static\">${toString vcpus}</vcpu>";

      # CPU configuration with host passthrough for best performance
      cpuXml = ''
        <cpu mode="host-passthrough" check="none">
          <topology sockets="1" dies="1" clusters="1" cores="${toString vcpus}" threads="1"/>
        </cpu>'';

      # Memory backing (hugepages + shared for virtiofs)
      memBackingXml = generateMemoryBackingXml {
        inherit hugepages;
        shared = sharedFolders != { };
      };

      # CPU pinning
      cpuTuneXml = generateCpuPinningXml cpuPinning;

      # OS/boot configuration
      osXml = generateSecureBootXml {
        enable = secureBoot;
        inherit ovmfCodePath ovmfVarsPath nvramPath;
      };

      # Features (ACPI, APIC, hyperv for Windows)
      featuresXml =
        if osType == "windows" then
          ''
            <features>
              <acpi/>
              <apic/>
              <hyperv mode="passthrough">
                <relaxed state="on"/>
                <vapic state="on"/>
                <spinlocks state="on" retries="8191"/>
                <vpindex state="on"/>
                <runtime state="on"/>
                <synic state="on"/>
                <stimer state="on"/>
                <reset state="on"/>
                <frequencies state="on"/>
              </hyperv>
            </features>''
        else
          ''
            <features>
              <acpi/>
              <apic/>
            </features>'';

      # Clock configuration
      clockXml =
        if osType == "windows" then
          ''
            <clock offset="localtime">
              <timer name="rtc" tickpolicy="catchup"/>
              <timer name="pit" tickpolicy="delay"/>
              <timer name="hpet" present="no"/>
              <timer name="hypervclock" present="yes"/>
            </clock>''
        else
          ''
            <clock offset="utc">
              <timer name="rtc" tickpolicy="catchup"/>
              <timer name="pit" tickpolicy="delay"/>
              <timer name="hpet" present="no"/>
            </clock>'';

      # Power management
      pmXml = ''
        <pm>
          <suspend-to-mem enabled="no"/>
          <suspend-to-disk enabled="no"/>
        </pm>'';

      # Graphics configuration
      graphicsXml =
        if display == "spice" then
          generateSpiceGraphicsXml { }
        else if display == "vnc" then
          generateVncGraphicsXml { }
        else if display == "looking-glass" then
          # Looking Glass uses SPICE for input plus shared memory
          generateSpiceGraphicsXml { } + "\n      " + generateLookingGlassXml { }
        else
          throw "Unknown display type: ${display}";

      # VirtIO-FS shared folders
      virtioFsXml = generateVirtioFsXml sharedFolders;

      # TPM for Windows 11
      tpmXml = generateTpmXml { enable = tpm && osType == "windows"; };

      # Disk
      diskXml = generateDiskXml {
        pool = diskPool;
        volume = diskVolume;
      };

      # Network
      networkXml = generateNetworkXml { };

      # Video
      videoXml = generateVideoXml { };

      # Input devices
      inputXml = ''
        <input type="tablet" bus="usb">
          <address type="usb" bus="0" port="1"/>
        </input>
        <input type="mouse" bus="ps2"/>
        <input type="keyboard" bus="ps2"/>'';

      # Serial/console for debugging
      consoleXml = ''
        <serial type="pty">
          <target type="isa-serial" port="0">
            <model name="isa-serial"/>
          </target>
        </serial>
        <console type="pty">
          <target type="serial" port="0"/>
        </console>'';

      # Channel for QEMU guest agent
      channelXml = ''
        <channel type="unix">
          <target type="virtio" name="org.qemu.guest_agent.0"/>
        </channel>
        <channel type="spicevmc">
          <target type="virtio" name="com.redhat.spice.0"/>
        </channel>'';

      # USB controller
      usbXml = ''
        <controller type="usb" model="qemu-xhci" ports="15">
          <address type="pci" domain="0x0000" bus="0x02" slot="0x00" function="0x0"/>
        </controller>'';

      # Sound device (optional for desktop VMs)
      soundXml = ''
        <sound model="ich9">
          <codec type="micro"/>
          <audio id="1"/>
        </sound>
        <audio id="1" type="spice"/>'';

      # Memballoon for memory management
      # Reference: https://libvirt.org/formatdomain.html#memory-balloon-device
      #
      # Attributes:
      # - autodeflate='on': Automatically deflate balloon before OOM killer activates
      # - freePageReporting='on': Report free pages to host for memory overcommit
      #
      # The <stats> element enables periodic memory statistics collection.
      # Stats can be viewed with: virsh dommemstat <domain>
      memballoonXml =
        if memballoon.enable then
          let
            # Build attributes string
            autodeflateAttr = if memballoon.autodeflate then " autodeflate='on'" else "";
            freePageReportingAttr = if memballoon.freePageReporting then " freePageReporting='on'" else "";
            # Stats element (only if interval > 0)
            statsElement =
              if memballoon.statsInterval > 0 then
                "\n          <stats period='${toString memballoon.statsInterval}'/>"
              else
                "";
          in
          ''
            <memballoon model="virtio"${autodeflateAttr}${freePageReportingAttr}>${statsElement}
              <address type="pci" domain="0x0000" bus="0x05" slot="0x00" function="0x0"/>
            </memballoon>''
        else
          ''<memballoon model="none"/>'';

    in
    ''
      <domain type="kvm">
        <name>${name}</name>
        ${uuidLine}
        ${memoryXml}
        ${vcpuXml}
        ${cpuXml}
        ${memBackingXml}
        ${cpuTuneXml}
        ${osXml}
        ${featuresXml}
        ${clockXml}
        <on_poweroff>destroy</on_poweroff>
        <on_reboot>restart</on_reboot>
        <on_crash>destroy</on_crash>
        ${pmXml}
        <devices>
          <emulator>/run/current-system/sw/bin/qemu-system-x86_64</emulator>
          ${diskXml}
          ${networkXml}
          ${graphicsXml}
          ${videoXml}
          ${inputXml}
          ${consoleXml}
          ${channelXml}
          ${usbXml}
          ${soundXml}
          ${virtioFsXml}
          ${tpmXml}
          ${memballoonXml}
          ${extraDevices}
        </devices>
      </domain>'';
}
