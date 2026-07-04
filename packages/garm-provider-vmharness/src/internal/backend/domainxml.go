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
// M1 NOTE: this is a minimal, deliberately-generic domain skeleton. The real
// per-job device model (the CoW-clone golden disk + config-drive ISO) is wired
// in M2 (clone) and M3 (injection); the SourceImage + Bootstrap on CreateArgs
// are the seam those milestones consume. The disk source below points at the
// resolved golden image so a real libvirt host has a bootable reference, while
// the mock virsh used by the hermetic gate ignores the device model entirely.
func buildDomainXML(args CreateArgs, metaInner, configDriveISO string) string {
	source := html.EscapeString(args.SourceImage)
	name := html.EscapeString(args.Name)
	network := args.Network
	if network == "" {
		network = "default"
	}
	network = html.EscapeString(network)

	// M3: attach the cloudbase-init config-drive as a read-only CD-ROM when
	// present, so the guest fetches + runs the injected JIT bootstrap.
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

	// A conservative q35/UEFI-capable shell. Memory/vCPU are placeholders; the
	// pool flavor -> resource mapping is finalised alongside the M2 clone.
	return fmt.Sprintf(`<domain type='kvm'>
  <name>%s</name>
  <metadata>
%s
  </metadata>
  <memory unit='MiB'>4096</memory>
  <vcpu>2</vcpu>
  <os>
    <type arch='x86_64' machine='q35'>hvm</type>
    <boot dev='hd'/>
  </os>
  <features>
    <acpi/>
    <apic/>
  </features>
  <devices>
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
    <console type='pty'/>
  </devices>
</domain>
`, name, metaInner, source, configDrive, network)
}
