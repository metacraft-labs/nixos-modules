package backend

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestVMHarnessRunBackendMacOSCreateCommand(t *testing.T) {
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "argv.log")
	mock := filepath.Join(tmp, "vm-harness")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
		"sleep 30\n"
	if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}

	b := &VMHarnessRunBackend{
		VMHarnessPath: mock,
		BackendID:     "tart-macos",
		GuestOS:       "macos",
		StateDir:      filepath.Join(tmp, "state"),
	}
	inst, err := b.Create(context.Background(), CreateArgs{
		Name:         "garm-macos-test",
		ControllerID: "controller",
		PoolID:       "pool",
		SourceImage:  "ghcr.io/cirruslabs/macos-tahoe-base:latest",
		OSName:       "macos",
		OSVersion:    "tahoe",
		OSArch:       "arm64",
		Bootstrap:    []byte("#!/bin/sh\necho macos\n"),
	})
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		_ = b.Delete(context.Background(), inst.Name)
	}()

	deadline := time.Now().Add(3 * time.Second)
	var argv string
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(logPath)
		if err == nil {
			argv = string(data)
			break
		}
		time.Sleep(50 * time.Millisecond)
	}
	if argv == "" {
		t.Fatal("mock vm-harness did not record argv")
	}
	for _, want := range []string{
		"run\n",
		"--backend\n",
		"tart-macos\n",
		"--guest\n",
		"macos\n",
		"--baseline\n",
		"ghcr.io/cirruslabs/macos-tahoe-base:latest\n",
		"--copy-to\n",
		"/tmp/garm-bootstrap.sh\n",
		"--\n",
		"sh\n",
	} {
		if !strings.Contains(argv, want) {
			t.Fatalf("argv missing %q:\n%s", want, argv)
		}
	}

	st, err := b.load("garm-macos-test")
	if err != nil {
		t.Fatal(err)
	}
	if st.OSName != "macos" || st.OSArch != "arm64" {
		t.Fatalf("state OS metadata = %s/%s, want macos/arm64", st.OSName, st.OSArch)
	}
	if data, err := os.ReadFile(st.Bootstrap); err != nil || !strings.Contains(string(data), "echo macos") {
		t.Fatalf("bootstrap not written correctly: err=%v data=%q", err, string(data))
	}
}

func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
