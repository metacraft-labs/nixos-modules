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

package provider

// configJSONSchema is the JSON schema for the provider config.toml (returned by
// the GetConfigJSONSchema command). It describes the vm-harness/libvirt backend
// selection, the golden-image map, the libvirt URI, and the network.
const configJSONSchema = `{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "garm-provider-vmharness config",
  "type": "object",
  "properties": {
    "backend": {
      "type": "string",
      "enum": ["libvirt"],
      "description": "VM management backend. Only 'libvirt' is supported."
    },
    "virsh_path": {
      "type": "string",
      "description": "Path to the virsh binary the provider shells to."
    },
    "vm_harness_path": {
      "type": "string",
      "description": "Path to the vm-harness binary used for per-job clone (M2) and config-drive injection (M3)."
    },
    "libvirt_uri": {
      "type": "string",
      "description": "libvirt connection URI, e.g. qemu:///system."
    },
    "network": {
      "type": "string",
      "description": "libvirt network the per-job domains attach to."
    },
    "images": {
      "type": "object",
      "description": "Map of pool image identifier to a golden source.",
      "additionalProperties": {
        "type": "object",
        "properties": {
          "source_image": {
            "type": "string",
            "description": "Golden qcow2/volume the per-job domain is cloned from."
          },
          "os_name": {
            "type": "string",
            "description": "Reported OS name (e.g. windows)."
          },
          "os_version": {
            "type": "string",
            "description": "Reported OS version (e.g. 2022)."
          }
        }
      }
    }
  },
  "additionalProperties": false
}`

// extraSpecsJSONSchema is the JSON schema for per-pool extra_specs. M1 keeps
// this permissive (an open object); pool-level overrides (flavor sizing,
// per-pool golden overrides) are formalised in later milestones.
const extraSpecsJSONSchema = `{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "garm-provider-vmharness extra_specs",
  "type": "object",
  "properties": {
    "source_image": {
      "type": "string",
      "description": "Override the golden source for this pool."
    }
  },
  "additionalProperties": true
}`
