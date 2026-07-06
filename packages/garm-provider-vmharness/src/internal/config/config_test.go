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
