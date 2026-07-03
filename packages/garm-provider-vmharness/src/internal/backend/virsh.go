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
	"encoding/xml"
	"fmt"
	"os/exec"
	"strings"

	garmErrors "github.com/cloudbase/garm-provider-common/errors"
)

// MetadataNamespace is the libvirt <metadata> namespace under which the
// provider stores its stateless identity tags. Recovering these from
// `virsh dumpxml` is how GetInstance/ListInstances recompute state.
const MetadataNamespace = "https://metacraft-labs.com/garm-provider-vmharness/1.0"

// garmMetadata is the XML document embedded under MetadataNamespace inside a
// domain's <metadata>. It carries the full stateless identity so no provider
// side DB is needed.
type garmMetadata struct {
	XMLName      xml.Name `xml:"garm:instance"`
	NS           string   `xml:"xmlns:garm,attr"`
	ControllerID string   `xml:"garm:controller_id"`
	PoolID       string   `xml:"garm:pool_id"`
	Name         string   `xml:"garm:name"`
	OSName       string   `xml:"garm:os_name"`
	OSVersion    string   `xml:"garm:os_version"`
}

// VirshBackend shells to `virsh` to drive libvirt. It is the M1 backend; the
// real per-job clone (M2) and config-drive injection (M3) plug into Create via
// vm-harness, but the stateless lifecycle + metadata tagging live here.
type VirshBackend struct {
	// VirshPath is the virsh binary (or a mock, for the hermetic gate).
	VirshPath string
	// URI is the libvirt connection URI passed as `-c`.
	URI string
	// VMHarnessPath is the vm-harness binary used for clone/inject (M2/M3).
	// Recorded for the seam; unused by the M1 protocol path.
	VMHarnessPath string
}

// run executes virsh with the connection URI and the given args, returning
// stdout. On non-zero exit it returns an error that includes stderr.
func (v *VirshBackend) run(ctx context.Context, args ...string) (string, error) {
	full := append([]string{"-c", v.URI}, args...)
	cmd := exec.CommandContext(ctx, v.VirshPath, full...)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	err := cmd.Run()
	out := stdout.String()
	if err != nil {
		return out, fmt.Errorf("virsh %s: %w: %s", strings.Join(args, " "), err, strings.TrimSpace(stderr.String()))
	}
	return out, nil
}

// isNotFound recognises virsh's "domain not found" errors so the caller can map
// them to GARM's ErrNotFound / exit 30.
func isNotFound(err error) bool {
	if err == nil {
		return false
	}
	msg := strings.ToLower(err.Error())
	return strings.Contains(msg, "failed to get domain") ||
		strings.Contains(msg, "domain not found") ||
		strings.Contains(msg, "no domain with matching") ||
		strings.Contains(msg, "not found")
}

// Create defines a per-job domain carrying the stateless identity metadata.
//
// M1: the domain is defined from a minimal XML skeleton that embeds our
// <metadata> block; the golden clone (M2) and bootstrap injection (M3) are
// recorded on args and left to those milestones. Against a mock virsh this is
// a pure metadata round-trip; against real libvirt it defines a placeholder
// domain shell that M2 replaces with the CoW-clone path.
func (v *VirshBackend) Create(ctx context.Context, args CreateArgs) (Instance, error) {
	meta := garmMetadata{
		NS:           "garm",
		ControllerID: args.ControllerID,
		PoolID:       args.PoolID,
		Name:         args.Name,
		OSName:       args.OSName,
		OSVersion:    args.OSVersion,
	}
	metaXML, err := xml.Marshal(meta)
	if err != nil {
		return Instance{}, fmt.Errorf("marshaling metadata: %w", err)
	}

	domainXML := buildDomainXML(args, string(metaXML))

	// virsh define reads the domain XML from stdin when given "/dev/stdin".
	cmd := exec.CommandContext(ctx, v.VirshPath, "-c", v.URI, "define", "/dev/stdin")
	cmd.Stdin = strings.NewReader(domainXML)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return Instance{}, fmt.Errorf("virsh define %s: %w: %s", args.Name, err, strings.TrimSpace(stderr.String()))
	}

	// Start the domain so GARM sees it as running (best-effort: a real libvirt
	// backend boots the clone here; the mock records the transition).
	if _, err := v.run(ctx, "start", args.Name); err != nil {
		// Not fatal for M1's metadata contract, but surface it: a domain that
		// won't start is an error the caller reports back to GARM.
		return Instance{}, fmt.Errorf("starting domain %s: %w", args.Name, err)
	}

	return v.Get(ctx, args.Name)
}

// Delete destroys + undefines the domain. Idempotent: absence => nil (the
// provider maps a real ErrNotFound to exit 30, but a missing domain during
// delete is treated as already-deleted success).
func (v *VirshBackend) Delete(ctx context.Context, idOrName string) error {
	name, err := v.resolveName(ctx, idOrName)
	if err != nil {
		if isNotFound(err) {
			return nil // already gone
		}
		return err
	}

	// destroy (power off) — ignore "not running" style errors.
	if _, derr := v.run(ctx, "destroy", name); derr != nil && !isNotFound(derr) {
		low := strings.ToLower(derr.Error())
		if !strings.Contains(low, "not running") && !strings.Contains(low, "domain is not running") {
			// destroy of a shut-off domain fails on some libvirt versions; only
			// fail on genuinely unexpected errors.
			if !strings.Contains(low, "not running") {
				// fall through to undefine anyway
			}
		}
	}

	if _, uerr := v.run(ctx, "undefine", name, "--nvram", "--remove-all-storage"); uerr != nil {
		// Retry without the extra flags for backends that reject them, then
		// treat not-found as success.
		if _, uerr2 := v.run(ctx, "undefine", name); uerr2 != nil {
			if isNotFound(uerr2) {
				return nil
			}
			return uerr2
		}
	}
	return nil
}

// resolveName maps a provider_id (UUID) or name to the domain name. If the
// domain does not exist it returns an error for which isNotFound is true.
func (v *VirshBackend) resolveName(ctx context.Context, idOrName string) (string, error) {
	// `virsh domname <uuid>` resolves a UUID to a name; if idOrName is already a
	// name, `virsh dominfo <name>` succeeds. Try dominfo first (works for both
	// name and UUID on real virsh).
	out, err := v.run(ctx, "dominfo", idOrName)
	if err != nil {
		return "", err
	}
	if name := fieldValue(out, "Name:"); name != "" {
		return name, nil
	}
	return idOrName, nil
}

// Get returns the domain's stateless view, recomputed from virsh dumpxml +
// dominfo.
func (v *VirshBackend) Get(ctx context.Context, idOrName string) (Instance, error) {
	info, err := v.run(ctx, "dominfo", idOrName)
	if err != nil {
		if isNotFound(err) {
			return Instance{}, garmErrors.ErrNotFound
		}
		return Instance{}, err
	}
	name := fieldValue(info, "Name:")
	uuid := fieldValue(info, "UUID:")
	state := fieldValue(info, "State:")

	xmlOut, err := v.run(ctx, "dumpxml", idOrName)
	if err != nil {
		return Instance{}, err
	}
	meta := parseMetadata(xmlOut)

	inst := Instance{
		ProviderID:   uuid,
		Name:         name,
		ControllerID: meta.ControllerID,
		PoolID:       meta.PoolID,
		OSName:       meta.OSName,
		OSVersion:    meta.OSVersion,
		Status:       mapState(state),
	}
	if inst.ProviderID == "" {
		inst.ProviderID = name
	}
	if inst.Name == "" {
		inst.Name = meta.Name
	}
	return inst, nil
}

// List returns all domains tagged with poolID (recomputed via dumpxml).
func (v *VirshBackend) List(ctx context.Context, poolID string) ([]Instance, error) {
	return v.listFiltered(ctx, func(m garmMetadata) bool { return m.PoolID == poolID })
}

// ListByController returns all domains tagged with controllerID.
func (v *VirshBackend) ListByController(ctx context.Context, controllerID string) ([]Instance, error) {
	return v.listFiltered(ctx, func(m garmMetadata) bool { return m.ControllerID == controllerID })
}

func (v *VirshBackend) listFiltered(ctx context.Context, keep func(garmMetadata) bool) ([]Instance, error) {
	out, err := v.run(ctx, "list", "--all", "--name")
	if err != nil {
		return nil, err
	}
	var result []Instance
	for _, line := range strings.Split(out, "\n") {
		name := strings.TrimSpace(line)
		if name == "" {
			continue
		}
		inst, err := v.Get(ctx, name)
		if err != nil {
			// A domain that vanished between list and dumpxml is simply skipped.
			continue
		}
		// Reconstruct the metadata predicate from the recovered fields.
		m := garmMetadata{ControllerID: inst.ControllerID, PoolID: inst.PoolID}
		if keep(m) {
			result = append(result, inst)
		}
	}
	return result, nil
}

// Start boots the domain.
func (v *VirshBackend) Start(ctx context.Context, idOrName string) error {
	name, err := v.resolveName(ctx, idOrName)
	if err != nil {
		if isNotFound(err) {
			return garmErrors.ErrNotFound
		}
		return err
	}
	if _, err := v.run(ctx, "start", name); err != nil {
		low := strings.ToLower(err.Error())
		if strings.Contains(low, "already active") || strings.Contains(low, "already running") {
			return nil
		}
		return err
	}
	return nil
}

// Stop shuts the domain down (graceful) or forcibly destroys it when force.
func (v *VirshBackend) Stop(ctx context.Context, idOrName string, force bool) error {
	name, err := v.resolveName(ctx, idOrName)
	if err != nil {
		if isNotFound(err) {
			return garmErrors.ErrNotFound
		}
		return err
	}
	verb := "shutdown"
	if force {
		verb = "destroy"
	}
	if _, err := v.run(ctx, verb, name); err != nil {
		low := strings.ToLower(err.Error())
		if strings.Contains(low, "not running") || strings.Contains(low, "domain is not running") {
			return nil
		}
		return err
	}
	return nil
}

// ---- parsing helpers -------------------------------------------------------

// fieldValue extracts the value after a "Key:" prefix from virsh's aligned
// key/value output (dominfo).
func fieldValue(out, key string) string {
	for _, line := range strings.Split(out, "\n") {
		if strings.HasPrefix(strings.TrimSpace(line), key) {
			return strings.TrimSpace(strings.TrimPrefix(strings.TrimSpace(line), key))
		}
	}
	return ""
}

// mapState maps a libvirt domain state string to the provider status vocabulary.
func mapState(state string) string {
	switch strings.ToLower(strings.TrimSpace(state)) {
	case "running", "idle":
		return "running"
	case "shut off", "shutoff", "shutdown", "crashed", "paused", "pmsuspended":
		return "stopped"
	default:
		return "stopped"
	}
}

// parseMetadata extracts the garm metadata block from a domain's dumpxml.
func parseMetadata(domainXML string) garmMetadata {
	type metaWrap struct {
		Meta struct {
			Inner []byte `xml:",innerxml"`
		} `xml:"metadata"`
	}
	var w metaWrap
	if err := xml.Unmarshal([]byte(domainXML), &w); err != nil {
		return garmMetadata{}
	}
	// The inner XML contains our <garm:instance> element. Decode it tolerantly
	// by field local-name (ignore the namespace prefix).
	return decodeGarmInstance(w.Meta.Inner)
}

// decodeGarmInstance walks the inner metadata XML and pulls the garm fields by
// local element name, tolerating namespace prefixes and other sibling metadata.
func decodeGarmInstance(inner []byte) garmMetadata {
	dec := xml.NewDecoder(bytes.NewReader(inner))
	var m garmMetadata
	var cur string
	for {
		tok, err := dec.Token()
		if err != nil {
			break
		}
		switch t := tok.(type) {
		case xml.StartElement:
			cur = t.Name.Local
		case xml.CharData:
			val := strings.TrimSpace(string(t))
			if val == "" {
				continue
			}
			switch cur {
			case "controller_id":
				m.ControllerID = val
			case "pool_id":
				m.PoolID = val
			case "name":
				m.Name = val
			case "os_name":
				m.OSName = val
			case "os_version":
				m.OSVersion = val
			}
		case xml.EndElement:
			cur = ""
		}
	}
	return m
}
