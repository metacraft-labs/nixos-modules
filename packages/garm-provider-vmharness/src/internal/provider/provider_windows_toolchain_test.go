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

import (
	"strings"
	"testing"

	commonParams "github.com/cloudbase/garm-provider-common/params"
)

// The eph-win-x64 golden ships neither git nor bash. Two distinct things break:
//
//   - every `shell: bash` step dies with "bash: command not found";
//   - actions/checkout finds no git and silently degrades to a REST-API zip
//     download -- no submodules, no history, no LFS -- while still reporting
//     success, so the lane looks green until something downstream needs what
//     the zip did not contain.
//
// The second is why the fix lives in this template rather than in a workflow:
// actions/checkout is the first step of a job, so no action of ours runs before
// it. This template does -- it executes in the guest during provisioning,
// before Runner.Listener starts -- so the PATH it establishes is inherited by
// the runner and by every step, checkout included.
//
// These tests pin that behaviour. The ordering assertion is the load-bearing
// one: provisioning that happened AFTER the runner started would satisfy every
// content check here and still leave checkout without git.

func windowsBootstrapText(t *testing.T) string {
	t.Helper()
	params := commonParams.BootstrapInstance{
		Name:             "garm-win-x64-1",
		RepoURL:          "https://github.com/example-org/example-repo",
		CallbackURL:      "http://192.168.122.1:9997/api/v1/callbacks",
		MetadataURL:      "http://192.168.122.1:9997/api/v1/metadata",
		InstanceToken:    "instance-token",
		OSType:           commonParams.Windows,
		OSArch:           commonParams.Amd64,
		Labels:           []string{"self-hosted", "windows", "x64", "eph-win-x64"},
		JitConfigEnabled: true,
		Tools: []commonParams.RunnerApplicationDownload{
			{
				OS:           strptr("win"),
				Architecture: strptr("x64"),
				DownloadURL:  strptr("https://example.invalid/actions-runner-win-x64.zip"),
				Filename:     strptr("actions-runner-win-x64.zip"),
			},
		},
	}
	tools, err := pickTools(params)
	if err != nil {
		t.Fatalf("pickTools: %v", err)
	}
	rendered, err := renderRunnerInstallTemplate(
		"windows-foreground",
		windowsForegroundRunnerInstallTemplate,
		runnerInstallTemplateDataFrom(params, tools, params.Name),
	)
	if err != nil {
		t.Fatalf("renderRunnerInstallTemplate: %v", err)
	}
	return string(rendered)
}

// TestWindowsBootstrapProvisionsGitAndBash pins the content of the toolchain
// provisioning: what is installed, that it is pinned and digest-verified, and
// that both PATH entries are established.
func TestWindowsBootstrapProvisionsGitAndBash(t *testing.T) {
	text := windowsBootstrapText(t)

	for _, want := range []string{
		// Pinned version + digest. An unpinned or unverified download into a
		// CI runner's SYSTEM PATH is remote code execution with extra steps.
		"$PortableGitVersion = '2.47.1'",
		"$PortableGitSha256 = '4f3f21f4effcb659566883ee1ed3ae403e5b3d7a0699cee455f6cd765e1ac39c'",
		"https://github.com/git-for-windows/git/releases/download/v$PortableGitVersion.windows.1/$PortableGitName",
		// The digest must be checked and must abort on mismatch.
		"$actualHash = (Get-FileHash -Algorithm SHA256 -Path $archive).Hash.ToLowerInvariant()",
		"Fail-Install \"PortableGit checksum mismatch: expected $PortableGitSha256 got $actualHash\"",
		// Both directories: cmd/ carries git.exe, bin/ carries bash.exe. One
		// without the other is the half-fix this exists to avoid.
		"foreach ($sub in @('cmd', 'bin')) {",
		"Add-RunnerPathEntry (Join-Path $PortableGitInstallDir $sub)",
		// The machine PATH does not reach the already-running process that
		// launches run.cmd, so the process PATH must be set too.
		"$env:PATH = \"$Entry;$env:PATH\"",
		"[Environment]::SetEnvironmentVariable('Path', $updated, 'Machine')",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("windows bootstrap missing %q:\n%s", want, text)
		}
	}

	// MinGit satisfies actions/checkout and still leaves every bash step dead.
	// Pinning PortableGit explicitly keeps a future "smaller download" refactor
	// from reintroducing exactly that half-fix.
	//
	// Scoped to executable lines: the template's own PowerShell comments explain
	// why MinGit is rejected, and a substring search over the whole rendered
	// text would fire on that explanation. Checking the comment rather than the
	// code is the failure mode these tests exist to avoid, so check the code.
	for _, line := range strings.Split(text, "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed == "" || strings.HasPrefix(trimmed, "#") {
			continue
		}
		if strings.Contains(trimmed, "MinGit") {
			t.Fatalf("windows bootstrap uses MinGit, which ships no Git Bash:\n%s", line)
		}
	}
}

// TestWindowsBootstrapVerifiesToolchainRatherThanAssumingIt is the guard
// against this provisioning becoming the same silent no-op it fixes: an
// install that "succeeded" but left the tools unusable must fail the runner,
// not proceed into a job that will fail confusingly much later.
func TestWindowsBootstrapVerifiesToolchainRatherThanAssumingIt(t *testing.T) {
	text := windowsBootstrapText(t)

	for _, want := range []string{
		// Re-check after provisioning, whichever branch was taken.
		"Fail-Install 'git and Git Bash are still not on PATH after provisioning'",
		// Presence on PATH is not usability: both tools must actually run.
		"$gitVersion = (& git --version 2>&1 | Out-String).Trim()",
		"$bashVersion = (& bash --version 2>&1 | Select-Object -First 1 | Out-String).Trim()",
		"Fail-Install 'git --version produced no output'",
		"Fail-Install 'bash --version produced no output'",
		// A System32 bash.exe is the WSL launcher stub: on PATH, launches, and
		// fails only once a step tries to use it. Worse than absent.
		"if ($bash.Source -like \"$env:SystemRoot\\System32\\*\") {",
	} {
		if !strings.Contains(text, want) {
			t.Fatalf("windows bootstrap missing verification %q:\n%s", want, text)
		}
	}
}

// TestWindowsBootstrapProvisionsToolchainBeforeRunnerStarts is the assertion
// that actually makes actions/checkout work. Content alone is not enough: the
// toolchain must be on PATH before Runner.Listener is launched, because the
// runner inherits this process's environment and checkout runs before any
// action of ours could intervene.
func TestWindowsBootstrapProvisionsToolchainBeforeRunnerStarts(t *testing.T) {
	text := windowsBootstrapText(t)

	const invocation = "\nInitialize-RunnerToolchain\n"
	invocationAt := strings.Index(text, invocation)
	if invocationAt < 0 {
		t.Fatalf("windows bootstrap never CALLS Initialize-RunnerToolchain; "+
			"defining it is not running it, and an uncalled function leaves "+
			"checkout without git:\n%s", text)
	}

	runnerAt := strings.Index(text, `& "$env:ComSpec" /d /c run.cmd`)
	if runnerAt < 0 {
		t.Fatalf("windows bootstrap does not launch run.cmd in the foreground:\n%s", text)
	}

	if invocationAt > runnerAt {
		t.Fatalf("Initialize-RunnerToolchain runs at offset %d, after the runner "+
			"starts at offset %d; every job step, including actions/checkout, "+
			"would already have been handed a PATH without git", invocationAt, runnerAt)
	}

	// It must also precede the runner *download*, so a broken toolchain fails
	// fast rather than after a multi-hundred-MB fetch.
	if downloadAt := strings.Index(text, "downloading tools from"); downloadAt >= 0 && invocationAt > downloadAt {
		t.Fatalf("Initialize-RunnerToolchain runs after the runner download; "+
			"a guest that cannot be provisioned should fail before that work "+
			"(toolchain at %d, download at %d)", invocationAt, downloadAt)
	}
}

// TestLinuxBootstrapUnaffectedByWindowsToolchain keeps the change scoped: the
// Linux template must not have grown Windows provisioning.
func TestLinuxBootstrapUnaffectedByWindowsToolchain(t *testing.T) {
	if strings.Contains(linuxForegroundRunnerInstallTemplate, "PortableGit") {
		t.Fatal("the Linux bootstrap template references PortableGit")
	}
}
