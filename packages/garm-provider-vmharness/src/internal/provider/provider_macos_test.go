package provider

import (
	"strings"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/backend"
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

	script, err := renderRunnerBootstrap(params, tools, params.Name)
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
