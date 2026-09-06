package config

import "testing"

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
