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

package backend

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"testing"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// mockIncusScript is a self-contained POSIX-sh emulation of the subset of the
// `incus` CLI the IncusBackend drives (init / config set [from stdin] / start /
// stop / delete --force / list [filter] --format json). It persists container
// state + the user.garm.* config keys under $MOCK_INCUS_STATE so the STATELESS
// provider (which never persists anything itself) has a real backend to
// recompute from — the same idea as the mock virsh, but for containers. It
// emits JSON that matches `incus list --format json` closely enough for the
// backend's parser (name / status / config / state.network eth0 inet address).
const mockIncusScript = `#!/bin/sh
set -eu
STATE="${MOCK_INCUS_STATE:?MOCK_INCUS_STATE unset}"
mkdir -p "$STATE"

cmd="${1:-}"; shift || true

case "$cmd" in
  init)
    # init <image> <name>
    image="$1"; name="$2"
    d="$STATE/$name"
    if [ -d "$d" ]; then echo "Error: Instance '$name' already exists" >&2; exit 1; fi
    mkdir -p "$d"
    echo "$image" > "$d/image"
    echo "Stopped" > "$d/status"
    : > "$d/config"
    ;;
  config)
    sub="$1"; shift
    if [ "$sub" = "device" ]; then
      # config device add <name> <devname> <devtype> [k=v ...]
      action="$1"; name="$2"; devname="$3"; devtype="$4"; shift 4 || true
      d="$STATE/$name"
      [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
      if [ "$action" = "add" ]; then
        printf '%s\t%s\t%s\n' "$devname" "$devtype" "$*" >> "$d/devices"
      fi
    else
      # config set <name> <key> <value|->   OR   config set <name> <key=val>
      name="$1"; key="$2"; val="${3:-}"
      d="$STATE/$name"
      [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
      if [ "$val" = "-" ]; then
        cat > "$d/cfgfile.$(echo "$key" | tr '/.' '__')"
      else
        case "$key" in
          *=*) v="${key#*=}"; k="${key%%=*}" ;;
          *)   k="$key"; v="$val" ;;
        esac
        # keep only the newest value per key
        grep -v "^$k	" "$d/config" > "$d/config.tmp" 2>/dev/null || true
        mv "$d/config.tmp" "$d/config" 2>/dev/null || true
        printf '%s\t%s\n' "$k" "$v" >> "$d/config"
      fi
    fi
    ;;
  start)
    name="$1"; d="$STATE/$name"
    [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
    echo "Running" > "$d/status"
    ;;
  stop)
    name="$1"; d="$STATE/$name"
    [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
    echo "Stopped" > "$d/status"
    ;;
  delete)
    # delete --force <name>
    name="$2"; d="$STATE/$name"
    [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
    rm -rf "$d"
    ;;
  list)
    # list [filter] --format json
    filter=""
    if [ "${1:-}" != "--format" ]; then filter="$1"; shift; fi
    printf '['
    first=1
    for d in "$STATE"/*/; do
      [ -d "$d" ] || continue
      n=$(basename "$d")
      if [ -n "$filter" ] && [ "$n" != "$filter" ]; then continue; fi
      st=$(cat "$d/status" 2>/dev/null || echo Stopped)
      [ "$first" = 1 ] || printf ','
      first=0
      printf '{"name":"%s","status":"%s","config":{' "$n" "$st"
      ip=""
      cfirst=1
      while IFS='	' read -r k v; do
        [ -n "$k" ] || continue
        [ "$cfirst" = 1 ] || printf ','
        cfirst=0
        printf '"%s":"%s"' "$k" "$v"
        if [ "$k" = "user.garm.ipv4" ]; then ip="$v"; fi
      done < "$d/config"
      printf '}'
      if [ -n "$ip" ]; then
        printf ',"state":{"network":{"eth0":{"addresses":[{"family":"inet","address":"%s"}]}}}' "$ip"
      else
        printf ',"state":null'
      fi
      printf '}'
    done
    printf ']'
    ;;
  *)
    echo "mock incus: unsupported cmd '$cmd'" >&2; exit 1;;
esac
`

func writeMockIncus(t *testing.T) (cmd []string, stateDir string) {
	t.Helper()
	dir := t.TempDir()
	script := filepath.Join(dir, "incus")
	if err := os.WriteFile(script, []byte(mockIncusScript), 0o755); err != nil {
		t.Fatalf("write mock incus: %v", err)
	}
	stateDir = filepath.Join(dir, "state")
	t.Setenv("MOCK_INCUS_STATE", stateDir)
	return []string{script}, stateDir
}

func newTestIncusBackend(cmd []string) *IncusBackend {
	return &IncusBackend{
		IncusCmd:    cmd,
		Bridge:      "incusbr0",
		IPv4CIDR:    "10.0.100.0/24",
		IPv4Gateway: "10.0.100.1",
		RangeStart:  "10.0.100.200",
		RangeEnd:    "10.0.100.250",
		Nameservers: []string{"1.1.1.1", "8.8.8.8"},
	}
}

func TestIncusCreateGetDeleteLifecycle(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	ctx := context.Background()

	inst, err := b.Create(ctx, CreateArgs{
		Name:         "garm-linux-1",
		ControllerID: "ctrl-A",
		PoolID:       "pool-1",
		SourceImage:  "runner-linux",
		OSName:       "linux",
		OSVersion:    "debian12",
		Bootstrap:    []byte("#!/bin/bash\necho hi\n"),
	})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if inst.Name != "garm-linux-1" || inst.PoolID != "pool-1" || inst.ControllerID != "ctrl-A" {
		t.Fatalf("identity not tagged/recovered: %+v", inst)
	}
	if inst.OSName != "linux" {
		t.Fatalf("os_name not recovered: %+v", inst)
	}
	if inst.Status != "running" {
		t.Fatalf("expected running, got %q", inst.Status)
	}
	if len(inst.Addresses) != 1 || inst.Addresses[0] != "10.0.100.200" {
		t.Fatalf("expected static IP 10.0.100.200, got %v", inst.Addresses)
	}

	got, err := b.Get(ctx, "garm-linux-1")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if got.Name != inst.Name {
		t.Fatalf("Get mismatch: %+v", got)
	}

	if err := b.Delete(ctx, "garm-linux-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, err := b.Get(ctx, "garm-linux-1"); err != garmErrors.ErrNotFound {
		t.Fatalf("expected ErrNotFound after delete, got %v", err)
	}
	// idempotent: deleting a missing container is success.
	if err := b.Delete(ctx, "garm-linux-1"); err != nil {
		t.Fatalf("second Delete not idempotent: %v", err)
	}
}

// TestIncusGpuPassthroughAttachesGpuDevice proves the `incus-gpu` class path:
// with GpuPassthrough set, Create attaches a `gpu` device and sets
// nvidia.runtime=true on the container BEFORE start. Without it, neither is
// present (the plain `incus` class must not touch the GPU).
func TestIncusGpuPassthroughAttachesGpuDevice(t *testing.T) {
	cmd, stateDir := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	b.GpuPassthrough = true
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{
		Name:        "garm-gpu-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (gpu): %v", err)
	}

	devices, err := os.ReadFile(filepath.Join(stateDir, "garm-gpu-1", "devices"))
	if err != nil {
		t.Fatalf("expected a gpu device to be added, but no devices file: %v", err)
	}
	if !strings.Contains(string(devices), "gpu\tgpu") {
		t.Fatalf("expected a `gpu` device of type `gpu`, got: %q", string(devices))
	}

	config, err := os.ReadFile(filepath.Join(stateDir, "garm-gpu-1", "config"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	if !strings.Contains(string(config), "nvidia.runtime\ttrue") {
		t.Fatalf("expected nvidia.runtime=true, got config: %q", string(config))
	}

	// The plain (non-GPU) backend must NOT attach a GPU or set nvidia.runtime.
	plain := newTestIncusBackend(cmd)
	if _, err := plain.Create(ctx, CreateArgs{
		Name:        "garm-plain-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (plain): %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "garm-plain-1", "devices")); err == nil {
		t.Fatalf("plain incus class must not attach any device")
	}
}

// TestIncusSecurityNestingEnablesNesting proves the HR1 nested-Docker path:
// with SecurityNesting set, Create sets `security.nesting=true` plus the two
// fuse-overlayfs syscall intercepts (mknod + setxattr) on the container BEFORE
// start. Without it, none are present (the plain `incus` class stays
// byte-unchanged — the live runners are untouched).
func TestIncusSecurityNestingEnablesNesting(t *testing.T) {
	cmd, stateDir := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	b.SecurityNesting = true
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{
		Name:        "garm-nest-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (nesting): %v", err)
	}

	config, err := os.ReadFile(filepath.Join(stateDir, "garm-nest-1", "config"))
	if err != nil {
		t.Fatalf("read config: %v", err)
	}
	cfg := string(config)
	for _, want := range []string{
		"security.nesting\ttrue",
		"security.syscalls.intercept.mknod\ttrue",
		"security.syscalls.intercept.setxattr\ttrue",
	} {
		if !strings.Contains(cfg, want) {
			t.Fatalf("expected config %q with nesting on, got config:\n%s", want, cfg)
		}
	}

	// The plain (default-OFF) backend must NOT set any nesting/intercept key:
	// the existing live runners stay byte-unchanged until the toggle is enabled.
	plain := newTestIncusBackend(cmd)
	if _, err := plain.Create(ctx, CreateArgs{
		Name:        "garm-nest-plain",
		SourceImage: "runner-linux",
	}); err != nil {
		t.Fatalf("Create (plain): %v", err)
	}
	pcfg, err := os.ReadFile(filepath.Join(stateDir, "garm-nest-plain", "config"))
	if err != nil {
		t.Fatalf("read plain config: %v", err)
	}
	if strings.Contains(string(pcfg), "security.nesting") ||
		strings.Contains(string(pcfg), "security.syscalls.intercept") {
		t.Fatalf("plain incus class must not set any nesting/intercept key (default OFF), got:\n%s", string(pcfg))
	}
}

// TestIncusSharedStoresAttachStoreDisks proves the PM2/PM3 shared-store path
// (writable-by-design, safe): with ShareHostNixStore + ReprobuildStore set,
// Create attaches, before start, the host `/nix/store` READ-ONLY (the guest
// reads prebuilt paths directly), the host nix-daemon socket dir READ-WRITE
// (so guest builds/writes route through the host daemon and persist to the
// shared store), and the reprobuild CAS READ-WRITE (self-verifying content-
// addressed writes). Without the toggles, no store device is attached (the
// plain `incus` class is byte-unchanged).
func TestIncusSharedStoresAttachStoreDisks(t *testing.T) {
	cmd, stateDir := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	b.ShareHostNixStore = true
	b.ReprobuildStore = "/var/lib/reprobuild/shared-store"
	b.ReprobuildStoreGuestPath = "/srv/repro-store"
	ctx := context.Background()

	if _, err := b.Create(ctx, CreateArgs{
		Name:        "garm-store-1",
		SourceImage: "runner-linux",
		OSName:      "linux",
		OSVersion:   "debian12",
	}); err != nil {
		t.Fatalf("Create (shared stores): %v", err)
	}

	devices, err := os.ReadFile(filepath.Join(stateDir, "garm-store-1", "devices"))
	if err != nil {
		t.Fatalf("expected store disk devices to be added, but no devices file: %v", err)
	}
	dev := string(devices)
	// /nix/store READ-ONLY; the nix-daemon socket dir READ-WRITE (no
	// readonly=true — the guest must connect() through it); reprobuild CAS
	// READ-WRITE (self-verifying content-addressed writes persist).
	for _, want := range []string{
		"nixstore\tdisk\tsource=/nix/store path=/nix/store readonly=true",
		"nixdaemon\tdisk\tsource=/nix/var/nix/daemon-socket path=/nix/var/nix/daemon-socket",
		"reprostore\tdisk\tsource=/var/lib/reprobuild/shared-store path=/srv/repro-store",
	} {
		if !strings.Contains(dev, want) {
			t.Fatalf("expected device line %q, got devices:\n%s", want, dev)
		}
	}
	// /nix/store MUST be read-only (raw store bytes immutable from the guest —
	// all mutation goes through the validating daemon).
	for _, line := range strings.Split(strings.TrimSpace(dev), "\n") {
		if strings.HasPrefix(line, "nixstore\tdisk\t") && !strings.Contains(line, "readonly=true") {
			t.Fatalf("nixstore share must be read-only, got: %q", line)
		}
	}
	// The nix-daemon socket + reprobuild CAS MUST be writable (NOT readonly) so
	// guest builds/adds can flow through the daemon / persist to the CAS.
	for _, dname := range []string{"nixdaemon", "reprostore"} {
		for _, line := range strings.Split(strings.TrimSpace(dev), "\n") {
			if strings.HasPrefix(line, dname+"\tdisk\t") && strings.Contains(line, "readonly=true") {
				t.Fatalf("%s share must be read-write (writable-by-design), got: %q", dname, line)
			}
		}
	}

	// Reprobuild guest path defaults to the host path when unset.
	b2 := newTestIncusBackend(cmd)
	b2.ReprobuildStore = "/host/repro"
	if _, err := b2.Create(ctx, CreateArgs{Name: "garm-store-2", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create (repro default guest path): %v", err)
	}
	d2, _ := os.ReadFile(filepath.Join(stateDir, "garm-store-2", "devices"))
	if !strings.Contains(string(d2), "reprostore\tdisk\tsource=/host/repro path=/host/repro") {
		t.Fatalf("expected reprostore to mirror host path when guest path unset, got:\n%s", string(d2))
	}

	// The plain (default-OFF) backend must NOT attach any store device: the
	// existing live runners stay byte-unchanged until the toggle is enabled.
	plain := newTestIncusBackend(cmd)
	if _, err := plain.Create(ctx, CreateArgs{Name: "garm-plain-store", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create (plain): %v", err)
	}
	if _, err := os.Stat(filepath.Join(stateDir, "garm-plain-store", "devices")); err == nil {
		t.Fatalf("plain incus class must not attach any store device (default OFF)")
	}
}

func TestIncusDistinctIPAllocationAndListFilter(t *testing.T) {
	cmd, _ := writeMockIncus(t)
	b := newTestIncusBackend(cmd)
	ctx := context.Background()

	for _, n := range []string{"garm-a", "garm-b"} {
		if _, err := b.Create(ctx, CreateArgs{
			Name: n, ControllerID: "ctrl-A", PoolID: "pool-1",
			SourceImage: "runner-linux", OSName: "linux",
		}); err != nil {
			t.Fatalf("Create %s: %v", n, err)
		}
	}
	// A container in a different pool + controller must not leak into pool-1.
	if _, err := b.Create(ctx, CreateArgs{
		Name: "garm-c", ControllerID: "ctrl-B", PoolID: "pool-2",
		SourceImage: "runner-linux", OSName: "linux",
	}); err != nil {
		t.Fatalf("Create garm-c: %v", err)
	}

	a, _ := b.Get(ctx, "garm-a")
	bb, _ := b.Get(ctx, "garm-b")
	if len(a.Addresses) == 0 || len(bb.Addresses) == 0 || a.Addresses[0] == bb.Addresses[0] {
		t.Fatalf("expected distinct static IPs, got %v and %v", a.Addresses, bb.Addresses)
	}
	if a.Addresses[0] != "10.0.100.200" || bb.Addresses[0] != "10.0.100.201" {
		t.Fatalf("expected sequential lowest-free IPs, got %v %v", a.Addresses, bb.Addresses)
	}

	pool1, err := b.List(ctx, "pool-1")
	if err != nil {
		t.Fatalf("List: %v", err)
	}
	if len(pool1) != 2 {
		t.Fatalf("expected 2 in pool-1, got %d", len(pool1))
	}
	ctrlB, err := b.ListByController(ctx, "ctrl-B")
	if err != nil {
		t.Fatalf("ListByController: %v", err)
	}
	if len(ctrlB) != 1 || ctrlB[0].Name != "garm-c" {
		t.Fatalf("expected only garm-c for ctrl-B, got %+v", ctrlB)
	}
}

func TestIncusNetworkConfigRendersStaticIP(t *testing.T) {
	b := newTestIncusBackend([]string{"incus"})
	nc := b.networkConfig("10.0.100.207")
	for _, want := range []string{
		"dhcp4: false",
		"addresses: [10.0.100.207/24]",
		"to: 0.0.0.0/0",
		"via: 10.0.100.1",
		"addresses: [1.1.1.1, 8.8.8.8]",
	} {
		if !strings.Contains(nc, want) {
			t.Fatalf("network-config missing %q:\n%s", want, nc)
		}
	}
}
