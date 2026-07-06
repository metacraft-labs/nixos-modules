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
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"os/exec"
	"sort"
	"strings"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// IncusBackend shells to the `incus` CLI to drive per-job Linux SYSTEM
// CONTAINERS — the container-based analog of VirshBackend (IM3). It is the
// same STATELESS shape: the provider holds no lifecycle state; every query
// (GetInstance/ListInstances) is recomputed from the daemon, and the
// GARM identity (controller/pool/name/os) is carried entirely in the
// container's `user.garm.*` config keys (the incus analog of libvirt's
// <metadata> tags), never in a provider-owned store.
//
// Create lifecycle (mirrors the IM2 gate's proven init → inject → start
// order so cloud-init consumes the injected user-data on FIRST boot):
//
//	incus init <image> <name>                     # create, stopped
//	incus config set <name> user.garm.* ...       # stateless identity tags
//	incus config set <name> cloud-init.user-data  # GARM's Linux JIT bootstrap
//	incus config set <name> cloud-init.network-config  # static IPv4 (no DHCP)
//	incus start <name>                            # cloud-init runs the bootstrap
//
// Delete: `incus delete --force <name>` (stops + removes the container and
// its per-container storage volume in one shot — no residue). Idempotent:
// a missing container is success.
type IncusBackend struct {
	// IncusCmd is the incus invocation vector, eg ["incus"] or
	// ["sudo","-n","incus"]. Built from config.IncusPath (whitespace-split)
	// so a session that pre-dates the incus-admin group grant can still run
	// via sudo; production (GARM as root) uses a plain ["incus"].
	IncusCmd []string
	// Bridge is the managed incus bridge the containers attach to (recorded;
	// the default profile provides eth0).
	Bridge string
	// Static-IPv4 injection parameters (incusbr0 DHCP does not lease on this
	// host). CIDR is the subnet in a.b.c.d/nn form; Gateway the default route;
	// RangeStart/RangeEnd bound the allocatable host addresses (inclusive,
	// dotted); Nameservers the resolvers written into the netplan.
	IPv4CIDR    string
	IPv4Gateway string
	RangeStart  string
	RangeEnd    string
	Nameservers []string
	// GpuPassthrough, when true, attaches an NVIDIA GPU to each per-job
	// container before start (`incus config device add <name> gpu gpu` +
	// `incus config set <name> nvidia.runtime=true`). Requires the host's
	// nvidia-container-toolkit (CDI runtime). Backs the `incus-gpu` class.
	GpuPassthrough bool
	// ShareHostNixStore, when true, wires each per-job container into the
	// HOST's shared `/nix/store` as a build-farm participant (the multi-user
	// Nix model — build once, cache-hit for every later guest/host). The share
	// is WRITABLE-BY-DESIGN but SAFE:
	//
	//   * /nix/store is mounted READ-ONLY (the guest sees every prebuilt path
	//     directly — instant cache hits — but its raw filesystem bytes are
	//     immutable from the guest).
	//   * the host nix-daemon socket dir (/nix/var/nix/daemon-socket) is
	//     mounted so the guest can reach the host daemon; all guest WRITES and
	//     BUILDS go THROUGH that daemon (NIX_REMOTE=daemon), which runs on the
	//     host with write access, content-addresses/validates every added path,
	//     and builds derivations in its own sandbox. A guest-built novel path
	//     lands in the shared host store and is a cache hit for later guests.
	//   * the guest's daemon user is UNTRUSTED: incus's default idmap shifts
	//     container root to an unprivileged host uid (base 1_000_000) that is
	//     NOT in nix `trusted-users`, so the daemon reports Trusted: 0. The
	//     guest can build + add content-addressed paths but CANNOT set
	//     substituters/trusted-keys or import unsigned NARs as trusted, and a
	//     malicious path content-addresses to a different hash than anything
	//     production resolves — no cache poisoning.
	//
	// The nix DB itself is served by the daemon (over the socket) — the guest
	// never touches /nix/var/nix/db directly. Residual risk is disk-DoS (a
	// guest filling the store), contained by ephemeral one-job guests + store
	// quotas. Backs PM2 (shared nix store). Default false ⇒ byte-unchanged.
	ShareHostNixStore bool
	// ReprobuildStore, when non-empty, is the HOST reprobuild content-addressed
	// store path mounted READ-WRITE into each per-job container. The CAS is
	// BLAKE3-content-addressed, so writes are self-verifying: a guest ADDS
	// content-addressed entries (which persist to the shared store for later
	// guests) but CANNOT corrupt an existing entry (a tampered blob hashes to a
	// different digest). Backs PM3 (shared reprobuild store).
	ReprobuildStore string
	// ReprobuildStoreGuestPath is the in-guest mount point for ReprobuildStore.
	// Empty ⇒ mirrors the host path.
	ReprobuildStoreGuestPath string
}

// Host paths shared into the per-job container when ShareHostNixStore is set:
// the content-addressed store (READ-ONLY — the guest reads prebuilt paths
// directly) and the nix-daemon socket directory (so the guest routes all
// WRITES/builds through the host daemon, which validates + content-addresses
// every add). The guest never touches the nix DB directly — the daemon owns it.
const (
	hostNixStorePath        = "/nix/store"
	hostNixDaemonSocketPath = "/nix/var/nix/daemon-socket"
)

// incusMetaPrefix namespaces the provider's stateless identity config keys.
const incusMetaPrefix = "user.garm."

// incusContainer is the slice of `incus list --format json` the backend reads.
type incusContainer struct {
	Name   string            `json:"name"`
	Status string            `json:"status"`
	Config map[string]string `json:"config"`
	State  *struct {
		Network map[string]struct {
			Addresses []struct {
				Family  string `json:"family"`
				Address string `json:"address"`
			} `json:"addresses"`
		} `json:"network"`
	} `json:"state"`
}

// run executes incus with the given args, returning combined stdout+stderr.
func (b *IncusBackend) run(ctx context.Context, stdin string, args ...string) (string, error) {
	full := append(append([]string{}, b.IncusCmd[1:]...), args...)
	cmd := exec.CommandContext(ctx, b.IncusCmd[0], full...)
	if stdin != "" {
		cmd.Stdin = strings.NewReader(stdin)
	}
	var out bytes.Buffer
	cmd.Stdout = &out
	cmd.Stderr = &out
	err := cmd.Run()
	if err != nil {
		return out.String(), fmt.Errorf("incus %s: %w: %s",
			strings.Join(args, " "), err, strings.TrimSpace(out.String()))
	}
	return out.String(), nil
}

// listContainers returns the parsed `incus list --format json` view. When
// filter is non-empty it is passed as an incus name filter.
func (b *IncusBackend) listContainers(ctx context.Context, filter string) ([]incusContainer, error) {
	args := []string{"list"}
	if filter != "" {
		args = append(args, filter)
	}
	args = append(args, "--format", "json")
	out, err := b.run(ctx, "", args...)
	if err != nil {
		return nil, err
	}
	var cs []incusContainer
	if uerr := json.Unmarshal([]byte(strings.TrimSpace(out)), &cs); uerr != nil {
		return nil, fmt.Errorf("parsing incus list json: %w", uerr)
	}
	return cs, nil
}

// findExact returns the container with exactly this name, or ErrNotFound.
func (b *IncusBackend) findExact(ctx context.Context, name string) (incusContainer, error) {
	cs, err := b.listContainers(ctx, name)
	if err != nil {
		return incusContainer{}, err
	}
	for _, c := range cs {
		if c.Name == name {
			return c, nil
		}
	}
	return incusContainer{}, garmErrors.ErrNotFound
}

// toInstance maps an incusContainer to the provider's stateless Instance,
// recovering identity from the user.garm.* config keys.
func toInstance(c incusContainer) Instance {
	inst := Instance{
		ProviderID:   c.Name,
		Name:         c.Name,
		ControllerID: c.Config[incusMetaPrefix+"controller_id"],
		PoolID:       c.Config[incusMetaPrefix+"pool_id"],
		OSName:       c.Config[incusMetaPrefix+"os_name"],
		OSVersion:    c.Config[incusMetaPrefix+"os_version"],
		Status:       mapIncusStatus(c.Status),
	}
	if n := c.Config[incusMetaPrefix+"name"]; n != "" {
		inst.Name = n
	}
	if c.State != nil {
		for _, nw := range c.State.Network {
			for _, a := range nw.Addresses {
				if a.Family == "inet" && a.Address != "" {
					inst.Addresses = append(inst.Addresses, a.Address)
				}
			}
		}
	}
	return inst
}

func mapIncusStatus(s string) string {
	switch strings.ToLower(strings.TrimSpace(s)) {
	case "running":
		return "running"
	default:
		return "stopped"
	}
}

// allocateIPv4 picks the lowest free host address in [RangeStart, RangeEnd]
// that is not already assigned to a garm-tagged container (user.garm.ipv4).
// This keeps concurrent per-job containers on distinct static IPs even though
// incusbr0 DHCP does not lease.
func (b *IncusBackend) allocateIPv4(ctx context.Context) (string, error) {
	start := net.ParseIP(b.RangeStart).To4()
	end := net.ParseIP(b.RangeEnd).To4()
	if start == nil || end == nil {
		return "", fmt.Errorf("invalid incus ipv4 range: %q-%q", b.RangeStart, b.RangeEnd)
	}
	cs, err := b.listContainers(ctx, "")
	if err != nil {
		return "", err
	}
	used := map[string]bool{}
	for _, c := range cs {
		if ip := c.Config[incusMetaPrefix+"ipv4"]; ip != "" {
			used[ip] = true
		}
	}
	for ip := ipv4ToUint(start); ip <= ipv4ToUint(end); ip++ {
		cand := uintToIPv4(ip).String()
		if !used[cand] {
			return cand, nil
		}
	}
	return "", fmt.Errorf("no free static IPv4 in range %s-%s", b.RangeStart, b.RangeEnd)
}

func ipv4ToUint(ip net.IP) uint32 {
	ip = ip.To4()
	return uint32(ip[0])<<24 | uint32(ip[1])<<16 | uint32(ip[2])<<8 | uint32(ip[3])
}

func uintToIPv4(v uint32) net.IP {
	return net.IPv4(byte(v>>24), byte(v>>16), byte(v>>8), byte(v))
}

// prefixLen extracts the /nn prefix length from the configured CIDR.
func (b *IncusBackend) prefixLen() int {
	if i := strings.LastIndex(b.IPv4CIDR, "/"); i >= 0 {
		var n int
		fmt.Sscanf(b.IPv4CIDR[i+1:], "%d", &n)
		return n
	}
	return 24
}

// networkConfig renders a cloud-init v2 network-config assigning the static
// IPv4 (cloud-init applies this before user-data runs). Egress works through
// incus's existing NAT; this only replaces the broken DHCP lease.
func (b *IncusBackend) networkConfig(ip string) string {
	var ns strings.Builder
	for i, s := range b.Nameservers {
		if i > 0 {
			ns.WriteString(", ")
		}
		ns.WriteString(s)
	}
	// NOTE: use `to: 0.0.0.0/0` (not `to: default`) — the Debian-12 cloud
	// image's cloud-init/netplan rejects the `default` keyword, which silently
	// fails the WHOLE network-config (the container comes up with no IP).
	return fmt.Sprintf(`version: 2
ethernets:
  eth0:
    dhcp4: false
    addresses: [%s/%d]
    routes:
      - to: 0.0.0.0/0
        via: %s
    nameservers:
      addresses: [%s]
`, ip, b.prefixLen(), b.IPv4Gateway, ns.String())
}

// Create materialises ONE fresh per-job container from the runner image,
// tags it with the stateless identity, injects the GARM JIT bootstrap +
// a static IPv4 via cloud-init, and starts it. Rolls back on any failure.
func (b *IncusBackend) Create(ctx context.Context, args CreateArgs) (Instance, error) {
	if args.SourceImage == "" {
		return Instance{}, fmt.Errorf("incus Create: SourceImage (image alias) is required")
	}
	ip, err := b.allocateIPv4(ctx)
	if err != nil {
		return Instance{}, err
	}

	// 1. create the container (stopped) so config can be injected pre-boot.
	if out, err := b.run(ctx, "", "init", args.SourceImage, args.Name); err != nil {
		return Instance{}, fmt.Errorf("incus init %s %s: %w: %s",
			args.SourceImage, args.Name, err, strings.TrimSpace(out))
	}

	// 2. stateless identity tags (recovered by Get/List).
	meta := map[string]string{
		incusMetaPrefix + "controller_id": args.ControllerID,
		incusMetaPrefix + "pool_id":       args.PoolID,
		incusMetaPrefix + "name":          args.Name,
		incusMetaPrefix + "os_name":       args.OSName,
		incusMetaPrefix + "os_version":    args.OSVersion,
		incusMetaPrefix + "ipv4":          ip,
	}
	// sort keys for deterministic ordering (tests / logs).
	keys := make([]string, 0, len(meta))
	for k := range meta {
		keys = append(keys, k)
	}
	sort.Strings(keys)
	for _, k := range keys {
		if meta[k] == "" {
			continue
		}
		if out, err := b.run(ctx, "", "config", "set", args.Name, k, meta[k]); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config set %s: %w: %s", k, err, strings.TrimSpace(out))
		}
	}

	// 3. static IPv4 (DHCP does not lease on incusbr0).
	if out, err := b.run(ctx, b.networkConfig(ip), "config", "set", args.Name, "cloud-init.network-config", "-"); err != nil {
		_ = b.forceDelete(ctx, args.Name)
		return Instance{}, fmt.Errorf("incus config set cloud-init.network-config: %w: %s", err, strings.TrimSpace(out))
	}

	// 4. the GARM Linux JIT bootstrap as cloud-init user-data (the injection
	//    seam). When absent (hermetic paths) the container still boots clean.
	if len(args.Bootstrap) > 0 {
		if out, err := b.run(ctx, string(args.Bootstrap), "config", "set", args.Name, "cloud-init.user-data", "-"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config set cloud-init.user-data: %w: %s", err, strings.TrimSpace(out))
		}
	}

	// 4b. GPU passthrough (the `incus-gpu` class). Attach an NVIDIA GPU device
	//     and enable the nvidia container runtime so the host's
	//     nvidia-container-toolkit (CDI) exposes the GPU + userspace driver into
	//     the container. Done pre-start (a stopped container) so the device is
	//     present on first boot. `gputype: physical` is Incus's default for a
	//     `gpu` device and covers the whole-GPU passthrough this class needs.
	if b.GpuPassthrough {
		if out, err := b.run(ctx, "", "config", "set", args.Name, "nvidia.runtime=true"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config set nvidia.runtime: %w: %s", err, strings.TrimSpace(out))
		}
		if out, err := b.run(ctx, "", "config", "device", "add", args.Name, "gpu", "gpu"); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, fmt.Errorf("incus config device add gpu: %w: %s", err, strings.TrimSpace(out))
		}
	}

	// 4c. Shared host build stores (PM2/PM3). Wire the per-job container into
	//     the host's shared content-addressed stores so it resolves prebuilt
	//     artifacts INSTANTLY (cache hit) AND persists its own novel builds
	//     back for later guests — the build-farm / multi-user-Nix model. Done
	//     pre-start so the mounts are present on first boot.
	if b.ShareHostNixStore {
		// /nix/store READ-ONLY: the guest sees every prebuilt path directly
		// (instant cache hits) but cannot mutate the store bytes.
		if err := b.addDisk(ctx, args.Name, "nixstore", hostNixStorePath, hostNixStorePath, true); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, err
		}
		// The nix-daemon socket dir READ-WRITE: the guest routes all WRITES +
		// BUILDS through the HOST daemon (NIX_REMOTE=daemon), which validates +
		// content-addresses every add and owns the nix DB. incus's default
		// idmap shifts guest root to an unprivileged, UNTRUSTED host uid, so
		// the daemon reports Trusted: 0 (build/add-CA allowed; set-trust
		// refused). The socket dir must be writable so the guest can connect().
		if err := b.addDisk(ctx, args.Name, "nixdaemon", hostNixDaemonSocketPath, hostNixDaemonSocketPath, false); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, err
		}
	}
	if b.ReprobuildStore != "" {
		guestPath := b.ReprobuildStoreGuestPath
		if guestPath == "" {
			guestPath = b.ReprobuildStore
		}
		// READ-WRITE: the CAS is BLAKE3-content-addressed, so guest-added
		// entries persist to the shared store for later guests and cannot
		// corrupt existing entries (a tampered blob hashes to a new digest).
		if err := b.addDisk(ctx, args.Name, "reprostore", b.ReprobuildStore, guestPath, false); err != nil {
			_ = b.forceDelete(ctx, args.Name)
			return Instance{}, err
		}
	}

	// 5. start — cloud-init consumes the injected user-data on first boot.
	if out, err := b.run(ctx, "", "start", args.Name); err != nil {
		_ = b.forceDelete(ctx, args.Name)
		return Instance{}, fmt.Errorf("incus start %s: %w: %s", args.Name, err, strings.TrimSpace(out))
	}

	return b.Get(ctx, args.Name)
}

// addDisk attaches a host directory to the container as a `disk` device before
// start (PM2/PM3 shared stores). The device name must be unique per container;
// source is the host path, path the in-guest mount point. When readonly is
// true the mount is immutable from the guest (used for /nix/store, which the
// guest reads directly); when false the guest can write (the nix-daemon socket
// dir, and the content-addressed reprobuild CAS — both self-validating so a
// write cannot corrupt existing data).
func (b *IncusBackend) addDisk(ctx context.Context, container, device, source, guestPath string, readonly bool) error {
	dargs := []string{"config", "device", "add", container, device, "disk",
		"source=" + source, "path=" + guestPath}
	if readonly {
		dargs = append(dargs, "readonly=true")
	}
	if out, err := b.run(ctx, "", dargs...); err != nil {
		return fmt.Errorf("incus config device add %s (disk %s->%s ro=%t): %w: %s",
			device, source, guestPath, readonly, err, strings.TrimSpace(out))
	}
	return nil
}

// forceDelete is the idempotent teardown primitive.
func (b *IncusBackend) forceDelete(ctx context.Context, name string) error {
	_, err := b.run(ctx, "", "delete", "--force", name)
	return err
}

// Delete force-removes the container. Idempotent: a missing container is
// treated as already-deleted success.
func (b *IncusBackend) Delete(ctx context.Context, idOrName string) error {
	if _, err := b.findExact(ctx, idOrName); err != nil {
		if err == garmErrors.ErrNotFound {
			return nil
		}
		return err
	}
	if err := b.forceDelete(ctx, idOrName); err != nil {
		// A container that vanished between the check and delete is success.
		if _, gerr := b.findExact(ctx, idOrName); gerr == garmErrors.ErrNotFound {
			return nil
		}
		return err
	}
	return nil
}

// Get returns one container's stateless view. ErrNotFound when absent.
func (b *IncusBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	c, err := b.findExact(ctx, idOrName)
	if err != nil {
		return Instance{}, err
	}
	return toInstance(c), nil
}

// List returns all containers tagged with poolID.
func (b *IncusBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	return b.listFiltered(ctx, func(c incusContainer) bool {
		return c.Config[incusMetaPrefix+"pool_id"] == poolID
	})
}

// ListByController returns all containers tagged with controllerID.
func (b *IncusBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	return b.listFiltered(ctx, func(c incusContainer) bool {
		return c.Config[incusMetaPrefix+"controller_id"] == controllerID
	})
}

func (b *IncusBackend) listFiltered(ctx context.Context, keep func(incusContainer) bool) ([]Instance, error) {
	cs, err := b.listContainers(ctx, "")
	if err != nil {
		return nil, err
	}
	var out []Instance
	for _, c := range cs {
		// Only consider containers we own (a garm identity tag present).
		if c.Config[incusMetaPrefix+"controller_id"] == "" && c.Config[incusMetaPrefix+"pool_id"] == "" {
			continue
		}
		if keep(c) {
			out = append(out, toInstance(c))
		}
	}
	return out, nil
}

// Start boots the container.
func (b *IncusBackend) Start(ctx context.Context, idOrName string) error {
	if _, err := b.findExact(ctx, idOrName); err != nil {
		return err
	}
	out, err := b.run(ctx, "", "start", idOrName)
	if err != nil && !strings.Contains(strings.ToLower(out), "already running") {
		return err
	}
	return nil
}

// Stop shuts the container down (graceful) or force-stops it.
func (b *IncusBackend) Stop(ctx context.Context, idOrName string, force bool) error {
	if _, err := b.findExact(ctx, idOrName); err != nil {
		return err
	}
	args := []string{"stop", idOrName}
	if force {
		args = append(args, "--force")
	}
	out, err := b.run(ctx, "", args...)
	if err != nil && !strings.Contains(strings.ToLower(out), "not running") {
		return err
	}
	return nil
}
