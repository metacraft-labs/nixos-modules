// Copyright 2026 Metacraft Labs
//
//    Licensed under the Apache License, Version 2.0 (the "License"); you may
//    not use this file except in compliance with the License. You may obtain a
//    copy of the License at
//
//         http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
//    WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.

// RemoteBackend is the RB1 remote-target backend: it implements the same
// backend.Backend seam the local backends do, but instead of exec-ing a LOCAL
// vm-harness/virsh/incus it drives a REMOTE `vm-harness serve` daemon over the
// RA1 RPC (bearer-auth HTTP/JSON, protocol v1). Because the daemon runs the
// SAME vm-harness CLI as its worker, each lifecycle op is a forwarded CLI argv
// that is byte-equivalent to the local path — a remote
// `run --ephemeral --backend <target> …` / `ephemeral-destroy …` executes the
// identical backend code on the remote host.
//
// STATELESSNESS. The provider keeps NO local lifecycle state in remote mode.
// The provider_id is GARM's own unique instance name (GARM's DB is the source
// of truth), and host/instance liveness is recovered from the remote daemon's
// authenticated `/v1/info` — never from a local store. This preserves the
// stateless-provider non-negotiable across the network boundary: a fresh
// provider process (GARM spawns one per command) reconstructs everything it
// needs from the config + the remote endpoint.
//
// Per-target LIFECYCLE RECIPES map a create/delete to the concrete vm-harness
// verbs a given remote backend understands. RB1 ships:
//   - "noop"  — the sanctioned test backend (provision / ephemeral-destroy);
//     this is what the hermetic `t_garm_provider_remote` gate exercises so the
//     WIRE CONTRACT (bearer auth, /v1/exec NDJSON streaming, exit codes) is
//     tested for real against a live `vm-harness serve --backend noop`.
//   - "incus" and a generic fallback — the production-shaped ephemeral path
//     (`run --ephemeral --keep` to launch + return, `ephemeral-destroy` to
//     reclaim). Per-target refinements (hyperv's --golden-image, tart's
//     run-backgrounding) and remote runner-bootstrap SHIPPING (the rendered
//     user-data must reach the remote guest — the current serve protocol takes
//     a file path local to the daemon) are RB2 follow-ups; they are called out
//     rather than half-implemented.
package backend

import (
	"context"
	"errors"
	"fmt"
	"os"
	"time"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// RemoteBackend drives a remote `vm-harness serve` daemon. It is constructed
// from the parsed [remote] config by provider.NewWithConfig.
type RemoteBackend struct {
	// Client is the bearer-authenticated RPC client to the remote daemon.
	Client *ServeClient
	// TargetBackend is the vm-harness backend id the remote host drives
	// (forwarded as the remote `--backend`).
	TargetBackend string
	// GuestOS is the reported guest OS for created instances when the
	// golden-image map carries no os_name.
	GuestOS string
}

// remoteRecipe builds the create/delete argv for a specific target backend.
type remoteRecipe struct {
	create func(target string, args CreateArgs) []string
	del    func(target, name string) []string
}

// noopRecipe: the sanctioned test backend. `provision` and `ephemeral-destroy`
// both succeed against `--backend noop` (verified), so a real create+delete
// round-trip exercises the whole wire path without a hypervisor.
var noopRecipe = remoteRecipe{
	create: func(target string, args CreateArgs) []string {
		return []string{"provision", "--backend", target, "--baseline", args.Name, "--log-format", "json"}
	},
	del: func(target, name string) []string {
		return []string{"ephemeral-destroy", "--backend", target, "--baseline", name, "--log-format", "json"}
	},
}

// ephemeralRecipe: the production-shaped per-job path used by incus/libvirt and
// as the generic fallback. `run --ephemeral --keep` launches the per-job guest
// and returns immediately (the guest keeps running the injected runner);
// `ephemeral-destroy` reclaims it. NOTE (RB2): the rendered runner bootstrap is
// NOT yet shipped to the remote guest here — the serve protocol's --user-data
// takes a path local to the daemon; shipping the bytes over the wire is an RB2
// deliverable. RB1's tested path is noop.
var ephemeralRecipe = remoteRecipe{
	create: func(target string, args CreateArgs) []string {
		argv := []string{"run", "--ephemeral", "--backend", target, "--baseline", args.Name}
		if args.SourceImage != "" {
			argv = append(argv, "--base-image", args.SourceImage)
		}
		argv = append(argv, "--keep", "--log-format", "json")
		return argv
	},
	del: func(target, name string) []string {
		return []string{"ephemeral-destroy", "--backend", target, "--baseline", name, "--log-format", "json"}
	},
}

func (b *RemoteBackend) recipe() remoteRecipe {
	switch b.TargetBackend {
	case "noop":
		return noopRecipe
	default:
		// incus, libvirt, and any other target use the ephemeral recipe.
		return ephemeralRecipe
	}
}

// osName resolves the reported OS name for a created instance.
func (b *RemoteBackend) osName(args CreateArgs) string {
	if args.OSName != "" {
		return args.OSName
	}
	if b.GuestOS != "" {
		return b.GuestOS
	}
	return "linux"
}

// Create launches a per-job guest on the remote host over RPC. It is stateless:
// on a successful (exit 0) launch it returns a running Instance whose
// provider_id is GARM's own unique name. No local file is written.
func (b *RemoteBackend) Create(ctx context.Context, args CreateArgs) (Instance, error) {
	if args.Name == "" {
		return Instance{}, fmt.Errorf("remote Create: instance name is required")
	}
	argv := b.recipe().create(b.TargetBackend, args)
	code, err := b.Client.ExecStream(ctx, argv, logToStderr("create "+args.Name))
	if err != nil {
		return Instance{}, fmt.Errorf("remote Create %s: %w", args.Name, err)
	}
	if code != 0 {
		return Instance{}, fmt.Errorf("remote Create %s: worker exit %d", args.Name, code)
	}
	return Instance{
		ProviderID:   args.Name,
		Name:         args.Name,
		ControllerID: args.ControllerID,
		PoolID:       args.PoolID,
		OSName:       b.osName(args),
		OSVersion:    args.OSVersion,
		OSArch:       args.OSArch,
		Status:       "running",
	}, nil
}

// Delete reclaims the per-job guest on the remote host over RPC. It is
// idempotent: a transport/auth failure is surfaced, but a non-zero worker exit
// (the guest is already gone) is treated as success so a repeated Delete of an
// absent instance still reports success — matching the local backends' contract.
func (b *RemoteBackend) Delete(ctx context.Context, idOrName string) error {
	argv := b.recipe().del(b.TargetBackend, idOrName)
	code, err := b.Client.ExecStream(ctx, argv, logToStderr("delete "+idOrName))
	if err != nil {
		// A rejected credential or an unreachable endpoint is a real error.
		var authErr *ServeAuthError
		if errors.As(err, &authErr) {
			return err
		}
		return fmt.Errorf("remote Delete %s: %w", idOrName, err)
	}
	if code != 0 {
		// Idempotent: the ephemeral guest is gone either way. Log and succeed.
		fmt.Fprintf(os.Stderr, "remote Delete %s: teardown worker exit %d (treated as idempotent success)\n", idOrName, code)
	}
	return nil
}

// Get recovers a best-effort view of one instance. The provider holds no local
// state and the RA1 protocol has no per-instance query yet (an enumeration
// endpoint is an RB2/RA6 follow-up), so Get confirms the remote host is
// reachable + the credential is valid via /v1/info and reports the GARM-known
// instance as running. A rejected credential is surfaced; a transport failure
// is surfaced (GARM treats it as transient) rather than mis-reported as absent,
// so a live runner is never spuriously reaped over a blind spot.
func (b *RemoteBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if _, err := b.Client.Info(cctx); err != nil {
		return Instance{}, err
	}
	return Instance{
		ProviderID: idOrName,
		Name:       idOrName,
		OSName:     b.GuestOS,
		Status:     "running",
	}, nil
}

// List cannot enumerate remote instances in RB1 (the RA1 protocol exposes no
// list endpoint; a stateless provider process holds nothing to list). It probes
// the endpoint for auth/liveness and returns an empty set — the honest answer
// under GARM's DB-as-truth model. Fleet-wide remote enumeration is an RB2
// deliverable (a serve-side list verb).
func (b *RemoteBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	return b.listProbe(ctx)
}

// ListByController mirrors List (used by RemoveAllInstances).
func (b *RemoteBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	return b.listProbe(ctx)
}

func (b *RemoteBackend) listProbe(ctx context.Context) ([]Instance, error) {
	cctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	if _, err := b.Client.Info(cctx); err != nil {
		var authErr *ServeAuthError
		if errors.As(err, &authErr) {
			return nil, err
		}
		// Transport error: report empty rather than fail the whole reconcile.
		return nil, nil
	}
	return nil, nil
}

// Start is not meaningful for one-shot ephemeral remote instances; the guest is
// launched by Create and reclaimed by Delete. A guest that has exited cannot be
// restarted — a replacement runner is created instead.
func (b *RemoteBackend) Start(ctx context.Context, idOrName string) error {
	return fmt.Errorf("remote instance %s: ephemeral runners are one-shot; create a replacement", idOrName)
}

// Stop maps to Delete (reclaim the per-job guest).
func (b *RemoteBackend) Stop(ctx context.Context, idOrName string, force bool) error {
	return b.Delete(ctx, idOrName)
}

// logToStderr streams remote worker log lines to the provider's stderr so a
// remote create/delete looks like a local one in GARM's provider logs.
func logToStderr(tag string) func(ExecEvent) {
	return func(ev ExecEvent) {
		switch ev.Kind {
		case "log":
			fmt.Fprintf(os.Stderr, "[remote %s] %s\n", tag, ev.Line)
		case "error":
			fmt.Fprintf(os.Stderr, "[remote %s] error: %s\n", tag, ev.Message)
		}
	}
}

// Ensure RemoteBackend satisfies the Backend seam and ErrNotFound is imported
// for parity with the other backends' idempotency contract.
var _ Backend = (*RemoteBackend)(nil)
var _ = garmErrors.ErrNotFound
