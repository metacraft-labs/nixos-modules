package config

import (
	"os"
	"testing"
)

func TestValidateAcceptsQemuWindowsArm(t *testing.T) {
	cfg, err := ParseBytes([]byte(`
backend = "qemu-windows-arm"
vm_harness_path = "/nix/store/test/bin/vm-harness"
state_dir = "/tmp/garm-provider-vmharness"
guest_metadata_url = "http://10.0.2.2:9997/api/v1/metadata"
guest_callback_url = "http://10.0.2.2:9997/api/v1/callbacks"
`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Backend != BackendQemuWindowsArm {
		t.Fatalf("Backend=%q want %q", cfg.Backend, BackendQemuWindowsArm)
	}
	if cfg.VMHarnessPath != "/nix/store/test/bin/vm-harness" {
		t.Fatalf("VMHarnessPath=%q", cfg.VMHarnessPath)
	}
	if cfg.GuestMetadataURL != "http://10.0.2.2:9997/api/v1/metadata" {
		t.Fatalf("GuestMetadataURL=%q", cfg.GuestMetadataURL)
	}
	if cfg.GuestCallbackURL != "http://10.0.2.2:9997/api/v1/callbacks" {
		t.Fatalf("GuestCallbackURL=%q", cfg.GuestCallbackURL)
	}
}

// TestIncusLimitsCPUParsesAndDefaultsEmpty pins the CIR-M1 CPU-cap key at the
// CONFIG boundary — the TOML the NixOS module renders is the only contract
// between `services.garm.providers.<n>.incusLimitsCpu` and the provider.
//
// The default arm is the load-bearing half: an incus provider config that does
// NOT carry the key must leave IncusLimitsCPU empty, because the backend keys
// "apply no cap at all" off exactly that emptiness. If a default ever leaked in
// here, every live runner would silently acquire a cap nobody asked for.
func TestIncusLimitsCPUParsesAndDefaultsEmpty(t *testing.T) {
	base := `
backend = "incus"
incus_path = "/nix/store/test/bin/incus"
incus_ipv4_cidr = "10.157.159.0/24"
incus_ipv4_gateway = "10.157.159.1"
`
	withKey, err := ParseBytes([]byte(base + "incus_limits_cpu = \"8\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if withKey.IncusLimitsCPU != "8" {
		t.Fatalf("IncusLimitsCPU=%q want %q", withKey.IncusLimitsCPU, "8")
	}

	withoutKey, err := ParseBytes([]byte(base))
	if err != nil {
		t.Fatal(err)
	}
	if withoutKey.IncusLimitsCPU != "" {
		t.Fatalf("IncusLimitsCPU=%q want empty when the key is absent; a non-empty default would cap every existing runner", withoutKey.IncusLimitsCPU)
	}

	// An explicit CPU SET must survive verbatim: incus accepts "0-7"/"0,2,4"
	// as well as a count, and the provider passes the value through unparsed.
	set, err := ParseBytes([]byte(base + "incus_limits_cpu = \"0-7\"\n"))
	if err != nil {
		t.Fatal(err)
	}
	if set.IncusLimitsCPU != "0-7" {
		t.Fatalf("IncusLimitsCPU=%q want %q", set.IncusLimitsCPU, "0-7")
	}
}

// TestValidateRemoteBackend covers RB1 remote-target parsing/validation: a
// well-formed [remote] section is accepted with its defaults, and each missing
// requirement (endpoint / target_backend / token) is rejected at parse time
// rather than deferred to the first CreateInstance.
func TestValidateRemoteBackend(t *testing.T) {
	t.Setenv(DefaultAuthTokenEnv, "")

	cfg, err := ParseBytes([]byte(`
backend = "remote"
[remote]
endpoint = "100.72.0.5:8873"
target_backend = "incus"
auth_token_file = "/run/creds/vmh"
`))
	if err != nil {
		t.Fatalf("well-formed remote config rejected: %v", err)
	}
	if cfg.Backend != BackendRemote {
		t.Fatalf("Backend=%q want %q", cfg.Backend, BackendRemote)
	}
	if cfg.Remote == nil || cfg.Remote.Endpoint != "100.72.0.5:8873" {
		t.Fatalf("Remote endpoint not parsed: %+v", cfg.Remote)
	}
	if cfg.Remote.TargetBackend != "incus" {
		t.Fatalf("TargetBackend=%q want incus", cfg.Remote.TargetBackend)
	}
	// Defaults applied.
	if cfg.Remote.AuthTokenEnv != DefaultAuthTokenEnv {
		t.Fatalf("AuthTokenEnv default=%q want %q", cfg.Remote.AuthTokenEnv, DefaultAuthTokenEnv)
	}
	if cfg.Remote.GuestOS != "linux" {
		t.Fatalf("GuestOS default=%q want linux", cfg.Remote.GuestOS)
	}

	// Missing [remote] entirely.
	if _, err := ParseBytes([]byte(`backend = "remote"`)); err == nil {
		t.Fatal("remote backend without [remote] section should fail")
	}
	// Missing endpoint.
	if _, err := ParseBytes([]byte(`
backend = "remote"
[remote]
target_backend = "incus"
auth_token = "t"
`)); err == nil {
		t.Fatal("remote backend without endpoint should fail")
	}
	// Non host:port endpoint.
	if _, err := ParseBytes([]byte(`
backend = "remote"
[remote]
endpoint = "notaddr"
target_backend = "incus"
auth_token = "t"
`)); err == nil {
		t.Fatal("remote endpoint without ':' should fail")
	}
	// No token source at all (and env empty).
	if _, err := ParseBytes([]byte(`
backend = "remote"
[remote]
endpoint = "h:1"
target_backend = "incus"
`)); err == nil {
		t.Fatal("remote backend without any token source should fail")
	}
}

// TestRemoteTargetBackendDefault checks target_backend defaults to incus when
// omitted (the Phase-B first target) while still requiring an endpoint + token.
func TestRemoteTargetBackendDefault(t *testing.T) {
	cfg, err := ParseBytes([]byte(`
backend = "remote"
[remote]
endpoint = "h:1"
auth_token = "t"
`))
	if err != nil {
		t.Fatal(err)
	}
	if cfg.Remote.TargetBackend != string(BackendIncus) {
		t.Fatalf("TargetBackend default=%q want %q", cfg.Remote.TargetBackend, BackendIncus)
	}
}

// TestResolveToken exercises the token resolution priority: inline > file > env.
func TestResolveToken(t *testing.T) {
	// Inline wins.
	r := &RemoteConfig{AuthToken: "inline"}
	if got, err := r.ResolveToken(); err != nil || got != "inline" {
		t.Fatalf("inline token: got %q err %v", got, err)
	}
	// File next.
	f := t.TempDir() + "/tok"
	if err := os.WriteFile(f, []byte("  file-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	r = &RemoteConfig{AuthTokenFile: f}
	if got, err := r.ResolveToken(); err != nil || got != "file-token" {
		t.Fatalf("file token: got %q err %v", got, err)
	}
	// Env last (custom var name).
	t.Setenv("MY_SERVE_TOKEN", "env-token")
	r = &RemoteConfig{AuthTokenEnv: "MY_SERVE_TOKEN"}
	if got, err := r.ResolveToken(); err != nil || got != "env-token" {
		t.Fatalf("env token: got %q err %v", got, err)
	}
	// None → error.
	t.Setenv(DefaultAuthTokenEnv, "")
	r = &RemoteConfig{}
	if _, err := r.ResolveToken(); err == nil {
		t.Fatal("no token source should error")
	}
}
