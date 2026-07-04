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

// Package provider implements GARM's v0.1.1 external-provider interface for the
// vmharness backend. It is STATELESS: no lifecycle state is persisted here —
// GARM's DB owns it — and every query recomputes from the libvirt backend via
// the domain <metadata> tags (controller_id / pool_id / name).
package provider

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"

	"github.com/cloudbase/garm-provider-common/cloudconfig"
	garmErrors "github.com/cloudbase/garm-provider-common/errors"
	commonExecution "github.com/cloudbase/garm-provider-common/execution/common"
	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/backend"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/version"
)

// Provider implements executionv011.ExternalProvider.
type Provider struct {
	cfg     *config.Config
	backend backend.Backend
}

// New builds a Provider from the config file path GARM passes via
// GARM_PROVIDER_CONFIG_FILE.
func New(configFile string) (*Provider, error) {
	cfg, err := config.Parse(configFile)
	if err != nil {
		return nil, err
	}
	return NewWithConfig(cfg)
}

// NewWithConfig builds a Provider from an already-parsed config, wiring the
// backend the config selects. Exposed for tests.
func NewWithConfig(cfg *config.Config) (*Provider, error) {
	var b backend.Backend
	switch cfg.Backend {
	case config.BackendLibvirt:
		b = &backend.VirshBackend{
			VirshPath:         cfg.VirshPath,
			URI:               cfg.LibvirtURI,
			VMHarnessPath:     cfg.VMHarnessPath,
			PoolDir:           cfg.PoolDir,
			QemuImgPath:       cfg.QemuImgPath,
			UEFILoader:        cfg.UEFILoader,
			UEFINVRAMTemplate: cfg.UEFINVRAMTemplate,
			MemoryMB:          cfg.MemoryMB,
			VCPUs:             cfg.VCPUs,
		}
	default:
		return nil, fmt.Errorf("unsupported backend %q", cfg.Backend)
	}
	return &Provider{cfg: cfg, backend: b}, nil
}

// osTypeToParams maps a backend Instance to a commonParams.ProviderInstance.
func toProviderInstance(inst backend.Instance) commonParams.ProviderInstance {
	pi := commonParams.ProviderInstance{
		ProviderID: inst.ProviderID,
		Name:       inst.Name,
		OSType:     commonParams.Windows,
		OSName:     inst.OSName,
		OSVersion:  inst.OSVersion,
		OSArch:     commonParams.Amd64,
		Status:     commonParams.InstanceStatus(inst.Status),
	}
	for _, addr := range inst.Addresses {
		pi.Addresses = append(pi.Addresses, commonParams.Address{
			Address: addr,
			Type:    commonParams.PrivateAddress,
		})
	}
	if pi.Status == "" {
		pi.Status = commonParams.InstanceStatusUnknown
	}
	return pi
}

// pickTools selects the runner tools matching the bootstrap's OS/arch.
func pickTools(bootstrapParams commonParams.BootstrapInstance) (commonParams.RunnerApplicationDownload, error) {
	wantOS := "win"
	switch bootstrapParams.OSType {
	case commonParams.Linux:
		wantOS = "linux"
	case commonParams.Windows:
		wantOS = "win"
	}
	wantArch := "x64"
	switch bootstrapParams.OSArch {
	case commonParams.Arm64:
		wantArch = "arm64"
	case commonParams.Arm:
		wantArch = "arm"
	}
	for _, t := range bootstrapParams.Tools {
		if t.GetOS() == wantOS && t.GetArchitecture() == wantArch {
			return t, nil
		}
	}
	return commonParams.RunnerApplicationDownload{}, fmt.Errorf("no tools for os=%s arch=%s", wantOS, wantArch)
}

// CreateInstance renders the runner bootstrap and asks the backend to
// materialise a per-job domain tagged with the controller/pool identity.
func (p *Provider) CreateInstance(ctx context.Context, bootstrapParams commonParams.BootstrapInstance) (commonParams.ProviderInstance, error) {
	controllerID := os.Getenv("GARM_CONTROLLER_ID")

	golden := p.cfg.ResolveImage(bootstrapParams.Image)
	osName := golden.OSName
	if osName == "" {
		osName = string(bootstrapParams.OSType)
	}

	// Render the runner bootstrap (Windows PowerShell / Linux shell) using
	// GARM's own template so the guest installs + JIT-registers the runner. The
	// injection of this into the guest is the M3 config-drive path; we render it
	// here and carry it through the backend seam.
	var bootstrap []byte
	if tools, err := pickTools(bootstrapParams); err == nil {
		script, serr := cloudconfig.GetRunnerInstallScript(bootstrapParams, tools, bootstrapParams.Name)
		if serr != nil {
			return commonParams.ProviderInstance{}, fmt.Errorf("rendering runner bootstrap: %w", serr)
		}
		bootstrap = script
	}
	// NOTE: if no matching tools are supplied (eg the hermetic gate uses a
	// minimal bootstrap), the domain is still created; the M3 milestone makes
	// tool selection mandatory once real injection lands.

	inst, err := p.backend.Create(ctx, backend.CreateArgs{
		Name:         bootstrapParams.Name,
		ControllerID: controllerID,
		PoolID:       bootstrapParams.PoolID,
		SourceImage:  golden.SourceImage,
		OSName:       osName,
		OSVersion:    golden.OSVersion,
		Flavor:       bootstrapParams.Flavor,
		Network:      p.cfg.Network,
		Bootstrap:    bootstrap,
	})
	if err != nil {
		return commonParams.ProviderInstance{
			Name:          bootstrapParams.Name,
			OSType:        bootstrapParams.OSType,
			Status:        commonParams.InstanceError,
			ProviderFault: []byte(err.Error()),
		}, err
	}
	pi := toProviderInstance(inst)
	// CreateInstance must report a running instance (GARM's ValidateResult
	// requires provider_id + a status). The backend started the domain.
	if pi.Status == "" || pi.Status == commonParams.InstanceStatusUnknown {
		pi.Status = commonParams.InstanceRunning
	}
	if pi.OSType == "" {
		pi.OSType = bootstrapParams.OSType
	}
	return pi, nil
}

// DeleteInstance destroys + undefines the domain. Idempotent: returns
// garmErrors.ErrNotFound (=> exit 30) only when the harness should signal
// not-found; a genuinely-absent domain is treated as success.
func (p *Provider) DeleteInstance(ctx context.Context, instance string) error {
	if err := p.backend.Delete(ctx, instance); err != nil {
		if errors.Is(err, garmErrors.ErrNotFound) {
			// Absence during delete is success (idempotent).
			return nil
		}
		return err
	}
	return nil
}

// GetInstance recomputes one domain's view from the backend.
func (p *Provider) GetInstance(ctx context.Context, instance string) (commonParams.ProviderInstance, error) {
	inst, err := p.backend.Get(ctx, instance)
	if err != nil {
		return commonParams.ProviderInstance{}, err
	}
	return toProviderInstance(inst), nil
}

// ListInstances recomputes all domains for a pool from the backend.
func (p *Provider) ListInstances(ctx context.Context, poolID string) ([]commonParams.ProviderInstance, error) {
	insts, err := p.backend.List(ctx, poolID)
	if err != nil {
		return nil, err
	}
	out := make([]commonParams.ProviderInstance, 0, len(insts))
	for _, inst := range insts {
		out = append(out, toProviderInstance(inst))
	}
	return out, nil
}

// RemoveAllInstances removes every domain tagged with the controller ID.
func (p *Provider) RemoveAllInstances(ctx context.Context) error {
	controllerID := os.Getenv("GARM_CONTROLLER_ID")
	insts, err := p.backend.ListByController(ctx, controllerID)
	if err != nil {
		return err
	}
	for _, inst := range insts {
		if derr := p.backend.Delete(ctx, inst.Name); derr != nil && !errors.Is(derr, garmErrors.ErrNotFound) {
			return derr
		}
	}
	return nil
}

// Stop shuts a domain down.
func (p *Provider) Stop(ctx context.Context, instance string, force bool) error {
	return p.backend.Stop(ctx, instance, force)
}

// Start boots a domain.
func (p *Provider) Start(ctx context.Context, instance string) error {
	return p.backend.Start(ctx, instance)
}

// GetVersion returns the provider version.
func (p *Provider) GetVersion(ctx context.Context) string {
	return version.Version
}

// GetSupportedInterfaceVersions returns the GARM external-provider interface
// versions this provider implements.
func (p *Provider) GetSupportedInterfaceVersions(ctx context.Context) []string {
	return []string{commonExecution.Version011}
}

// ValidatePoolInfo validates that a pool's image/flavor and provider config are
// usable by this provider.
func (p *Provider) ValidatePoolInfo(ctx context.Context, image string, flavor string, providerConfig string, extraspecs string) error {
	if image == "" {
		return fmt.Errorf("image is required")
	}
	// Ensure the resolved golden source is non-empty (either mapped or the raw
	// image identifier is used directly).
	if p.cfg.ResolveImage(image).SourceImage == "" {
		return fmt.Errorf("image %q does not resolve to a golden source", image)
	}
	if extraspecs != "" && extraspecs != "{}" {
		var probe map[string]any
		if err := json.Unmarshal([]byte(extraspecs), &probe); err != nil {
			return fmt.Errorf("invalid extra_specs: %w", err)
		}
	}
	return nil
}

// GetConfigJSONSchema returns the JSON schema for the provider config file.
func (p *Provider) GetConfigJSONSchema(ctx context.Context) (string, error) {
	return configJSONSchema, nil
}

// GetExtraSpecsJSONSchema returns the JSON schema for per-pool extra specs.
func (p *Provider) GetExtraSpecsJSONSchema(ctx context.Context) (string, error) {
	return extraSpecsJSONSchema, nil
}
