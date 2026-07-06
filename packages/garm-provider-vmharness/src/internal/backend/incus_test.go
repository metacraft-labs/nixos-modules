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
      action="$1"; name="$2"; devname="$3"; devtype="$4"
      d="$STATE/$name"
      [ -d "$d" ] || { echo "Error: Instance '$name' not found" >&2; exit 1; }
      if [ "$action" = "add" ]; then
        printf '%s\t%s\n' "$devname" "$devtype" >> "$d/devices"
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
