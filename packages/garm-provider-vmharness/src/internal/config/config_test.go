package config

import "testing"

func TestValidateAcceptsQemuWindowsArm(t *testing.T) {
	cfg, err := ParseBytes([]byte(`
backend = "qemu-windows-arm"
vm_harness_path = "/nix/store/test/bin/vm-harness"
state_dir = "/tmp/garm-provider-vmharness"
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
}
