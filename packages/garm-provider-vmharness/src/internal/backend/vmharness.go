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

package backend

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// VMHarnessRunBackend drives vm-harness backends whose lifecycle is already
// one-shot and self-cleaning. It starts `vm-harness run` in the background and
// records only a pid + metadata file under StateDir, keeping the provider
// stateless with respect to GARM's own DB.
type VMHarnessRunBackend struct {
	VMHarnessPath string
	BackendID     string
	GuestOS       string
	StateDir      string
}

type vmhState struct {
	ProviderID      string   `json:"provider_id"`
	Name            string   `json:"name"`
	ControllerID    string   `json:"controller_id"`
	PoolID          string   `json:"pool_id"`
	OSName          string   `json:"os_name"`
	OSVersion       string   `json:"os_version"`
	OSArch          string   `json:"os_arch"`
	PID             int      `json:"pid"`
	OutputDir       string   `json:"output_dir"`
	Bootstrap       string   `json:"bootstrap"`
	EphemeralPrefix string   `json:"ephemeral_prefix,omitempty"`
	Addresses       []string `json:"addresses"`
}

func (b *VMHarnessRunBackend) instanceDir(name string) string {
	return filepath.Join(b.StateDir, "instances", name)
}

func (b *VMHarnessRunBackend) statePath(name string) string {
	return filepath.Join(b.instanceDir(name), "state.json")
}

func (b *VMHarnessRunBackend) tartEphemeralPrefix(name string) string {
	switch b.BackendID {
	case "tart-macos":
		return "repro-vm-tart-macos-" + name
	case "tart-linux-arm":
		return "repro-vm-tart-linux-" + name
	default:
		return ""
	}
}

func (b *VMHarnessRunBackend) load(name string) (vmhState, error) {
	data, err := os.ReadFile(b.statePath(name))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return vmhState{}, garmErrors.ErrNotFound
		}
		return vmhState{}, err
	}
	var st vmhState
	if err := json.Unmarshal(data, &st); err != nil {
		return vmhState{}, err
	}
	return st, nil
}

func (b *VMHarnessRunBackend) save(st vmhState) error {
	if err := os.MkdirAll(b.instanceDir(st.Name), 0o755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(st, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(b.statePath(st.Name), data, 0o644)
}

func processRunning(pid int) bool {
	if pid <= 0 {
		return false
	}
	p, err := os.FindProcess(pid)
	if err != nil {
		return false
	}
	return p.Signal(syscall.Signal(0)) == nil
}

func vmHarnessChildEnv() []string {
	env := os.Environ()
	out := make([]string, 0, len(env))
	hasTartHome := false
	tartStateDir := ""
	for _, entry := range env {
		if strings.HasPrefix(entry, "XPC_SERVICE_NAME=") {
			continue
		}
		if strings.HasPrefix(entry, "TART_HOME=") {
			hasTartHome = true
		}
		if strings.HasPrefix(entry, "VM_HARNESS_TART_STATE_DIR=") {
			tartStateDir = strings.TrimPrefix(entry, "VM_HARNESS_TART_STATE_DIR=")
		}
		out = append(out, entry)
	}
	if !hasTartHome && tartStateDir != "" {
		out = append(out, "TART_HOME="+tartStateDir)
	}
	return out
}

func (b *VMHarnessRunBackend) toInstance(st vmhState) Instance {
	status := "stopped"
	if processRunning(st.PID) {
		status = "running"
	}
	return Instance{
		ProviderID:   st.ProviderID,
		Name:         st.Name,
		ControllerID: st.ControllerID,
		PoolID:       st.PoolID,
		OSName:       st.OSName,
		OSVersion:    st.OSVersion,
		OSArch:       st.OSArch,
		Status:       status,
		Addresses:    st.Addresses,
	}
}

func (b *VMHarnessRunBackend) Create(ctx context.Context, args CreateArgs) (Instance, error) {
	if args.SourceImage == "" {
		return Instance{}, fmt.Errorf("vm-harness Create: SourceImage (baseline/golden) is required")
	}
	dir := b.instanceDir(args.Name)
	outDir := filepath.Join(dir, "run")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		return Instance{}, err
	}

	guestPath := "/tmp/garm-bootstrap.sh"
	bootstrapPath := filepath.Join(dir, "garm-bootstrap.sh")
	argv := []string{"run", "--backend", b.BackendID, "--guest", b.GuestOS, "--baseline", args.SourceImage, "--output-dir", outDir}
	ephemeralPrefix := b.tartEphemeralPrefix(args.Name)
	if ephemeralPrefix != "" {
		argv = append(argv, "--ephemeral-prefix", ephemeralPrefix)
	}
	if strings.EqualFold(args.OSName, "windows") || b.GuestOS == "windows" {
		guestPath = `C:\garm-bootstrap.ps1`
		bootstrapPath = filepath.Join(dir, "garm-bootstrap.ps1")
		argv = append(argv, "--copy-to", bootstrapPath+":"+guestPath, "--", "powershell.exe", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", guestPath)
	} else {
		argv = append(argv, "--copy-to", bootstrapPath+":"+guestPath, "--", "/bin/sh", "-c", "chmod +x "+guestPath+" && exec "+guestPath)
	}
	if err := os.WriteFile(bootstrapPath, args.Bootstrap, 0o755); err != nil {
		return Instance{}, err
	}

	cmdPath := b.VMHarnessPath
	cmdArgs := argv
	if uid := os.Getenv("VM_HARNESS_DARWIN_ASUSER_UID"); uid != "" {
		launchctl := os.Getenv("VM_HARNESS_DARWIN_LAUNCHCTL")
		if launchctl == "" {
			launchctl = "/bin/launchctl"
		}
		cmdPath = launchctl
		cmdArgs = append([]string{"asuser", uid, b.VMHarnessPath}, argv...)
	}
	cmd := exec.Command(cmdPath, cmdArgs...)
	cmd.Env = vmHarnessChildEnv()
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	logFile, err := os.OpenFile(filepath.Join(dir, "vm-harness.log"), os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o644)
	if err != nil {
		return Instance{}, err
	}
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	if err := cmd.Start(); err != nil {
		_ = logFile.Close()
		return Instance{}, err
	}
	_ = logFile.Close()

	st := vmhState{
		ProviderID:      args.Name,
		Name:            args.Name,
		ControllerID:    args.ControllerID,
		PoolID:          args.PoolID,
		OSName:          args.OSName,
		OSVersion:       args.OSVersion,
		OSArch:          args.OSArch,
		PID:             cmd.Process.Pid,
		OutputDir:       outDir,
		Bootstrap:       bootstrapPath,
		EphemeralPrefix: ephemeralPrefix,
	}
	if err := b.save(st); err != nil {
		return Instance{}, err
	}
	if err := cmd.Process.Release(); err != nil {
		return Instance{}, err
	}
	return b.toInstance(st), nil
}

func (b *VMHarnessRunBackend) Delete(ctx context.Context, idOrName string) error {
	st, err := b.load(idOrName)
	if err != nil {
		return nil
	}
	if processRunning(st.PID) {
		_ = syscall.Kill(-st.PID, syscall.SIGTERM)
		if p, err := os.FindProcess(st.PID); err == nil {
			_ = p.Signal(syscall.SIGTERM)
		}
	}
	if st.EphemeralPrefix != "" {
		b.cleanupTartEphemerals(ctx, st.EphemeralPrefix)
	}
	return os.RemoveAll(b.instanceDir(st.Name))
}

func (b *VMHarnessRunBackend) cleanupTartEphemerals(ctx context.Context, prefix string) {
	if prefix == "" {
		return
	}
	cmd := exec.CommandContext(ctx, "tart", "list")
	cmd.Env = vmHarnessChildEnv()
	out, err := cmd.Output()
	if err != nil {
		return
	}
	for _, line := range strings.Split(string(out), "\n") {
		fields := strings.Fields(line)
		if len(fields) < 2 || !strings.EqualFold(fields[0], "local") || !strings.HasPrefix(fields[1], prefix) {
			continue
		}
		stop := exec.CommandContext(ctx, "tart", "stop", fields[1])
		stop.Env = vmHarnessChildEnv()
		_ = stop.Run()
		del := exec.CommandContext(ctx, "tart", "delete", fields[1])
		del.Env = vmHarnessChildEnv()
		_ = del.Run()
	}
}

func (b *VMHarnessRunBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	st, err := b.load(idOrName)
	if err != nil {
		return Instance{}, err
	}
	return b.toInstance(st), nil
}

func (b *VMHarnessRunBackend) listFiltered(keep func(vmhState) bool) ([]Instance, error) {
	root := filepath.Join(b.StateDir, "instances")
	entries, err := os.ReadDir(root)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	var out []Instance
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		st, err := b.load(e.Name())
		if err != nil || !keep(st) {
			continue
		}
		out = append(out, b.toInstance(st))
	}
	return out, nil
}

func (b *VMHarnessRunBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	return b.listFiltered(func(st vmhState) bool { return st.PoolID == poolID })
}

func (b *VMHarnessRunBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	return b.listFiltered(func(st vmhState) bool { return st.ControllerID == controllerID })
}

func (b *VMHarnessRunBackend) Start(ctx context.Context, idOrName string) error {
	st, err := b.load(idOrName)
	if err != nil {
		return err
	}
	if processRunning(st.PID) {
		return nil
	}
	return fmt.Errorf("vm-harness instance %s has exited; create a replacement runner", idOrName)
}

func (b *VMHarnessRunBackend) Stop(ctx context.Context, idOrName string, force bool) error {
	return b.Delete(ctx, idOrName)
}
