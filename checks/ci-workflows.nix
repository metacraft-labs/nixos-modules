{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      flakeChecksWorkflow = ../.github/workflows/reusable-flake-checks-ci-matrix.yml;
      terraformWorkflow = ../.github/workflows/reusable-terraform-ci.yml;
    in
    {
      checks.reusable-flake-checks-mcl-ref =
        pkgs.runCommand "reusable-flake-checks-mcl-ref"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
          }
          ''
            python3 - <<'PY'
            import os
            import subprocess
            import tempfile
            from pathlib import Path

            workflow = Path("${flakeChecksWorkflow}").read_text()
            lines = workflow.splitlines()

            step_index = None
            for index, line in enumerate(lines):
                if "- name: Compute reusable workflow SHA and set mcl nix run command" in line:
                    step_index = index
                    break
            assert step_index is not None, "compute-mcl-ref step not found"

            step_indent = len(lines[step_index]) - len(lines[step_index].lstrip())
            next_step_index = len(lines)
            for index in range(step_index + 1, len(lines)):
                if lines[index].strip() and (
                    len(lines[index]) - len(lines[index].lstrip())
                ) <= step_indent:
                    next_step_index = index
                    break
            compute_step = "\n".join(lines[step_index:next_step_index])

            assert "gh api" not in compute_step, "compute step must not call GitHub APIs"
            assert "/actions/runs/" not in compute_step, "compute step must not inspect caller workflow runs"
            assert "GITHUB_WORKFLOW_REF" in compute_step
            assert "GITHUB_WORKFLOW_SHA" in compute_step
            assert "is_commit_sha" in compute_step, "compute step must validate refs before building flake URI"

            run_index = None
            for index in range(step_index + 1, next_step_index):
                if lines[index].strip() == "run: |":
                    run_index = index
                    break
            assert run_index is not None, "compute-mcl-ref run block not found"

            run_indent = len(lines[run_index]) - len(lines[run_index].lstrip())
            block_indent = run_indent + 2
            block = []
            for line in lines[run_index + 1:next_step_index]:
                if not line.strip():
                    block.append("")
                    continue
                indent = len(line) - len(line.lstrip())
                assert indent >= block_indent, f"unexpected run block indentation: {line!r}"
                block.append(line[block_indent:])
            script = "\n".join(block) + "\n"

            with tempfile.TemporaryDirectory() as temp:
                temp_path = Path(temp)
                script_path = temp_path / "compute-mcl-ref.sh"
                script_path.write_text(script)
                subprocess.run(["${pkgs.bash}/bin/bash", "-n", str(script_path)], check=True)

                def run_case(name, env_updates, expected_ref):
                    output_path = temp_path / f"{name}.out"
                    env = os.environ.copy()
                    env.update(
                        {
                            "GITHUB_OUTPUT": str(output_path),
                            "GITHUB_REPOSITORY": "",
                            "GITHUB_SHA": "",
                            "GITHUB_WORKFLOW_REF": "",
                            "GITHUB_WORKFLOW_SHA": "",
                        }
                    )
                    env.update(env_updates)
                    result = subprocess.run(
                        ["${pkgs.bash}/bin/bash", str(script_path)],
                        env=env,
                        text=True,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                    )
                    assert result.returncode == 0, (
                        f"{name}: exit {result.returncode}\n"
                        f"stdout:\n{result.stdout}\nstderr:\n{result.stderr}"
                    )
                    outputs = dict(
                        line.split("=", 1)
                        for line in output_path.read_text().splitlines()
                        if "=" in line
                    )
                    assert outputs["workflow_sha"] == expected_ref, (name, outputs)
                    expected_cmd = (
                        "nix run --accept-flake-config "
                        f"github:metacraft-labs/nixos-modules/{expected_ref}#mcl"
                    )
                    assert outputs["mcl_flake_cmd"] == expected_cmd, (name, outputs)
                    assert "{" not in outputs["mcl_flake_cmd"], (name, outputs)
                    assert "Resource not accessible" not in outputs["mcl_flake_cmd"], (name, outputs)

                workflow_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
                caller_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

                run_case(
                    "reusable_workflow_sha",
                    {
                        "GITHUB_WORKFLOW_REF": (
                            "metacraft-labs/nixos-modules/.github/workflows/"
                            "reusable-flake-checks-ci-matrix.yml@refs/heads/main"
                        ),
                        "GITHUB_WORKFLOW_SHA": workflow_sha,
                        "GITHUB_REPOSITORY": "metacraft-labs/infra",
                        "GITHUB_SHA": caller_sha,
                    },
                    workflow_sha,
                )
                run_case(
                    "local_repo_pr_sha",
                    {
                        "GITHUB_REPOSITORY": "metacraft-labs/nixos-modules",
                        "GITHUB_SHA": caller_sha,
                        "GITHUB_WORKFLOW_REF": (
                            "metacraft-labs/nixos-modules/.github/workflows/"
                            "reusable-flake-checks-ci-matrix.yml@refs/pull/1/merge"
                        ),
                        "GITHUB_WORKFLOW_SHA": workflow_sha,
                    },
                    caller_sha,
                )
                run_case(
                    "forbidden_api_json_falls_back",
                    {
                        "GITHUB_WORKFLOW_REF": (
                            "metacraft-labs/nixos-modules/.github/workflows/"
                            "reusable-flake-checks-ci-matrix.yml@refs/heads/main"
                        ),
                        "GITHUB_WORKFLOW_SHA": '{"message":"Resource not accessible by integration","status":"403"}',
                        "GITHUB_REPOSITORY": "metacraft-labs/infra",
                        "GITHUB_SHA": caller_sha,
                    },
                    "main",
                )
                run_case("empty_context_falls_back", {}, "main")
            PY

            touch "$out"
          '';

      checks.reusable-terraform-drift-workflow =
        pkgs.runCommand "reusable-terraform-drift-workflow"
          {
            nativeBuildInputs = [
              pkgs.bash
              pkgs.python3
            ];
          }
          ''
            python3 - <<'PY'
            import subprocess
            import tempfile
            from pathlib import Path

            workflow = Path("${terraformWorkflow}").read_text()
            lines = workflow.splitlines()

            def extract_named_block(start_text, base_indent=None):
                start = None
                for index, line in enumerate(lines):
                    if line.strip() == start_text:
                        start = index
                        break
                assert start is not None, f"{start_text!r} not found"

                if base_indent is None:
                    base_indent = len(lines[start]) - len(lines[start].lstrip())

                end = len(lines)
                for index in range(start + 1, len(lines)):
                    if lines[index].strip() and (
                        len(lines[index]) - len(lines[index].lstrip())
                    ) <= base_indent:
                        end = index
                        break
                return lines[start:end]

            def extract_run_script(block_lines, step_name):
                step_index = None
                for index, line in enumerate(block_lines):
                    if line.strip() == f"- name: {step_name}":
                        step_index = index
                        break
                assert step_index is not None, f"{step_name!r} step not found"

                step_indent = len(block_lines[step_index]) - len(block_lines[step_index].lstrip())
                step_end = len(block_lines)
                for index in range(step_index + 1, len(block_lines)):
                    if block_lines[index].strip() and (
                        len(block_lines[index]) - len(block_lines[index].lstrip())
                    ) <= step_indent:
                        step_end = index
                        break

                run_index = None
                for index in range(step_index + 1, step_end):
                    if block_lines[index].strip() == "run: |":
                        run_index = index
                        break
                assert run_index is not None, f"{step_name!r} run block not found"

                run_indent = len(block_lines[run_index]) - len(block_lines[run_index].lstrip())
                block_indent = run_indent + 2
                script_lines = []
                for line in block_lines[run_index + 1:step_end]:
                    if not line.strip():
                        script_lines.append("")
                        continue
                    indent = len(line) - len(line.lstrip())
                    assert indent >= block_indent, f"unexpected run block indentation: {line!r}"
                    script_lines.append(line[block_indent:])
                return "\n".join(script_lines) + "\n"

            drift_job = extract_named_block("drift-check:", base_indent=2)
            drift_text = "\n".join(drift_job)

            terranix_index = drift_text.find("- name: Terranix")
            init_index = drift_text.find("- name: Init")
            detect_index = drift_text.find("- name: Detect drift")
            assert terranix_index != -1, "drift job must generate Terranix before init"
            assert init_index != -1, "drift job Init step not found"
            assert detect_index != -1, "drift job Detect drift step not found"
            assert terranix_index < init_index < detect_index, (
                "drift job must generate Terranix before init and plan"
            )

            script = extract_run_script(drift_job, "Detect drift")
            assert "set -euo pipefail" in script
            assert "run_tofu()" in script
            assert "plan_exit=$?" in script
            assert "| tee /tmp/drift-plan.txt" not in script, (
                "drift plan exit code must not be hidden behind tee"
            )

            with tempfile.TemporaryDirectory() as temp:
                script_path = Path(temp) / "detect-drift.sh"
                script_path.write_text(script)
                subprocess.run(["${pkgs.bash}/bin/bash", "-n", str(script_path)], check=True)
            PY

            touch "$out"
          '';
    };
}
