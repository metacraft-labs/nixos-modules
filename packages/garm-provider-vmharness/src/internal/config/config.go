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

// Package config parses the garm-provider-vmharness provider configuration
// file (the path GARM passes via GARM_PROVIDER_CONFIG_FILE). The file is TOML.
//
// The provider is STATELESS: it persists NO lifecycle state. This config only
// tells the provider HOW to reach the backend (which vm-harness/virsh binaries
// to shell to, the libvirt connection URI, the network, and the golden-image
// map that resolves a pool's image/flavor to a concrete libvirt source).
package config

import (
	"fmt"
	"os"

	"github.com/BurntSushi/toml"
)

// BackendKind selects the mechanism the provider uses to drive libvirt.
type BackendKind string

const (
	// BackendLibvirt shells to `virsh` (and, in M2+, `vm-harness`) to manage
	// per-job Windows domains cloned from a golden image.
	BackendLibvirt BackendKind = "libvirt"
	// BackendIncus shells to `incus` to manage per-job Linux SYSTEM
	// CONTAINERS launched from a runner image (the container-based analog of
	// the libvirt path — IM3). Container launch is sub-second and needs no
	// /dev/kvm, so the ephemeral loop (fresh container per job → one job →
	// destroy) is far cheaper than the VM path.
	BackendIncus BackendKind = "incus"
)

// GoldenImage maps a pool label/flavor to a concrete libvirt source.
//
// In M1 the per-job clone is still a vm-harness stub (that lands in M2) and the
// real config-drive injection lands in M3, so these fields are recorded and
// passed to the backend but the backend is free to treat clone/injection as a
// no-op when running against a mock virsh (the hermetic gate path).
type GoldenImage struct {
	// SourceImage is the golden qcow2 (or volume) the per-job domain is cloned
	// from. Consumed by the vm-harness/libvirt clone path (M2).
	SourceImage string `toml:"source_image"`
	// OSName is the reported OS name (eg: "windows"), surfaced in
	// ProviderInstance.os_name.
	OSName string `toml:"os_name"`
	// OSVersion is the reported OS version (eg: "2022").
	OSVersion string `toml:"os_version"`
}

// Config is the parsed provider configuration.
type Config struct {
	// Backend selects the VM management mechanism. Defaults to "libvirt".
	Backend BackendKind `toml:"backend"`

	// VirshPath is the path to the `virsh` binary the provider shells to. The
	// hermetic gate points this at a mock virsh that emulates domain lifecycle
	// without KVM. Defaults to "virsh" (resolved via PATH).
	VirshPath string `toml:"virsh_path"`

	// VMHarnessPath is the path to the `vm-harness` binary used for the per-job
	// clone + config-drive injection. In M1 this is only recorded (the real
	// clone lands in M2, injection in M3); the seam is kept explicit so those
	// milestones can wire it without changing the protocol surface.
	VMHarnessPath string `toml:"vm_harness_path"`

	// QemuImgPath is the path to the `qemu-img` binary used to create the
	// per-job CoW overlay over the golden (M4 clone path). Defaults to
	// "qemu-img" (resolved via PATH).
	QemuImgPath string `toml:"qemu_img_path"`

	// UEFILoader / UEFINVRAMTemplate configure OVMF firmware for the per-job
	// domain (Windows 11 requires UEFI). UEFILoader is the read-only OVMF code
	// firmware (eg /run/libvirt/nix-ovmf/edk2-x86_64-code.fd) and
	// UEFINVRAMTemplate the OVMF vars template that is copied into a per-job
	// writable nvram file. When UEFILoader is empty the domain boots via
	// SeaBIOS (kept so the hermetic M1 mock gate, which never boots a real
	// guest, is unchanged).
	UEFILoader        string `toml:"uefi_loader"`
	UEFINVRAMTemplate string `toml:"uefi_nvram_template"`

	// MemoryMB / VCPUs size the per-job domain. Zero => conservative defaults
	// (4096 MiB / 2 vCPU) applied in the domain-XML builder.
	MemoryMB int `toml:"memory_mb"`
	VCPUs    int `toml:"vcpus"`

	// LibvirtURI is the libvirt connection URI (eg: "qemu:///system"). Passed
	// to virsh as `-c`.
	LibvirtURI string `toml:"libvirt_uri"`

	// Network is the libvirt network the per-job domains attach to. Recorded
	// for the M2 clone; not required by the M1 protocol gate.
	Network string `toml:"network"`

	// PoolDir is the libvirt image pool directory where per-job artifacts (the
	// CoW overlay + the M3 config-drive ISO) are written. When empty the
	// provider skips config-drive injection (the hermetic M1 gate). On a real
	// host this is typically "/var/lib/libvirt/images".
	PoolDir string `toml:"pool_dir"`

	// Images maps a pool image identifier (BootstrapInstance.Image, typically a
	// label/flavor key) to a concrete golden source. If a pool's image is not
	// present here, the raw image string is used as the source directly.
	Images map[string]GoldenImage `toml:"images"`

	// ---- Incus backend (IM3) -------------------------------------------
	// These fields are consumed only when Backend == "incus". For the incus
	// path a GoldenImage's SourceImage is an incus IMAGE ALIAS (eg
	// "runner-linux") rather than a qcow2 path.

	// IncusPath is the incus binary the provider shells to. Defaults to
	// "incus" (resolved via PATH). GARM runs as root, which can reach the
	// incus-admin socket directly.
	IncusPath string `toml:"incus_path"`

	// IncusBridge is the managed incus bridge the per-job containers attach
	// to (their eth0). Defaults to "incusbr0". Informational — the container
	// inherits it from the default profile — but recorded for clarity.
	IncusBridge string `toml:"incus_bridge"`

	// The incus DHCP server on incusbr0 does not lease on this host (nixos-fw
	// drops the DHCP path), so the provider injects a STATIC IPv4 via
	// cloud-init.network-config. It allocates the lowest free host address in
	// [IncusIPv4RangeStart, IncusIPv4RangeEnd] (full dotted IPs) on the
	// IncusIPv4CIDR subnet, routing default via IncusIPv4Gateway and resolving
	// through IncusNameservers. Egress itself works through incus's existing
	// NAT (no host firewall change); only the lease is worked around here.
	IncusIPv4CIDR       string   `toml:"incus_ipv4_cidr"`
	IncusIPv4Gateway    string   `toml:"incus_ipv4_gateway"`
	IncusIPv4RangeStart string   `toml:"incus_ipv4_range_start"`
	IncusIPv4RangeEnd   string   `toml:"incus_ipv4_range_end"`
	IncusNameservers    []string `toml:"incus_nameservers"`
}

// Defaults returns a Config populated with sensible defaults for fields the
// operator did not set.
func (c *Config) applyDefaults() {
	if c.Backend == "" {
		c.Backend = BackendLibvirt
	}
	if c.VirshPath == "" {
		c.VirshPath = "virsh"
	}
	if c.VMHarnessPath == "" {
		c.VMHarnessPath = "vm-harness"
	}
	if c.QemuImgPath == "" {
		c.QemuImgPath = "qemu-img"
	}
	if c.LibvirtURI == "" {
		c.LibvirtURI = "qemu:///system"
	}
	if c.Images == nil {
		c.Images = map[string]GoldenImage{}
	}
	if c.IncusPath == "" {
		c.IncusPath = "incus"
	}
	if c.IncusBridge == "" {
		c.IncusBridge = "incusbr0"
	}
	if len(c.IncusNameservers) == 0 {
		c.IncusNameservers = []string{"1.1.1.1", "8.8.8.8"}
	}
}

// Validate returns an error if the config is internally inconsistent.
func (c *Config) Validate() error {
	switch c.Backend {
	case BackendLibvirt:
	case BackendIncus:
		// Static-IP injection needs a subnet + gateway (DHCP is broken on
		// incusbr0). The range is optional: it defaults to the whole subnet
		// minus the gateway when unset, but a subnet + gateway are required.
		if c.IncusIPv4CIDR == "" || c.IncusIPv4Gateway == "" {
			return fmt.Errorf("backend %q requires incus_ipv4_cidr and incus_ipv4_gateway (incusbr0 DHCP does not lease on this host)", c.Backend)
		}
	default:
		return fmt.Errorf("unsupported backend %q (supported: %q, %q)", c.Backend, BackendLibvirt, BackendIncus)
	}
	return nil
}

// Parse reads and parses the provider config file at path.
func Parse(path string) (*Config, error) {
	var cfg Config
	if _, err := toml.DecodeFile(path, &cfg); err != nil {
		return nil, fmt.Errorf("decoding provider config %q: %w", path, err)
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// ParseBytes parses provider config from an in-memory TOML blob. Useful for
// tests and for the ValidatePoolInfo command which receives the config path.
func ParseBytes(data []byte) (*Config, error) {
	var cfg Config
	if err := toml.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("decoding provider config: %w", err)
	}
	cfg.applyDefaults()
	if err := cfg.Validate(); err != nil {
		return nil, err
	}
	return &cfg, nil
}

// ResolveImage returns the golden source + OS metadata for a pool image key.
// If the key is not present in the Images map, the raw key is used as the
// source image directly (with empty OS metadata), which keeps simple single
// image pools configuration-free.
func (c *Config) ResolveImage(image string) GoldenImage {
	if gi, ok := c.Images[image]; ok {
		if gi.SourceImage == "" {
			gi.SourceImage = image
		}
		return gi
	}
	return GoldenImage{SourceImage: image}
}

// mustExist is a small helper used by callers that need to fail fast when the
// config file is missing. GARM's harness already Lstat's the file, but the
// provider double-checks for clearer error messages.
func mustExist(path string) error {
	if _, err := os.Stat(path); err != nil {
		return fmt.Errorf("provider config file %q: %w", path, err)
	}
	return nil
}

var _ = mustExist
