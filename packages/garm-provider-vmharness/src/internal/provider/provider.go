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
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"strings"
	"text/template"

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
	case config.BackendIncus:
		b = &backend.IncusBackend{
			IncusCmd:       strings.Fields(cfg.IncusPath),
			Bridge:         cfg.IncusBridge,
			IPv4CIDR:       cfg.IncusIPv4CIDR,
			IPv4Gateway:    cfg.IncusIPv4Gateway,
			RangeStart:     incusRangeStart(cfg),
			RangeEnd:       incusRangeEnd(cfg),
			Nameservers:    cfg.IncusNameservers,
			GpuPassthrough: cfg.IncusGpuPassthrough,

			ShareHostNixStore:        cfg.IncusShareHostNixStore,
			ReprobuildStore:          cfg.IncusReprobuildStore,
			ReprobuildStoreGuestPath: cfg.IncusReprobuildStoreGuestPath,
		}
	case config.BackendTartLinuxArm:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendTartLinuxArm),
			GuestOS:       "linux",
			StateDir:      cfg.StateDir,
		}
	case config.BackendTartMacos:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendTartMacos),
			GuestOS:       "macos",
			StateDir:      cfg.StateDir,
		}
	case config.BackendUtmWindowsArm:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendUtmWindowsArm),
			GuestOS:       "windows",
			StateDir:      cfg.StateDir,
		}
	case config.BackendQemuWindowsArm:
		b = &backend.VMHarnessRunBackend{
			VMHarnessPath: cfg.VMHarnessPath,
			BackendID:     string(config.BackendQemuWindowsArm),
			GuestOS:       "windows",
			StateDir:      cfg.StateDir,
		}
	default:
		return nil, fmt.Errorf("unsupported backend %q", cfg.Backend)
	}
	return &Provider{cfg: cfg, backend: b}, nil
}

// incusRangeStart/End default the static-IP allocation range to the .200-.250
// host block of the configured /24 when the operator did not set explicit
// bounds (keeps single-image pools configuration-light while staying clear of
// the low DHCP block and the gateway).
func incusRangeStart(cfg *config.Config) string {
	if cfg.IncusIPv4RangeStart != "" {
		return cfg.IncusIPv4RangeStart
	}
	return subnetHost(cfg.IncusIPv4CIDR, 200)
}

func incusRangeEnd(cfg *config.Config) string {
	if cfg.IncusIPv4RangeEnd != "" {
		return cfg.IncusIPv4RangeEnd
	}
	return subnetHost(cfg.IncusIPv4CIDR, 250)
}

// subnetHost returns the a.b.c.<host> address for the /24 the CIDR names.
func subnetHost(cidr string, host int) string {
	base := cidr
	if i := strings.LastIndex(base, "/"); i >= 0 {
		base = base[:i]
	}
	parts := strings.Split(base, ".")
	if len(parts) != 4 {
		return ""
	}
	return fmt.Sprintf("%s.%s.%s.%d", parts[0], parts[1], parts[2], host)
}

// osTypeToParams maps a backend Instance to a commonParams.ProviderInstance.
func toProviderInstance(inst backend.Instance) commonParams.ProviderInstance {
	osType := commonParams.Windows
	// The incus/Linux path tags os_name "linux"; the libvirt/Windows path
	// tags "windows". The Tart macOS path reports "macos"; garm-provider-common
	// carries OSType as a string alias, so preserve that value even though this
	// vendored version only declares Linux/Windows constants.
	if strings.EqualFold(inst.OSName, "linux") {
		osType = commonParams.Linux
	} else if strings.EqualFold(inst.OSName, "macos") || strings.EqualFold(inst.OSName, "darwin") {
		osType = commonParams.OSType("macos")
	}
	osArch := commonParams.Amd64
	if strings.EqualFold(inst.OSArch, "arm64") || strings.EqualFold(inst.OSArch, "aarch64") {
		osArch = commonParams.Arm64
	}
	pi := commonParams.ProviderInstance{
		ProviderID: inst.ProviderID,
		Name:       inst.Name,
		OSType:     osType,
		OSName:     inst.OSName,
		OSVersion:  inst.OSVersion,
		OSArch:     osArch,
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
	case commonParams.OSType("macos"):
		wantOS = "osx"
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

func shellQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}

const macosRunnerInstallTemplate = `#!/bin/sh
set -eu

CALLBACK_URL={{ shell .CallbackURL }}
METADATA_URL={{ shell .MetadataURL }}
BEARER_TOKEN={{ shell .CallbackToken }}
RUN_HOME="$HOME/actions-runner"

call_status() {
	payload="$1"
	case "$CALLBACK_URL" in
		*/status|*/status/) status_url="$CALLBACK_URL" ;;
		*) status_url="${CALLBACK_URL}/status" ;;
	esac
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X POST -d "$payload" \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"$status_url" >/dev/null || true
}

status() {
	msg=$(printf '%s' "$1" | sed 's/"/\\"/g')
	call_status "{\"status\":\"installing\",\"message\":\"$msg\"}"
}

fail() {
	msg=$(printf '%s' "$1" | sed 's/"/\\"/g')
	call_status "{\"status\":\"failed\",\"message\":\"$msg\"}"
	exit 1
}

get_metadata_file() {
	path="$1"
	dest="$2"
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X GET -H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"${METADATA_URL}/${path}" -o "$dest"
}

if [ -z "$METADATA_URL" ]; then
	fail "missing metadata URL"
fi

mkdir -p "$RUN_HOME"
cd "$RUN_HOME"

if [ ! -x ./run.sh ]; then
	status "downloading tools from {{ .DownloadURL }}"
	tmp_archive="$(mktemp "${TMPDIR:-/tmp}/actions-runner.XXXXXX")"
	temp_header=""
	if [ -n {{ shell .TempDownloadToken }} ]; then
		temp_header="Authorization: Bearer {{ .TempDownloadToken }}"
	fi
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -L \
		-H "$temp_header" -o "$tmp_archive" {{ shell .DownloadURL }} || fail "failed to download tools"
	{{- if .SHA256Checksum }}
	printf '%s  %s\n' {{ shell .SHA256Checksum }} "$tmp_archive" | shasum -a 256 -c - || fail "runner checksum mismatch"
	{{- end }}
	status "extracting runner"
	tar xzf "$tmp_archive" -C "$RUN_HOME" || fail "failed to extract runner"
	rm -f "$tmp_archive"
fi

status "configuring runner"
{{- if .UseJITConfig }}
status "downloading JIT credentials"
get_metadata_file "credentials/runner" "$RUN_HOME/.runner" || fail "failed to get runner file"
get_metadata_file "credentials/credentials" "$RUN_HOME/.credentials" || fail "failed to get credentials file"
get_metadata_file "credentials/credentials_rsaparams" "$RUN_HOME/.credentials_rsaparams" || fail "failed to get credentials_rsaparams file"
{{- else }}
GITHUB_TOKEN=$(curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
	-X GET -H 'Accept: application/json' \
	-H "Authorization: Bearer ${BEARER_TOKEN}" \
	"${METADATA_URL}/runner-registration-token/") || fail "failed to get registration token"
attempt=1
while :; do
	errout="$(mktemp "${TMPDIR:-/tmp}/runner-config.XXXXXX")"
	if ./config.sh --unattended --url {{ shell .RepoURL }} --token "$GITHUB_TOKEN" \
		{{- if .GitHubRunnerGroup }} --runnergroup {{ shell .GitHubRunnerGroup }}{{- end }} \
		--name {{ shell .RunnerName }} --labels {{ shell .RunnerLabels }} --no-default-labels --ephemeral 2>"$errout"; then
		rm -f "$errout"
		break
	fi
	last_err="$(cat "$errout")"
	rm -f "$errout"
	./config.sh remove --token "$GITHUB_TOKEN" >/dev/null 2>&1 || true
	if [ "$attempt" -ge 5 ]; then
		fail "failed to configure runner: $last_err"
	fi
	status "failed to configure runner, retrying"
	attempt=$((attempt + 1))
	sleep 5
done
{{- end }}

call_status '{"status":"idle","message":"runner configured"}'
exec ./run.sh
`

const linuxForegroundRunnerInstallTemplate = `#!/bin/bash
set -e
set -o pipefail
{{- if .EnableBootDebug }}
set -x
{{- end }}

CALLBACK_URL={{ shell .CallbackURL }}
METADATA_URL={{ shell .MetadataURL }}
BEARER_TOKEN={{ shell .CallbackToken }}
RUNNER_USER="runner"
RUNNER_GROUP="runner"
RUNNER_HOME="/home/${RUNNER_USER}"
RUN_HOME="${RUNNER_HOME}/actions-runner"

call_status() {
	payload="$1"
	case "$CALLBACK_URL" in
		*/status|*/status/) status_url="$CALLBACK_URL" ;;
		*) status_url="${CALLBACK_URL}/status" ;;
	esac
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X POST -d "$payload" \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"$status_url" >/dev/null || true
}

status() {
	msg=$(printf '%s' "$1" | sed 's/"/\\"/g')
	call_status "{\"status\":\"installing\",\"message\":\"$msg\"}"
}

fail() {
	msg=$(printf '%s' "$1" | sed 's/"/\\"/g')
	call_status "{\"status\":\"failed\",\"message\":\"$msg\"}"
	exit 1
}

get_metadata_file() {
	path="$1"
	dest="$2"
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X GET -H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"${METADATA_URL}/${path}" -o "$dest"
}

send_system_info() {
	os_name=""
	os_version=""
	if [ -f /etc/os-release ]; then
		. /etc/os-release
		os_name="${NAME:-}"
		os_version="${VERSION_ID:-}"
	fi
	base_url="$CALLBACK_URL"
	case "$base_url" in
		*/status) base_url="${base_url%/status}" ;;
		*/status/) base_url="${base_url%/status/}" ;;
	esac
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
		-X POST -d "{\"os_name\":\"${os_name}\",\"os_version\":\"${os_version}\",\"agent_id\":null}" \
		-H 'Accept: application/json' \
		-H "Authorization: Bearer ${BEARER_TOKEN}" \
		"${base_url}/system-info/" >/dev/null || true
}

if [ "$(id -u)" -ne 0 ]; then
	exec sudo -E bash "$0" "$@"
fi
if [ -z "$METADATA_URL" ]; then
	fail "missing metadata URL"
fi
if ! getent group "$RUNNER_GROUP" >/dev/null 2>&1; then
	groupadd "$RUNNER_GROUP"
fi
if ! id -u "$RUNNER_USER" >/dev/null 2>&1; then
	useradd -m -s /bin/bash -g "$RUNNER_GROUP" "$RUNNER_USER"
fi
mkdir -p "$RUN_HOME"

if [ ! -x "$RUN_HOME/run.sh" ]; then
	status "downloading tools from {{ .DownloadURL }}"
	tmp_archive="$(mktemp /tmp/actions-runner.XXXXXX)"
	temp_header=""
	if [ -n {{ shell .TempDownloadToken }} ]; then
		temp_header="Authorization: Bearer {{ .TempDownloadToken }}"
	fi
	curl --retry 5 --retry-delay 5 --retry-connrefused --fail -L \
		-H "$temp_header" -o "$tmp_archive" {{ shell .DownloadURL }} || fail "failed to download tools"
	{{- if .SHA256Checksum }}
	printf '%s  %s\n' {{ shell .SHA256Checksum }} "$tmp_archive" | sha256sum -c - || fail "runner checksum mismatch"
	{{- end }}
	status "extracting runner"
	tar xf "$tmp_archive" -C "$RUN_HOME"/ || fail "failed to extract runner"
	rm -f "$tmp_archive"
fi

chown "$RUNNER_USER:$RUNNER_GROUP" -R "$RUNNER_HOME" || fail "failed to change runner home owner"
status "installing dependencies"
cd "$RUN_HOME"
attempt=1
while :; do
	if ./bin/installdependencies.sh; then
		break
	fi
	if [ "$attempt" -ge 5 ]; then
		fail "failed to install dependencies after $attempt attempts"
	fi
	status "failed to install dependencies, retrying"
	attempt=$((attempt + 1))
	sleep 15
done

status "configuring runner"
{{- if .UseJITConfig }}
status "downloading JIT credentials"
get_metadata_file "credentials/runner" "$RUN_HOME/.runner" || fail "failed to get runner file"
get_metadata_file "credentials/credentials" "$RUN_HOME/.credentials" || fail "failed to get credentials file"
get_metadata_file "credentials/credentials_rsaparams" "$RUN_HOME/.credentials_rsaparams" || fail "failed to get credentials_rsaparams file"
{{- else }}
GITHUB_TOKEN=$(curl --retry 5 --retry-delay 5 --retry-connrefused --fail -s \
	-X GET -H 'Accept: application/json' \
	-H "Authorization: Bearer ${BEARER_TOKEN}" \
	"${METADATA_URL}/runner-registration-token/") || fail "failed to get registration token"
set +e
attempt=1
while :; do
	errout="$(mktemp /tmp/runner-config.XXXXXX)"
	if sudo -u "$RUNNER_USER" -H "$RUN_HOME/config.sh" --unattended --url {{ shell .RepoURL }} --token "$GITHUB_TOKEN" \
		{{- if .GitHubRunnerGroup }} --runnergroup {{ shell .GitHubRunnerGroup }}{{- end }} \
		--name {{ shell .RunnerName }} --labels {{ shell .RunnerLabels }} --no-default-labels --ephemeral 2>"$errout"; then
		rm -f "$errout"
		break
	fi
	last_err="$(cat "$errout")"
	rm -f "$errout"
	sudo -u "$RUNNER_USER" -H "$RUN_HOME/config.sh" remove --token "$GITHUB_TOKEN" >/dev/null 2>&1 || true
	if [ "$attempt" -ge 5 ]; then
		set -e
		fail "failed to configure runner: $last_err"
	fi
	status "failed to configure runner, retrying"
	attempt=$((attempt + 1))
	sleep 5
done
set -e
{{- end }}

chown "$RUNNER_USER:$RUNNER_GROUP" -R "$RUNNER_HOME" || fail "failed to change runner home owner"
send_system_info
call_status '{"status":"idle","message":"runner configured"}'
cd "$RUN_HOME"
exec sudo -u "$RUNNER_USER" -H ./run.sh
`

type runnerInstallTemplateData struct {
	FileName          string
	DownloadURL       string
	TempDownloadToken string
	SHA256Checksum    string
	MetadataURL       string
	RepoURL           string
	RunnerName        string
	RunnerLabels      string
	CallbackURL       string
	CallbackToken     string
	GitHubRunnerGroup string
	UseJITConfig      bool
	EnableBootDebug   bool
}

func runnerInstallTemplateDataFrom(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) runnerInstallTemplateData {
	return runnerInstallTemplateData{
		FileName:          tools.GetFilename(),
		DownloadURL:       tools.GetDownloadURL(),
		TempDownloadToken: tools.GetTempDownloadToken(),
		SHA256Checksum:    tools.GetSHA256Checksum(),
		MetadataURL:       bootstrapParams.MetadataURL,
		RepoURL:           bootstrapParams.RepoURL,
		RunnerName:        runnerName,
		RunnerLabels:      strings.Join(bootstrapParams.Labels, ","),
		CallbackURL:       bootstrapParams.CallbackURL,
		CallbackToken:     bootstrapParams.InstanceToken,
		GitHubRunnerGroup: bootstrapParams.GitHubRunnerGroup,
		UseJITConfig:      bootstrapParams.JitConfigEnabled,
		EnableBootDebug:   bootstrapParams.UserDataOptions.EnableBootDebug,
	}
}

func renderRunnerInstallTemplate(name, text string, data runnerInstallTemplateData) ([]byte, error) {
	tpl, err := template.New(name).Funcs(template.FuncMap{
		"shell": shellQuote,
	}).Parse(text)
	if err != nil {
		return nil, err
	}
	var buf bytes.Buffer
	if err := tpl.Execute(&buf, data); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func renderMacOSRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if tools.GetFilename() == "" {
		return nil, fmt.Errorf("missing tools filename")
	}
	if tools.GetDownloadURL() == "" {
		return nil, fmt.Errorf("missing tools download URL")
	}
	return renderRunnerInstallTemplate("macos-runner-install", macosRunnerInstallTemplate, runnerInstallTemplateDataFrom(bootstrapParams, tools, runnerName))
}

func renderLinuxRunnerInstallScript(bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if tools.GetFilename() == "" {
		return nil, fmt.Errorf("missing tools filename")
	}
	if tools.GetDownloadURL() == "" {
		return nil, fmt.Errorf("missing tools download URL")
	}
	return renderRunnerInstallTemplate("linux-foreground-runner-install", linuxForegroundRunnerInstallTemplate, runnerInstallTemplateDataFrom(bootstrapParams, tools, runnerName))
}

func renderRunnerBootstrapForBackend(backendKind config.BackendKind, bootstrapParams commonParams.BootstrapInstance, tools commonParams.RunnerApplicationDownload, runnerName string) ([]byte, error) {
	if bootstrapParams.OSType == commonParams.OSType("macos") {
		return renderMacOSRunnerInstallScript(bootstrapParams, tools, runnerName)
	}
	if backendKind == config.BackendTartLinuxArm && bootstrapParams.OSType == commonParams.Linux {
		return renderLinuxRunnerInstallScript(bootstrapParams, tools, runnerName)
	}
	script, err := cloudconfig.GetRunnerInstallScript(bootstrapParams, tools, runnerName)
	if err != nil {
		return nil, err
	}
	return script, nil
}

func replaceURLInBytes(data []byte, oldURL, newURL string) []byte {
	if oldURL == "" || newURL == "" || oldURL == newURL {
		return data
	}
	return bytes.ReplaceAll(data, []byte(oldURL), []byte(newURL))
}

func replaceURLInString(data, oldURL, newURL string) string {
	if oldURL == "" || newURL == "" || oldURL == newURL {
		return data
	}
	return strings.ReplaceAll(data, oldURL, newURL)
}

func rewriteCloudConfigSpecURLs(raw json.RawMessage, oldMetadataURL, newMetadataURL, oldCallbackURL, newCallbackURL string) json.RawMessage {
	if len(raw) == 0 {
		return raw
	}
	var spec map[string]json.RawMessage
	if err := json.Unmarshal(raw, &spec); err != nil {
		return raw
	}

	if value, ok := spec["runner_install_template"]; ok {
		var script []byte
		if err := json.Unmarshal(value, &script); err == nil {
			script = replaceURLInBytes(script, oldMetadataURL, newMetadataURL)
			script = replaceURLInBytes(script, oldCallbackURL, newCallbackURL)
			if encoded, err := json.Marshal(script); err == nil {
				spec["runner_install_template"] = encoded
			}
		}
	}
	if value, ok := spec["pre_install_scripts"]; ok {
		var scripts map[string][]byte
		if err := json.Unmarshal(value, &scripts); err == nil {
			for name, script := range scripts {
				script = replaceURLInBytes(script, oldMetadataURL, newMetadataURL)
				script = replaceURLInBytes(script, oldCallbackURL, newCallbackURL)
				scripts[name] = script
			}
			if encoded, err := json.Marshal(scripts); err == nil {
				spec["pre_install_scripts"] = encoded
			}
		}
	}
	if value, ok := spec["extra_context"]; ok {
		var extraContext map[string]string
		if err := json.Unmarshal(value, &extraContext); err == nil {
			for key, value := range extraContext {
				value = replaceURLInString(value, oldMetadataURL, newMetadataURL)
				value = replaceURLInString(value, oldCallbackURL, newCallbackURL)
				extraContext[key] = value
			}
			if encoded, err := json.Marshal(extraContext); err == nil {
				spec["extra_context"] = encoded
			}
		}
	}

	rewritten, err := json.Marshal(spec)
	if err != nil {
		return raw
	}
	return rewritten
}

func applyGuestURLOverrides(bootstrapParams commonParams.BootstrapInstance, cfg *config.Config) commonParams.BootstrapInstance {
	if cfg == nil {
		return bootstrapParams
	}
	originalMetadataURL := bootstrapParams.MetadataURL
	originalCallbackURL := bootstrapParams.CallbackURL
	if cfg.GuestMetadataURL != "" {
		bootstrapParams.MetadataURL = cfg.GuestMetadataURL
	}
	if cfg.GuestCallbackURL != "" {
		bootstrapParams.CallbackURL = cfg.GuestCallbackURL
	}
	bootstrapParams.ExtraSpecs = rewriteCloudConfigSpecURLs(
		bootstrapParams.ExtraSpecs,
		originalMetadataURL,
		bootstrapParams.MetadataURL,
		originalCallbackURL,
		bootstrapParams.CallbackURL,
	)
	return bootstrapParams
}

// CreateInstance renders the runner bootstrap and asks the backend to
// materialise a per-job domain tagged with the controller/pool identity.
func (p *Provider) CreateInstance(ctx context.Context, bootstrapParams commonParams.BootstrapInstance) (commonParams.ProviderInstance, error) {
	controllerID := os.Getenv("GARM_CONTROLLER_ID")
	bootstrapParams = applyGuestURLOverrides(bootstrapParams, p.cfg)

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
		script, serr := renderRunnerBootstrapForBackend(p.cfg.Backend, bootstrapParams, tools, bootstrapParams.Name)
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
		OSArch:       string(bootstrapParams.OSArch),
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
