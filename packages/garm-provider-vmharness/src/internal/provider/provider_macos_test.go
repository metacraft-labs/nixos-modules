package provider

import (
	"strings"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/backend"
	"github.com/metacraft-labs/garm-provider-vmharness/internal/config"
)

func strptr(v string) *string { return &v }

func TestMacOSProviderInstanceMapping(t *testing.T) {
	got := toProviderInstance(backend.Instance{
		ProviderID: "mac-1",
		Name:       "mac-1",
		OSName:     "macos",
		OSVersion:  "tahoe",
		OSArch:     "arm64",
		Status:     "running",
	})
	if got.OSType != commonParams.OSType("macos") {
		t.Fatalf("OSType=%q want macos", got.OSType)
	}
	if got.OSArch != commonParams.Arm64 {
		t.Fatalf("OSArch=%q want arm64", got.OSArch)
	}
}

func TestMacOSPickToolsAndBootstrap(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:             "garm-macos-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "https://garm.example.test/api/v1/callbacks",
		MetadataURL:      "https://garm.example.test/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.OSType("macos"),
		OSArch:           commonParams.Arm64,
		Labels:           []string{"self-hosted", "macos", "arm64", "macos-tart"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("linux"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/linux.tar.gz"),
				Filename:       strptr("actions-runner-linux-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
			{
				OS:             strptr("osx"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/osx.tar.gz"),
				Filename:       strptr("actions-runner-osx-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
		},
	}

	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	if tools.GetOS() != "osx" || tools.GetArchitecture() != "arm64" {
		t.Fatalf("picked %s/%s, want osx/arm64", tools.GetOS(), tools.GetArchitecture())
	}

	script, err := renderRunnerBootstrapForBackend(config.BackendTartMacos, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, want := range []string{
		"get_metadata_file \"credentials/runner\"",
		"exec ./run.sh",
		"https://example.invalid/osx.tar.gz",
		"runner configured",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("macOS bootstrap missing %q:\n%s", want, text)
		}
	}
	if strings.Contains(text, "systemctl") || strings.Contains(text, "svc.sh") {
		t.Fatalf("macOS bootstrap must not use Linux/Windows service managers:\n%s", text)
	}
}

func TestLinuxBootstrapCreatesRunnerHomeBeforeDownload(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:             "garm-linux-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "https://garm.example.test/api/v1/callbacks",
		MetadataURL:      "https://garm.example.test/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.Linux,
		OSArch:           commonParams.Arm64,
		Labels:           []string{"self-hosted", "linux", "arm64", "tart-linux-arm"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("linux"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/linux.tar.gz"),
				Filename:       strptr("actions-runner-linux-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
		},
	}

	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	script, err := renderRunnerBootstrapForBackend(config.BackendTartLinuxArm, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, want := range []string{
		"RUN_HOME=\"${RUNNER_HOME}/actions-runner\"",
		`exec sudo -E bash "$0" "$@"`,
		"groupadd \"$RUNNER_GROUP\"",
		"useradd -m -s /bin/bash -g \"$RUNNER_GROUP\" \"$RUNNER_USER\"",
		"get_metadata_file \"credentials/runner\"",
		"call_status '{\"status\":\"idle\",\"message\":\"runner configured\"}'",
		"exec sudo -u \"$RUNNER_USER\" -H ./run.sh",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("linux bootstrap missing foreground-runner behavior %q:\n%s", want, text)
		}
	}
	for _, unwanted := range []string{"systemctl", "svc.sh", "systemd/unit-file"} {
		if strings.Contains(text, unwanted) {
			t.Fatalf("linux bootstrap must not use service manager path %q:\n%s", unwanted, text)
		}
	}
	if strings.Index(text, "get_metadata_file \"credentials/runner\"") > strings.Index(text, "exec sudo -u \"$RUNNER_USER\" -H ./run.sh") {
		t.Fatalf("linux bootstrap starts runner before writing JIT credentials:\n%s", text)
	}
}

func TestLinuxBootstrapForegroundRunnerIsTartOnly(t *testing.T) {
	params := commonParams.BootstrapInstance{
		Name:          "garm-linux-incus-1",
		RepoURL:       "https://github.com/example-org/example-repo",
		CallbackURL:   "https://garm.example.test/api/v1/callbacks",
		MetadataURL:   "https://garm.example.test/api/v1/metadata",
		InstanceToken: "instance-token",
		OSType:        commonParams.Linux,
		OSArch:        commonParams.Arm64,
		Labels:        []string{"self-hosted", "linux", "arm64", "incus-arm"},
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:             strptr("linux"),
				Architecture:   strptr("arm64"),
				DownloadURL:    strptr("https://example.invalid/linux.tar.gz"),
				Filename:       strptr("actions-runner-linux-arm64.tar.gz"),
				SHA256Checksum: strptr(""),
			},
		},
	}

	tools, err := pickTools(params)
	if err != nil {
		t.Fatal(err)
	}
	script, err := renderRunnerBootstrapForBackend(config.BackendIncus, params, tools, params.Name)
	if err != nil {
		t.Fatal(err)
	}
	text := string(script)
	for _, unwanted := range []string{
		"exec sudo -u \"$RUNNER_USER\" -H ./run.sh",
		"get_metadata_file \"credentials/runner\"",
	} {
		if strings.Contains(text, unwanted) {
			t.Fatalf("non-Tart Linux bootstrap must not use Tart foreground path %q:\n%s", unwanted, text)
		}
	}
	for _, want := range []string{
		"sudo ./svc.sh install runner",
		"sudo ./svc.sh start",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("non-Tart Linux bootstrap should use upstream service path %q:\n%s", want, text)
		}
	}
	if !strings.Contains(text, "runner-registration-token") {
		t.Fatalf("non-Tart Linux bootstrap should use upstream cloudconfig path:\n%s", text)
	}
}
