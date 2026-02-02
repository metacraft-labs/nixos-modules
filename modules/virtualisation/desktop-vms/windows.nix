# Windows-specific helpers for desktop VM configuration
#
# This module provides Windows-specific configurations and utilities
# for creating high-performance Windows VMs with libvirt/QEMU.
#
# Key features:
# - Windows 11 compatibility (TPM 2.0, Secure Boot bypass if needed)
# - Hyper-V enlightenments for better performance
# - VirtIO driver integration
# - Autounattend.xml generation for unattended installation
#
# References:
# - Microsoft Windows VM requirements: https://learn.microsoft.com/en-us/windows/whats-new/windows-11-requirements
# - QEMU Hyper-V enlightenments: https://www.qemu.org/docs/master/system/i386/hyperv.html
# - VirtIO drivers: https://fedorapeople.org/groups/virt/virtio-win/
{ lib, pkgs }:

let
  inherit (lib)
    optionalString
    concatStringsSep
    ;

  # VirtIO drivers ISO URL and hash
  # Updated periodically from https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/
  virtioDriversUrl = "https://fedorapeople.org/groups/virt/virtio-win/direct-downloads/stable-virtio/virtio-win.iso";

  # Windows timezone mapping
  # Maps IANA timezone identifiers to Windows timezone names
  # Reference: https://learn.microsoft.com/en-us/windows-hardware/manufacture/desktop/default-time-zones
  timezoneMapping = {
    "UTC" = "UTC";
    "America/New_York" = "Eastern Standard Time";
    "America/Chicago" = "Central Standard Time";
    "America/Denver" = "Mountain Standard Time";
    "America/Los_Angeles" = "Pacific Standard Time";
    "America/Phoenix" = "US Mountain Standard Time";
    "America/Anchorage" = "Alaskan Standard Time";
    "Pacific/Honolulu" = "Hawaiian Standard Time";
    "Europe/London" = "GMT Standard Time";
    "Europe/Paris" = "Romance Standard Time";
    "Europe/Berlin" = "W. Europe Standard Time";
    "Europe/Sofia" = "FLE Standard Time";
    "Europe/Moscow" = "Russian Standard Time";
    "Asia/Tokyo" = "Tokyo Standard Time";
    "Asia/Shanghai" = "China Standard Time";
    "Asia/Singapore" = "Singapore Standard Time";
    "Asia/Kolkata" = "India Standard Time";
    "Australia/Sydney" = "AUS Eastern Standard Time";
    "Australia/Perth" = "W. Australia Standard Time";
  };

in
rec {
  inherit virtioDriversUrl timezoneMapping;

  # Convert IANA timezone to Windows timezone name
  toWindowsTimezone = tz: if builtins.hasAttr tz timezoneMapping then timezoneMapping.${tz} else tz; # Assume already Windows format

  # Fetch VirtIO drivers ISO declaratively
  # This can be used in NixOS configuration or for standalone builds
  fetchVirtioDrivers =
    { sha256 }:
    pkgs.fetchurl {
      url = virtioDriversUrl;
      inherit sha256;
    };

  # Generate Windows-optimized CPU features XML
  # Hyper-V enlightenments significantly improve Windows guest performance
  # Reference: https://www.qemu.org/docs/master/system/i386/hyperv.html
  generateHyperVEnlightenmentsXml = ''
    <hyperv mode="passthrough">
      <relaxed state="on"/>
      <vapic state="on"/>
      <spinlocks state="on" retries="8191"/>
      <vpindex state="on"/>
      <runtime state="on"/>
      <synic state="on"/>
      <stimer state="on">
        <direct state="on"/>
      </stimer>
      <reset state="on"/>
      <vendor_id state="on" value="KVM Hv"/>
      <frequencies state="on"/>
      <reenlightenment state="on"/>
      <tlbflush state="on"/>
      <ipi state="on"/>
    </hyperv>'';

  # Generate Windows-optimized clock configuration
  # Windows expects local time and benefits from Hyper-V clock
  generateWindowsClockXml = ''
    <clock offset="localtime">
      <timer name="rtc" tickpolicy="catchup"/>
      <timer name="pit" tickpolicy="delay"/>
      <timer name="hpet" present="no"/>
      <timer name="hypervclock" present="yes"/>
    </clock>'';

  # Generate autounattend.xml for Windows unattended installation
  # This creates a complete answer file for automated Windows setup
  #
  # Parameters:
  #   username: Local administrator account username
  #   password: Local administrator account password
  #   computerName: Windows computer name (max 15 chars)
  #   timezone: Timezone in IANA or Windows format
  #   locale: Language/locale setting (default: en-US)
  #   virtioDriverPath: Path to VirtIO drivers (typically E:\)
  #
  # Reference: https://learn.microsoft.com/en-us/windows-hardware/customize/desktop/unattend/
  generateAutounattendXml =
    {
      username ? "admin",
      password ? "admin",
      computerName ? "WIN-VM",
      timezone ? "UTC",
      locale ? "en-US",
      virtioDriverPath ? "E:\\",
    }:
    let
      windowsTimezone = toWindowsTimezone timezone;
      # Validate computer name (Windows restriction: max 15 chars)
      validatedComputerName =
        if builtins.stringLength computerName > 15 then
          throw "Windows computer name '${computerName}' exceeds 15 character limit"
        else
          computerName;
    in
    ''
      <?xml version="1.0" encoding="utf-8"?>
      <unattend xmlns="urn:schemas-microsoft-com:unattend">
        <!-- WindowsPE pass: Configure disk, install drivers -->
        <settings pass="windowsPE">
          <component name="Microsoft-Windows-International-Core-WinPE" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <SetupUILanguage>
              <UILanguage>${locale}</UILanguage>
            </SetupUILanguage>
            <InputLocale>${locale}</InputLocale>
            <SystemLocale>${locale}</SystemLocale>
            <UILanguage>${locale}</UILanguage>
            <UserLocale>${locale}</UserLocale>
          </component>
          <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <DiskConfiguration>
              <Disk wcm:action="add">
                <CreatePartitions>
                  <!-- EFI System Partition -->
                  <CreatePartition wcm:action="add">
                    <Order>1</Order>
                    <Size>100</Size>
                    <Type>EFI</Type>
                  </CreatePartition>
                  <!-- Microsoft Reserved -->
                  <CreatePartition wcm:action="add">
                    <Order>2</Order>
                    <Size>16</Size>
                    <Type>MSR</Type>
                  </CreatePartition>
                  <!-- Windows partition (use remaining space) -->
                  <CreatePartition wcm:action="add">
                    <Order>3</Order>
                    <Extend>true</Extend>
                    <Type>Primary</Type>
                  </CreatePartition>
                </CreatePartitions>
                <ModifyPartitions>
                  <ModifyPartition wcm:action="add">
                    <Order>1</Order>
                    <PartitionID>1</PartitionID>
                    <Format>FAT32</Format>
                    <Label>System</Label>
                  </ModifyPartition>
                  <ModifyPartition wcm:action="add">
                    <Order>2</Order>
                    <PartitionID>3</PartitionID>
                    <Format>NTFS</Format>
                    <Label>Windows</Label>
                  </ModifyPartition>
                </ModifyPartitions>
                <DiskID>0</DiskID>
                <WillWipeDisk>true</WillWipeDisk>
              </Disk>
            </DiskConfiguration>
            <ImageInstall>
              <OSImage>
                <InstallTo>
                  <DiskID>0</DiskID>
                  <PartitionID>3</PartitionID>
                </InstallTo>
                <InstallToAvailablePartition>false</InstallToAvailablePartition>
              </OSImage>
            </ImageInstall>
            <UserData>
              <AcceptEula>true</AcceptEula>
              <ProductKey>
                <WillShowUI>OnError</WillShowUI>
              </ProductKey>
            </UserData>
            <!-- VirtIO drivers for disk/network during setup -->
            <DriverPaths>
              <PathAndCredentials wcm:action="add" wcm:keyValue="1">
                <Path>${virtioDriverPath}amd64\w11</Path>
              </PathAndCredentials>
              <PathAndCredentials wcm:action="add" wcm:keyValue="2">
                <Path>${virtioDriverPath}amd64\w10</Path>
              </PathAndCredentials>
              <PathAndCredentials wcm:action="add" wcm:keyValue="3">
                <Path>${virtioDriverPath}viostor\w11\amd64</Path>
              </PathAndCredentials>
              <PathAndCredentials wcm:action="add" wcm:keyValue="4">
                <Path>${virtioDriverPath}viostor\w10\amd64</Path>
              </PathAndCredentials>
              <PathAndCredentials wcm:action="add" wcm:keyValue="5">
                <Path>${virtioDriverPath}NetKVM\w11\amd64</Path>
              </PathAndCredentials>
              <PathAndCredentials wcm:action="add" wcm:keyValue="6">
                <Path>${virtioDriverPath}NetKVM\w10\amd64</Path>
              </PathAndCredentials>
            </DriverPaths>
            <!-- Bypass Windows 11 TPM/SecureBoot/RAM requirements -->
            <RunSynchronous>
              <RunSynchronousCommand wcm:action="add">
                <Order>1</Order>
                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
              </RunSynchronousCommand>
              <RunSynchronousCommand wcm:action="add">
                <Order>2</Order>
                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
              </RunSynchronousCommand>
              <RunSynchronousCommand wcm:action="add">
                <Order>3</Order>
                <Path>reg add HKLM\SYSTEM\Setup\LabConfig /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
              </RunSynchronousCommand>
            </RunSynchronous>
          </component>
        </settings>

        <!-- specialize pass: Configure computer name, drivers -->
        <settings pass="specialize">
          <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <ComputerName>${validatedComputerName}</ComputerName>
            <TimeZone>${windowsTimezone}</TimeZone>
          </component>
          <component name="Microsoft-Windows-TerminalServices-LocalSessionManager" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <fDenyTSConnections>false</fDenyTSConnections>
          </component>
          <component name="Networking-MPSSVC-Svc" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <FirewallGroups>
              <FirewallGroup wcm:action="add" wcm:keyValue="rd1">
                <Active>true</Active>
                <Group>Remote Desktop</Group>
                <Profile>all</Profile>
              </FirewallGroup>
            </FirewallGroups>
          </component>
        </settings>

        <!-- oobeSystem pass: Configure user account, OOBE -->
        <settings pass="oobeSystem">
          <component name="Microsoft-Windows-International-Core" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <InputLocale>${locale}</InputLocale>
            <SystemLocale>${locale}</SystemLocale>
            <UILanguage>${locale}</UILanguage>
            <UserLocale>${locale}</UserLocale>
          </component>
          <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
              <HideEULAPage>true</HideEULAPage>
              <HideLocalAccountScreen>true</HideLocalAccountScreen>
              <HideOEMRegistrationScreen>true</HideOEMRegistrationScreen>
              <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
              <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
              <ProtectYourPC>3</ProtectYourPC>
              <SkipMachineOOBE>true</SkipMachineOOBE>
              <SkipUserOOBE>true</SkipUserOOBE>
            </OOBE>
            <UserAccounts>
              <LocalAccounts>
                <LocalAccount wcm:action="add">
                  <Password>
                    <Value>${password}</Value>
                    <PlainText>true</PlainText>
                  </Password>
                  <Description>Administrator account</Description>
                  <DisplayName>${username}</DisplayName>
                  <Group>Administrators</Group>
                  <Name>${username}</Name>
                </LocalAccount>
              </LocalAccounts>
            </UserAccounts>
            <AutoLogon>
              <Password>
                <Value>${password}</Value>
                <PlainText>true</PlainText>
              </Password>
              <Enabled>true</Enabled>
              <LogonCount>1</LogonCount>
              <Username>${username}</Username>
            </AutoLogon>
            <FirstLogonCommands>
              <!-- Enable OpenSSH Server -->
              <SynchronousCommand wcm:action="add">
                <Order>1</Order>
                <CommandLine>powershell -Command "Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0"</CommandLine>
                <Description>Install OpenSSH Server</Description>
                <RequiresUserInput>false</RequiresUserInput>
              </SynchronousCommand>
              <SynchronousCommand wcm:action="add">
                <Order>2</Order>
                <CommandLine>powershell -Command "Start-Service sshd; Set-Service -Name sshd -StartupType Automatic"</CommandLine>
                <Description>Start and enable OpenSSH Server</Description>
                <RequiresUserInput>false</RequiresUserInput>
              </SynchronousCommand>
              <SynchronousCommand wcm:action="add">
                <Order>3</Order>
                <CommandLine>powershell -Command "New-NetFirewallRule -Name 'OpenSSH-Server-In-TCP' -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22"</CommandLine>
                <Description>Allow SSH through firewall</Description>
                <RequiresUserInput>false</RequiresUserInput>
              </SynchronousCommand>
              <!-- Install VirtIO guest agent for better integration -->
              <SynchronousCommand wcm:action="add">
                <Order>4</Order>
                <CommandLine>msiexec /i "${virtioDriverPath}virtio-win-guest-tools.msi" /qn /norestart</CommandLine>
                <Description>Install VirtIO Guest Tools</Description>
                <RequiresUserInput>false</RequiresUserInput>
              </SynchronousCommand>
              <!-- Disable auto-logon after first logon -->
              <SynchronousCommand wcm:action="add">
                <Order>5</Order>
                <CommandLine>reg add "HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon" /v AutoAdminLogon /t REG_SZ /d 0 /f</CommandLine>
                <Description>Disable auto-logon</Description>
                <RequiresUserInput>false</RequiresUserInput>
              </SynchronousCommand>
            </FirstLogonCommands>
          </component>
        </settings>
      </unattend>'';

  # Create a floppy disk image with autounattend.xml
  # Windows Setup automatically searches for this file on floppy drives
  makeAutounattendFloppy =
    { autounattendXml }:
    pkgs.runCommand "autounattend-floppy.vfd"
      {
        nativeBuildInputs = [
          pkgs.dosfstools
          pkgs.mtools
        ];
        passAsFile = [ "xml" ];
        xml = autounattendXml;
      }
      ''
        # Create 1.44MB floppy image
        dd if=/dev/zero of=$out bs=512 count=2880
        ${pkgs.dosfstools}/bin/mkfs.vfat -n "AUTOUNATTEND" $out
        ${pkgs.mtools}/bin/mcopy -i $out $xmlPath ::Autounattend.xml
        echo "Created floppy with Autounattend.xml"
      '';

  # Windows VM creation helper script
  # This generates a shell script that can be used to create a new Windows VM
  makeWindowsVmCreationScript =
    {
      vmName,
      diskSizeGB ? 100,
      memoryGB ? 8,
      vcpus ? 4,
      storagePool ? "default",
      windowsIsoPath ? null,
      virtioIsoPath ? null,
    }:
    let
      windowsIsoArg =
        if windowsIsoPath != null then "--disk path=${windowsIsoPath},device=cdrom,readonly=on" else "";
      virtioIsoArg =
        if virtioIsoPath != null then "--disk path=${virtioIsoPath},device=cdrom,readonly=on" else "";
    in
    pkgs.writeShellScriptBin "create-${vmName}" ''
      set -e

      # Configuration
      VM_NAME="${vmName}"
      DISK_SIZE="${toString diskSizeGB}G"
      STORAGE_POOL="${storagePool}"

      echo "Creating Windows VM: $VM_NAME"

      # Ensure storage pool exists and is active
      if ! virsh -c qemu:///system pool-info "$STORAGE_POOL" &>/dev/null; then
        echo "Creating storage pool $STORAGE_POOL..."
        sudo mkdir -p /var/lib/libvirt/images
        virsh -c qemu:///system pool-define-as "$STORAGE_POOL" dir --target /var/lib/libvirt/images
        virsh -c qemu:///system pool-autostart "$STORAGE_POOL"
        virsh -c qemu:///system pool-start "$STORAGE_POOL"
      fi

      # Create disk volume if it doesn't exist
      if ! virsh -c qemu:///system vol-info "$VM_NAME.qcow2" --pool "$STORAGE_POOL" &>/dev/null; then
        echo "Creating $DISK_SIZE disk volume..."
        virsh -c qemu:///system vol-create-as "$STORAGE_POOL" "$VM_NAME.qcow2" "$DISK_SIZE" --format qcow2
      else
        echo "Disk volume already exists"
      fi

      # Check if domain already exists
      if virsh -c qemu:///system dominfo "$VM_NAME" &>/dev/null; then
        echo "Domain $VM_NAME already exists"
        exit 0
      fi

      # Create VM with virt-install
      echo "Creating VM domain..."
      virt-install \
        --connect qemu:///system \
        --name "$VM_NAME" \
        --memory ${toString (memoryGB * 1024)} \
        --vcpus ${toString vcpus} \
        --cpu host-passthrough \
        --os-variant win11 \
        --boot uefi \
        --network network=default,model=virtio \
        --graphics spice,listen=127.0.0.1 \
        --video virtio \
        --controller type=scsi,model=virtio-scsi \
        --tpm backend.type=emulator,backend.version=2.0,model=tpm-crb \
        --disk vol="$STORAGE_POOL/$VM_NAME.qcow2",bus=virtio,format=qcow2 \
        ${windowsIsoArg} \
        ${virtioIsoArg} \
        --events on_reboot=restart,on_crash=restart \
        --noautoconsole \
        --print-xml > /tmp/$VM_NAME.xml

      virsh -c qemu:///system define /tmp/$VM_NAME.xml
      rm /tmp/$VM_NAME.xml

      echo "VM $VM_NAME created successfully"
      echo ""
      echo "To start:   virsh start $VM_NAME"
      echo "To view:    virt-viewer --connect qemu:///system $VM_NAME"
      echo "To console: virsh console $VM_NAME"
    '';
}
