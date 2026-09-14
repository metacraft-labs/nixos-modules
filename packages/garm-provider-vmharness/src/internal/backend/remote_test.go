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

// Hermetic wire-level tests for the RB1 remote-target backend + serve client.
//
// MOCK POLICY: the ONE fixture here is a minimal in-process HTTP server that
// speaks the RA1 `/v1` contract (bearer auth, `GET /v1/info`, chunked NDJSON
// `POST /v1/exec`). It stands in for a `vm-harness serve` daemon so the Go
// client's wire handling — bearer header, 401 → ServeAuthError, NDJSON event
// decoding, exit-code propagation, argv forwarding — is exercised WITHOUT a
// vm-harness binary or a hypervisor. The end-to-end gate `t_garm_provider_remote`
// (checks/garm-provider-remote.nix) complements this by driving the built
// provider against a REAL `vm-harness serve --backend noop`, so the full wire
// contract is also proven against the genuine daemon. This mock exists solely to
// give a fast, dependency-free unit that pins the client/backend logic.
package backend

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
)

const testToken = "unit-bearer-3f9a2c"

// fakeServe records exec argvs and replies with the RA1 wire contract.
type fakeServe struct {
	execArgv [][]string
	// execUserData records the /v1/exec `userData` field per request (parallel
	// to execArgv) so a test can prove the rendered bootstrap crosses the wire.
	execUserData []string
	exitCode     int
}

func (f *fakeServe) handler() http.Handler {
	mux := http.NewServeMux()
	auth := func(w http.ResponseWriter, r *http.Request) bool {
		if r.Header.Get("Authorization") != "Bearer "+testToken {
			w.WriteHeader(http.StatusUnauthorized)
			_, _ = w.Write([]byte(`{"error":"unauthorized"}`))
			return false
		}
		return true
	}
	mux.HandleFunc("/v1/info", func(w http.ResponseWriter, r *http.Request) {
		if !auth(w, r) {
			return
		}
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"service":"vm-harness-serve","protocol":"1","host":"linux","backends":[{"id":"noop","available":true,"guests":["linux"]}]}`))
	})
	mux.HandleFunc("/v1/exec", func(w http.ResponseWriter, r *http.Request) {
		if !auth(w, r) {
			return
		}
		var req execRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		f.execArgv = append(f.execArgv, req.Argv)
		f.execUserData = append(f.execUserData, req.UserData)
		fl, _ := w.(http.Flusher)
		w.Header().Set("Content-Type", "application/x-ndjson")
		w.WriteHeader(http.StatusOK)
		// Two log lines then a terminal exit — chunked because we flush.
		writeEv := func(v any) {
			b, _ := json.Marshal(v)
			_, _ = fmt.Fprintf(w, "%s\n", b)
			if fl != nil {
				fl.Flush()
			}
		}
		writeEv(map[string]any{"v": "1", "type": "log", "line": "line-a " + strings.Join(req.Argv, " ")})
		writeEv(map[string]any{"v": "1", "type": "log", "line": "line-b"})
		writeEv(map[string]any{"v": "1", "type": "exit", "code": f.exitCode})
	})
	return mux
}

func newFakeBackend(t *testing.T, target string, exitCode int) (*RemoteBackend, *fakeServe, func()) {
	t.Helper()
	fs := &fakeServe{exitCode: exitCode}
	srv := httptest.NewServer(fs.handler())
	endpoint := strings.TrimPrefix(srv.URL, "http://")
	b := &RemoteBackend{
		Client:        NewServeClient(endpoint, testToken, 0),
		TargetBackend: target,
		GuestOS:       "linux",
	}
	return b, fs, srv.Close
}

func TestRemoteCreateDeleteNoop(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	ctx := context.Background()

	inst, err := b.Create(ctx, CreateArgs{Name: "garm-r-1", ControllerID: "ctrl", PoolID: "pool", OSArch: "amd64"})
	if err != nil {
		t.Fatalf("Create: %v", err)
	}
	if inst.ProviderID != "garm-r-1" || inst.Name != "garm-r-1" || inst.Status != "running" {
		t.Fatalf("Create instance: %+v", inst)
	}
	if inst.OSName != "linux" {
		t.Fatalf("OSName=%q want linux", inst.OSName)
	}
	// The noop recipe stays byte-for-byte unchanged and cannot receive Incus
	// capability flags.
	wantCreate := []string{"provision", "--backend", "noop", "--baseline", "garm-r-1", "--log-format", "json"}
	if len(fs.execArgv) != 1 || !reflect.DeepEqual(fs.execArgv[0], wantCreate) {
		t.Fatalf("create argv=%v want exact %v", fs.execArgv, wantCreate)
	}

	if err := b.Delete(ctx, "garm-r-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if len(fs.execArgv) != 2 || fs.execArgv[1][0] != "ephemeral-destroy" {
		t.Fatalf("delete argv=%v want ephemeral-destroy", fs.execArgv)
	}
	wantDelete := []string{"ephemeral-destroy", "--backend", "noop", "--baseline", "garm-r-1", "--log-format", "json"}
	if !reflect.DeepEqual(fs.execArgv[1], wantDelete) {
		t.Fatalf("delete argv=%v want exact %v", fs.execArgv[1], wantDelete)
	}
}

func TestRemoteCreateIncusRecipe(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "incus", 0)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "job-42", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	want := []string{
		"run", "--ephemeral", "--backend", "incus", "--baseline", "job-42",
		"--base-image", "runner-linux", "--keep", "--log-format", "json",
	}
	if !reflect.DeepEqual(fs.execArgv[0], want) {
		t.Fatalf("default incus create argv=%v want byte-for-byte prior argv %v", fs.execArgv[0], want)
	}
}

func TestRemoteCreateIncusCapabilityFlagOrderAndDeleteIsolation(t *testing.T) {
	for _, tc := range []struct {
		name       string
		nesting    bool
		nestedKvm  bool
		capability []string
	}{
		{name: "nesting only", nesting: true, capability: []string{"--incus-security-nesting"}},
		{name: "nested KVM only", nestedKvm: true, capability: []string{"--incus-nested-kvm"}},
		{name: "both in fixed order", nesting: true, nestedKvm: true, capability: []string{"--incus-security-nesting", "--incus-nested-kvm"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			b, fs, closeFn := newFakeBackend(t, "incus", 0)
			defer closeFn()
			b.IncusSecurityNesting = tc.nesting
			b.IncusNestedKvm = tc.nestedKvm

			if _, err := b.Create(context.Background(), CreateArgs{Name: "job-cap"}); err != nil {
				t.Fatalf("Create: %v", err)
			}
			wantCreate := []string{"run", "--ephemeral", "--backend", "incus", "--baseline", "job-cap"}
			wantCreate = append(wantCreate, tc.capability...)
			wantCreate = append(wantCreate, "--keep", "--log-format", "json")
			if !reflect.DeepEqual(fs.execArgv[0], wantCreate) {
				t.Fatalf("create argv=%v want exact %v", fs.execArgv[0], wantCreate)
			}

			if err := b.Delete(context.Background(), "job-cap"); err != nil {
				t.Fatalf("Delete: %v", err)
			}
			wantDelete := []string{"ephemeral-destroy", "--backend", "incus", "--baseline", "job-cap", "--log-format", "json"}
			if !reflect.DeepEqual(fs.execArgv[1], wantDelete) {
				t.Fatalf("delete argv=%v want exact capability-free argv %v", fs.execArgv[1], wantDelete)
			}
		})
	}
}

func TestRemoteNonIncusRecipesNeverReceiveIncusCapabilities(t *testing.T) {
	for _, target := range []string{"noop", "libvirt", "hyperv", "tart-macos"} {
		t.Run(target, func(t *testing.T) {
			b, fs, closeFn := newFakeBackend(t, target, 0)
			defer closeFn()
			b.IncusSecurityNesting = true
			b.IncusNestedKvm = true

			if _, err := b.Create(context.Background(), CreateArgs{Name: "job-other"}); err != nil {
				t.Fatalf("Create: %v", err)
			}
			var want []string
			if target == "noop" {
				want = []string{"provision", "--backend", target, "--baseline", "job-other", "--log-format", "json"}
			} else {
				want = []string{"run", "--ephemeral", "--backend", target, "--baseline", "job-other", "--keep", "--log-format", "json"}
			}
			if !reflect.DeepEqual(fs.execArgv[0], want) {
				t.Fatalf("target %q argv=%v want exact capability-free argv %v", target, fs.execArgv[0], want)
			}
		})
	}
}

func TestRemoteCreateShipsBootstrapAsUserData(t *testing.T) {
	// RB2: the rendered runner bootstrap must cross the wire as /v1/exec
	// `userData` so the daemon can inject it as the guest's cloud-init user-data.
	b, fs, closeFn := newFakeBackend(t, "incus", 0)
	defer closeFn()
	const bootstrap = "#!/bin/bash\n# runner install (JIT token redacted)\n./config.sh --jitconfig XYZ\n"
	if _, err := b.Create(context.Background(), CreateArgs{
		Name:        "job-77",
		SourceImage: "runner-linux",
		Bootstrap:   []byte(bootstrap),
	}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if len(fs.execUserData) != 1 {
		t.Fatalf("expected 1 exec, got %d", len(fs.execUserData))
	}
	if fs.execUserData[0] != bootstrap {
		t.Fatalf("userData over the wire = %q, want the rendered bootstrap %q", fs.execUserData[0], bootstrap)
	}
	// The bootstrap travels alongside the argv, never inside it (the daemon
	// stages it to a file and appends --user-data itself).
	if hasFlag(fs.execArgv[0], "--user-data") {
		t.Fatalf("bootstrap must not be baked into argv: %v", fs.execArgv[0])
	}
}

func TestRemoteCreateWithoutBootstrapSendsNoUserData(t *testing.T) {
	// The noop test recipe (and any create with no rendered tools) sends an
	// empty userData, so the daemon appends no --user-data flag.
	b, fs, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "job-0"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	if len(fs.execUserData) != 1 || fs.execUserData[0] != "" {
		t.Fatalf("expected empty userData, got %q", fs.execUserData)
	}
}

func TestRemoteCreateNonZeroExitFails(t *testing.T) {
	b, _, closeFn := newFakeBackend(t, "noop", 7)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "x"}); err == nil {
		t.Fatal("Create with worker exit 7 should error")
	}
}

func TestRemoteDeleteNonZeroIsIdempotent(t *testing.T) {
	// A non-zero teardown exit (guest already gone) is treated as success.
	b, _, closeFn := newFakeBackend(t, "noop", 5)
	defer closeFn()
	if err := b.Delete(context.Background(), "x"); err != nil {
		t.Fatalf("Delete non-zero exit should be idempotent success, got %v", err)
	}
}

func TestRemoteWrongTokenRejected(t *testing.T) {
	b, _, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	b.Client.Token = "WRONG"
	ctx := context.Background()

	_, err := b.Create(ctx, CreateArgs{Name: "x"})
	if err == nil {
		t.Fatal("Create with wrong token should fail")
	}
	// Delete surfaces the auth error too (does NOT swallow it as idempotent).
	if err := b.Delete(ctx, "x"); err == nil {
		t.Fatal("Delete with wrong token should surface the auth error")
	}
	// Get probes /v1/info and must surface the 401.
	if _, err := b.Get(ctx, "x"); err == nil {
		t.Fatal("Get with wrong token should fail")
	}
	// And it is specifically a ServeAuthError.
	if _, err := b.Client.Info(ctx); err == nil {
		t.Fatal("Info with wrong token should fail")
	} else if _, ok := err.(*ServeAuthError); !ok {
		t.Fatalf("want *ServeAuthError, got %T: %v", err, err)
	}
}

func TestServeClientExecStreamEvents(t *testing.T) {
	fs := &fakeServe{exitCode: 0}
	srv := httptest.NewServer(fs.handler())
	defer srv.Close()
	c := NewServeClient(strings.TrimPrefix(srv.URL, "http://"), testToken, 0)

	var logs []string
	code, err := c.ExecStream(context.Background(), []string{"probe"}, func(ev ExecEvent) {
		if ev.Kind == "log" {
			logs = append(logs, ev.Line)
		}
	})
	if err != nil {
		t.Fatalf("ExecStream: %v", err)
	}
	if code != 0 {
		t.Fatalf("exit=%d want 0", code)
	}
	if len(logs) != 2 || !strings.HasPrefix(logs[0], "line-a") {
		t.Fatalf("streamed logs=%v", logs)
	}
}

func TestGetReportsRunningOnLiveHost(t *testing.T) {
	b, _, closeFn := newFakeBackend(t, "noop", 0)
	defer closeFn()
	inst, err := b.Get(context.Background(), "garm-r-9")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if inst.Name != "garm-r-9" || inst.Status != "running" {
		t.Fatalf("Get instance=%+v", inst)
	}
}

func hasFlag(argv []string, flag string) bool {
	for _, a := range argv {
		if a == flag {
			return true
		}
	}
	return false
}
