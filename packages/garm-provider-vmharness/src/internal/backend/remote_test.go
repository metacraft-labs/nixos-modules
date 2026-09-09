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
	"strings"
	"testing"
)

const testToken = "unit-bearer-3f9a2c"

// fakeServe records exec argvs and replies with the RA1 wire contract.
type fakeServe struct {
	execArgv [][]string
	exitCode int
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
	// The noop recipe forwards a `provision --backend noop` argv.
	if len(fs.execArgv) != 1 || fs.execArgv[0][0] != "provision" {
		t.Fatalf("create argv=%v want provision", fs.execArgv)
	}
	assertContains(t, fs.execArgv[0], "--backend", "noop")
	assertContains(t, fs.execArgv[0], "--baseline", "garm-r-1")

	if err := b.Delete(ctx, "garm-r-1"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if len(fs.execArgv) != 2 || fs.execArgv[1][0] != "ephemeral-destroy" {
		t.Fatalf("delete argv=%v want ephemeral-destroy", fs.execArgv)
	}
}

func TestRemoteCreateIncusRecipe(t *testing.T) {
	b, fs, closeFn := newFakeBackend(t, "incus", 0)
	defer closeFn()
	if _, err := b.Create(context.Background(), CreateArgs{Name: "job-42", SourceImage: "runner-linux"}); err != nil {
		t.Fatalf("Create: %v", err)
	}
	argv := fs.execArgv[0]
	// The production-shaped ephemeral recipe: run --ephemeral --keep.
	if argv[0] != "run" {
		t.Fatalf("incus create argv[0]=%q want run", argv[0])
	}
	assertContains(t, argv, "--backend", "incus")
	assertContains(t, argv, "--base-image", "runner-linux")
	if !hasFlag(argv, "--ephemeral") || !hasFlag(argv, "--keep") {
		t.Fatalf("incus create argv missing --ephemeral/--keep: %v", argv)
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

func assertContains(t *testing.T, argv []string, flag, val string) {
	t.Helper()
	for i := 0; i+1 < len(argv); i++ {
		if argv[i] == flag && argv[i+1] == val {
			return
		}
	}
	t.Fatalf("argv %v missing %s %s", argv, flag, val)
}

func hasFlag(argv []string, flag string) bool {
	for _, a := range argv {
		if a == flag {
			return true
		}
	}
	return false
}
