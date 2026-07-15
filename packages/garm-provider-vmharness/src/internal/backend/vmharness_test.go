package backend

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func TestVMHarnessChildEnvDropsSharedNixStoreOnlyForTartGuests(t *testing.T) {
	t.Setenv("MCL_RUNNER_SHARED_NIX_STORE", "/nix/store")

	hasSharedStore := func(env []string) bool {
		for _, entry := range env {
			if entry == "MCL_RUNNER_SHARED_NIX_STORE=/nix/store" {
				return true
			}
		}
		return false
	}

	for _, backendID := range []string{"tart-macos", "tart-linux-arm"} {
		if hasSharedStore(vmHarnessChildEnv(backendID)) {
			t.Fatalf("%s child retained the incomplete shared Nix store", backendID)
		}
	}
	if !hasSharedStore(vmHarnessChildEnv("qemu-windows-arm")) {
		t.Fatal("non-Tart child unexpectedly lost the shared Nix store environment")
	}
}

func TestVMHarnessRunBackendMacOSCreateCommand(t *testing.T) {
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
	oldTartHome, hadTartHome := os.LookupEnv("TART_HOME")
	if err := os.Unsetenv("TART_HOME"); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if hadTartHome {
			_ = os.Setenv("TART_HOME", oldTartHome)
		} else {
			_ = os.Unsetenv("TART_HOME")
		}
	})
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "argv.log")
	envPath := filepath.Join(tmp, "env.log")
	mock := filepath.Join(tmp, "vm-harness")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
		"env > " + shellSingleQuote(envPath) + "\n" +
		"sleep 30\n"
	if err := os.WriteFile(mock, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("XPC_SERVICE_NAME", "org.nixos.garm")
	t.Setenv("VM_HARNESS_TART_STATE_DIR", filepath.Join(tmp, "tart-home"))
	t.Setenv("VM_HARNESS_TEST_KEEP", "yes")
	t.Setenv("MCL_RUNNER_SHARED_NIX_STORE", "/nix/store")

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
	var envData []byte
	for time.Now().Before(deadline) {
		data, err := os.ReadFile(envPath)
		if err == nil && strings.Contains(string(data), "VM_HARNESS_TEST_KEEP=yes") {
			envData = data
			break
		}
		time.Sleep(25 * time.Millisecond)
	}
	if len(envData) == 0 {
		t.Fatal("mock vm-harness did not record its complete environment")
	}
	if strings.Contains(string(envData), "XPC_SERVICE_NAME=") {
		t.Fatalf("vm-harness child env leaked launchd XPC identity:\n%s", string(envData))
	}
	if !strings.Contains(string(envData), "VM_HARNESS_TEST_KEEP=yes") {
		t.Fatalf("vm-harness child env dropped unrelated environment:\n%s", string(envData))
	}
	if !strings.Contains(string(envData), "TART_HOME="+filepath.Join(tmp, "tart-home")) {
		t.Fatalf("vm-harness child env did not derive TART_HOME from VM_HARNESS_TART_STATE_DIR:\n%s", string(envData))
	}
	if strings.Contains(string(envData), "MCL_RUNNER_SHARED_NIX_STORE=") {
		t.Fatalf("Tart vm-harness child retained the host Nix store mount:\n%s", string(envData))
	}
	for _, want := range []string{
		"run\n",
		"--backend\n",
		"tart-macos\n",
		"--guest\n",
		"macos\n",
		"--baseline\n",
		"ghcr.io/cirruslabs/macos-tahoe-base:latest\n",
		"--ephemeral-prefix\n",
		"repro-vm-tart-macos-garm-macos-test\n",
		"--copy-to\n",
		"/tmp/garm-bootstrap.sh\n",
		"--\n",
		"/bin/sh\n",
		"-c\n",
		"chmod +x /tmp/garm-bootstrap.sh && exec /tmp/garm-bootstrap.sh\n",
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
	if st.EphemeralPrefix != "repro-vm-tart-macos-garm-macos-test" {
		t.Fatalf("state ephemeral prefix = %q", st.EphemeralPrefix)
	}
	if data, err := os.ReadFile(st.Bootstrap); err != nil || !strings.Contains(string(data), "echo macos") {
		t.Fatalf("bootstrap not written correctly: err=%v data=%q", err, string(data))
	}
}

func TestVMHarnessRunBackendDarwinAsUserWrapper(t *testing.T) {
	tmp := t.TempDir()
	logPath := filepath.Join(tmp, "launchctl.log")
	cwdPath := filepath.Join(tmp, "launchctl.cwd")
	mockLaunchctl := filepath.Join(tmp, "launchctl")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" > " + shellSingleQuote(logPath) + "\n" +
		"pwd > " + shellSingleQuote(cwdPath) + "\n" +
		"sleep 30\n"
	if err := os.WriteFile(mockLaunchctl, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	uid := os.Getuid()
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", fmt.Sprintf("%d", uid))
	t.Setenv("VM_HARNESS_DARWIN_LAUNCHCTL", mockLaunchctl)

	b := &VMHarnessRunBackend{
		VMHarnessPath: "/nix/store/test-vm-harness/bin/vm-harness",
		BackendID:     "tart-macos",
		GuestOS:       "macos",
		StateDir:      filepath.Join(tmp, "state"),
	}
	inst, err := b.Create(context.Background(), CreateArgs{
		Name:         "garm-macos-asuser-test",
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
		t.Fatal("mock launchctl did not record argv")
	}
	cwd, err := os.ReadFile(cwdPath)
	if err != nil {
		t.Fatal(err)
	}
	wantCWD, err := filepath.EvalSymlinks(filepath.Join(tmp, "state", "instances", "garm-macos-asuser-test", "run"))
	if err != nil {
		t.Fatal(err)
	}
	if got, want := strings.TrimSpace(string(cwd)), wantCWD; got != want {
		t.Fatalf("console-user wrapper cwd = %q, want %q", got, want)
	}
	for _, want := range []string{
		"asuser\n",
		fmt.Sprintf("%d\n", uid),
		"/usr/bin/sudo\n",
		"-E\n",
		"-u\n",
		fmt.Sprintf("#%d\n", uid),
		"--\n",
		"/nix/store/test-vm-harness/bin/vm-harness\n",
		"run\n",
		"tart-macos\n",
		"--timeout-sec\n",
		runnerTimeoutSec + "\n",
	} {
		if !strings.Contains(argv, want) {
			t.Fatalf("launchctl argv missing %q:\n%s", want, argv)
		}
	}
}

func TestVMHarnessRunBackendWindowsCreateCommandWaitsAfterBootstrap(t *testing.T) {
	t.Setenv("VM_HARNESS_DARWIN_ASUSER_UID", "")
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
		BackendID:     "qemu-windows-arm",
		GuestOS:       "windows",
		StateDir:      filepath.Join(tmp, "state"),
	}
	inst, err := b.Create(context.Background(), CreateArgs{
		Name:         "garm-windows-test",
		ControllerID: "controller",
		PoolID:       "pool",
		SourceImage:  filepath.Join(tmp, "golden"),
		OSName:       "windows",
		OSVersion:    "11-arm64",
		OSArch:       "arm64",
		Bootstrap:    []byte("Write-Output 'bootstrap'\n"),
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
		"qemu-windows-arm\n",
		"--guest\n",
		"windows\n",
		"--timeout-sec\n",
		runnerTimeoutSec + "\n",
		"--copy-to\n",
		"garm-bootstrap.ps1:C:\\garm-bootstrap.ps1\n",
		"--\n",
		"powershell.exe\n",
		"-NoProfile\n",
		"-ExecutionPolicy\n",
		"Bypass\n",
		"-Command\n",
		"$bootstrapExitCode = $null",
		"& 'C:\\garm-bootstrap.ps1'",
		"$bootstrapExitCode = $LASTEXITCODE",
		"exit $bootstrapExitCode",
		"Get-Service -Name 'actions.runner.*'",
		"Get-Process -Name 'Runner.Listener'",
		"GitHub Actions runner service/process did not start after bootstrap",
		"Start-Sleep -Seconds 30",
	} {
		if !strings.Contains(argv, want) {
			t.Fatalf("windows argv missing %q:\n%s", want, argv)
		}
	}
	if strings.Contains(argv, "-File\nC:\\garm-bootstrap.ps1\n") {
		t.Fatalf("windows argv still exits immediately after bootstrap:\n%s", argv)
	}
	for _, forbidden := range []string{
		"$ErrorActionPreference = 'Stop'",
		"try {",
		"} catch {",
		"GitHub Actions runner bootstrap failed:",
	} {
		if strings.Contains(argv, forbidden) {
			t.Fatalf("windows argv wraps bootstrap with fatal error handling %q:\n%s", forbidden, argv)
		}
	}
}

func TestVMHarnessRunBackendDeleteCleansTartEphemeralsByPrefix(t *testing.T) {
	tmp := t.TempDir()
	tartLog := filepath.Join(tmp, "tart.log")
	tart := filepath.Join(tmp, "tart")
	script := "#!/bin/sh\n" +
		"printf '%s\\n' \"$@\" >> " + shellSingleQuote(tartLog) + "\n" +
		"if [ \"$1\" = list ]; then\n" +
		"  echo 'Source Name Disk Size SizeOnDisk State'\n" +
		"  echo 'local repro-vm-tart-macos-garm-delete-test-123 50 32 32 running'\n" +
		"  echo 'local repro-vm-tart-macos-other-123 50 32 32 running'\n" +
		"fi\n"
	if err := os.WriteFile(tart, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", tmp+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("VM_HARNESS_TART_STATE_DIR", filepath.Join(tmp, "tart-home"))

	b := &VMHarnessRunBackend{
		VMHarnessPath: "/bin/sleep",
		BackendID:     "tart-macos",
		GuestOS:       "macos",
		StateDir:      filepath.Join(tmp, "state"),
	}
	st := vmhState{
		ProviderID:      "garm-delete-test",
		Name:            "garm-delete-test",
		ControllerID:    "controller",
		PoolID:          "pool",
		OSName:          "macos",
		OSVersion:       "tahoe",
		OSArch:          "arm64",
		PID:             -1,
		EphemeralPrefix: "repro-vm-tart-macos-garm-delete-test",
	}
	if err := b.save(st); err != nil {
		t.Fatal(err)
	}
	if err := b.Delete(context.Background(), st.Name); err != nil {
		t.Fatal(err)
	}
	data, err := os.ReadFile(tartLog)
	if err != nil {
		t.Fatal(err)
	}
	log := string(data)
	if !strings.Contains(log, "stop\nrepro-vm-tart-macos-garm-delete-test-123\n") {
		t.Fatalf("Delete did not stop matching Tart VM:\n%s", log)
	}
	if !strings.Contains(log, "delete\nrepro-vm-tart-macos-garm-delete-test-123\n") {
		t.Fatalf("Delete did not delete matching Tart VM:\n%s", log)
	}
	if strings.Contains(log, "stop\nrepro-vm-tart-macos-other-123") ||
		strings.Contains(log, "delete\nrepro-vm-tart-macos-other-123") {
		t.Fatalf("Delete touched non-matching Tart VM:\n%s", log)
	}
	if _, err := os.Stat(b.instanceDir(st.Name)); !os.IsNotExist(err) {
		t.Fatalf("instance dir still exists after Delete: err=%v", err)
	}
}

func TestVMHarnessRunBackendDoneMarkerOverridesLivePID(t *testing.T) {
	tmp := t.TempDir()
	outputDir := filepath.Join(tmp, "run")
	if err := os.MkdirAll(outputDir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(outputDir, "DONE"), nil, 0o644); err != nil {
		t.Fatal(err)
	}

	b := &VMHarnessRunBackend{StateDir: filepath.Join(tmp, "state")}
	inst := b.toInstance(vmhState{
		ProviderID: "finished-instance",
		Name:       "finished-instance",
		PoolID:     "pool",
		PID:        os.Getpid(), // definitely alive; DONE must still win
		OutputDir:  outputDir,
	})
	if inst.Status != "stopped" {
		t.Fatalf("terminal vm-harness run status = %q, want stopped", inst.Status)
	}
}

func shellSingleQuote(s string) string {
	return "'" + strings.ReplaceAll(s, "'", "'\"'\"'") + "'"
}
