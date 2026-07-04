// Copyright 2026 Metacraft Labs
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain
//    a copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
//    License for the specific language governing permissions and limitations
//    under the License.

package backend

import (
	"fmt"
	"html"
)

// buildDomainXML renders the libvirt domain XML the provider hands to
// `virsh define`. The <metadata> block carries the stateless identity so
// GetInstance/ListInstances can recompute from `virsh dumpxml` alone.
//
// The device model is the M4 per-job Windows model: the boot disk points at
// the CoW overlay (args.DiskSource; falls back to SourceImage for the hermetic
// M1 mock path that never boots), and when args.UEFILoader is set the domain
// boots via OVMF pflash + a per-job writable nvram with the SMM + hyperv
// enlightenments Windows 11 needs. This mirrors, in Go, vm-harness's proven
// buildEphemeralDomainXml (which booted the same golden on real KVM in M2/M3).
// The mock virsh used by the hermetic M1 gate ignores the device model.
func buildDomainXML(args CreateArgs, metaInner, configDriveISO string) string {
	disk := args.DiskSource
	if disk == "" {
		disk = args.SourceImage
	}
	source := html.EscapeString(disk)
	name := html.EscapeString(args.Name)
	network := args.Network
	if network == "" {
		network = "default"
	}
	network = html.EscapeString(network)

	mem := args.MemoryMB
	if mem <= 0 {
		mem = 4096
	}
	vcpus := args.VCPUs
	if vcpus <= 0 {
		vcpus = 2
	}

	uefi := args.UEFILoader != ""

	// <os> block: OVMF pflash loader + per-job nvram (UEFI/Windows 11) or a
	// plain hd boot (SeaBIOS) for the mock/hermetic path.
	osBlock := "  <os>\n    <type arch='x86_64' machine='q35'>hvm</type>\n"
	if uefi {
		osBlock += fmt.Sprintf(
			"    <loader readonly='yes' type='pflash' format='raw'>%s</loader>\n",
			html.EscapeString(args.UEFILoader))
		if args.UEFINVRAM != "" {
			if args.UEFINVRAMTemplate != "" {
				osBlock += fmt.Sprintf(
					"    <nvram template='%s' templateFormat='raw' format='raw'>%s</nvram>\n",
					html.EscapeString(args.UEFINVRAMTemplate), html.EscapeString(args.UEFINVRAM))
			} else {
				osBlock += fmt.Sprintf("    <nvram format='raw'>%s</nvram>\n",
					html.EscapeString(args.UEFINVRAM))
			}
		}
	}
	osBlock += "    <boot dev='hd'/>\n  </os>\n"

	// Windows 11 on UEFI requires SMM + APIC; hyperv enlightenments improve
	// stability. The SeaBIOS path keeps a minimal <acpi/><apic/>.
	features := "  <features>\n    <acpi/>\n    <apic/>\n  </features>\n"
	cpuBlock := ""
	clockBlock := ""
	if uefi {
		features = "  <features>\n" +
			"    <acpi/>\n    <apic/>\n" +
			"    <hyperv mode='custom'>\n" +
			"      <relaxed state='on'/>\n" +
			"      <vapic state='on'/>\n" +
			"      <spinlocks state='on' retries='8191'/>\n" +
			"    </hyperv>\n" +
			"    <smm state='on'/>\n" +
			"  </features>\n"
		cpuBlock = "  <cpu mode='host-passthrough'/>\n"
		// UTC, not localtime: the golden's Windows timezone is UTC with the RTC
		// treated as local time (RealTimeIsUniversal unset), so the guest's
		// wall-clock UTC must equal the RTC. offset='localtime' would feed the
		// host's local time (eg UTC+3) as the guest RTC, skewing the guest UTC
		// and making GitHub reject the runner's JIT/OAuth token (its not-before
		// is stamped in the skewed clock) -> "registration has been deleted".
		clockBlock = "  <clock offset='utc'>\n" +
			"    <timer name='rtc' tickpolicy='catchup'/>\n" +
			"    <timer name='hpet' present='no'/>\n" +
			"    <timer name='hypervclock' present='yes'/>\n" +
			"  </clock>\n"
	}

	// M3: attach the cloudbase-init config-drive as a read-only SATA CD-ROM
	// when present, so the guest fetches + runs the injected JIT bootstrap.
	configDrive := ""
	if configDriveISO != "" {
		configDrive = fmt.Sprintf(`    <disk type='file' device='cdrom'>
      <driver name='qemu' type='raw'/>
      <source file='%s'/>
      <target dev='sda' bus='sata'/>
      <readonly/>
    </disk>
`, html.EscapeString(configDriveISO))
	}

	return fmt.Sprintf(`<domain type='kvm'>
  <name>%s</name>
  <metadata>
%s
  </metadata>
  <memory unit='MiB'>%d</memory>
  <vcpu>%d</vcpu>
%s%s%s%s  <devices>
    <disk type='file' device='disk'>
      <driver name='qemu' type='qcow2'/>
      <source file='%s'/>
      <target dev='vda' bus='virtio'/>
    </disk>
%s    <interface type='network'>
      <source network='%s'/>
      <model type='virtio'/>
    </interface>
    <graphics type='vnc' port='-1'/>
    <video>
      <model type='qxl'/>
    </video>
    <console type='pty'/>
  </devices>
</domain>
`, name, metaInner, mem, vcpus, osBlock, features, cpuBlock, clockBlock, source, configDrive, network)
}
