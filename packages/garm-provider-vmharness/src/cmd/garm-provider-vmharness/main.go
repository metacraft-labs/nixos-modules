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

// Command garm-provider-vmharness is GARM's stateless external provider for
// libvirt/KVM Windows runners driven through vm-harness/virsh.
//
// It speaks GARM's external-provider protocol: GARM sets GARM_COMMAND +
// friends in the environment, pipes a BootstrapInstance JSON on stdin for
// CreateInstance, and expects a ProviderInstance JSON on stdout with the right
// exit code. All of that plumbing (env parsing, stdin, dispatch, exit-code
// mapping) is provided by github.com/cloudbase/garm-provider-common/execution,
// the same library GARM's own azure/openstack providers use — so protocol
// compatibility is guaranteed by construction.
package main

import (
	"context"
	"fmt"
	"os"

	"github.com/cloudbase/garm-provider-common/execution"
	commonExecution "github.com/cloudbase/garm-provider-common/execution/common"

	"github.com/metacraft-labs/garm-provider-vmharness/internal/provider"
)

func main() {
	ctx := context.Background()

	env, err := execution.GetEnvironment()
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to get environment: %s\n", err)
		os.Exit(1)
	}

	prov, err := provider.New(env.ProviderConfigFile)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to initialise provider: %s\n", err)
		os.Exit(1)
	}

	ret, err := env.Run(ctx, prov)
	if err != nil {
		// Map known error kinds (ErrNotFound / ErrDuplicateEntity) to GARM's
		// documented exit codes (30 / 31); everything else is exit 1.
		code := commonExecution.ResolveErrorToExitCode(err)
		fmt.Fprintf(os.Stderr, "%s\n", err)
		os.Exit(code)
	}

	if ret != "" {
		fmt.Fprint(os.Stdout, ret)
	}
}
