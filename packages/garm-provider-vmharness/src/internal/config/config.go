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
	if c.LibvirtURI == "" {
		c.LibvirtURI = "qemu:///system"
	}
	if c.Images == nil {
		c.Images = map[string]GoldenImage{}
	}
}

// Validate returns an error if the config is internally inconsistent.
func (c *Config) Validate() error {
	switch c.Backend {
	case BackendLibvirt:
	default:
		return fmt.Errorf("unsupported backend %q (supported: %q)", c.Backend, BackendLibvirt)
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
