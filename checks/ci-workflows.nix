{ ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      flakeChecksWorkflow = ../.github/workflows/reusable-flake-checks-ci-matrix.yml;
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
    };
}
