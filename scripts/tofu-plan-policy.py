#!/usr/bin/env python3
"""
OpenTofu plan JSON policy checker.

Analyzes tofu show -json output to enforce CI safety policies for
infrastructure-as-code workflows. Used as a gate in the reusable
Terraform CI workflow (M1).

Exit codes:
    0 - All checks pass
    1 - Policy violation (hard gate failure)
    2 - Advisory warnings only (non-blocking)
"""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


def load_plan(path: str) -> dict:
    """Load and return the plan JSON."""
    with open(path) as f:
        return json.load(f)


def get_resource_changes(plan: dict) -> list:
    """Extract resource_changes from the plan."""
    return plan.get("resource_changes", [])


def classify_actions(resource_changes: list) -> dict:
    """Classify resource changes by action type."""
    result = {
        "creates": [],
        "imports": [],
        "updates": [],
        "deletes": [],
        "replaces": [],
        "moves": [],
        "no_ops": [],
    }
    for rc in resource_changes:
        actions = rc.get("change", {}).get("actions", [])
        address = rc.get("address", "<unknown>")
        rtype = rc.get("type", "<unknown>")
        importing = rc.get("change", {}).get("importing")

        entry = {"address": address, "type": rtype, "actions": actions}

        if actions == ["no-op"]:
            result["no_ops"].append(entry)
        elif actions == ["create"] and importing:
            entry["import_id"] = importing.get("id", "")
            result["imports"].append(entry)
        elif actions == ["create"]:
            result["creates"].append(entry)
        elif actions == ["update"]:
            result["updates"].append(entry)
        elif actions == ["delete"]:
            result["deletes"].append(entry)
        elif set(actions) >= {"create", "delete"}:
            result["replaces"].append(entry)
        elif actions == ["read"]:
            pass  # data source reads are fine
        else:
            # Unknown action combination — treat as update
            result["updates"].append(entry)

    return result


def check_import_only(classified: dict) -> list:
    """Check that an import-only PR has zero updates/deletes/replaces/creates."""
    errors = []
    if classified["updates"]:
        for r in classified["updates"]:
            errors.append(f"Update action on {r['address']} (import-only PRs must have zero updates)")
    if classified["deletes"]:
        for r in classified["deletes"]:
            errors.append(f"Delete action on {r['address']} (import-only PRs must have zero deletes)")
    if classified["replaces"]:
        for r in classified["replaces"]:
            errors.append(f"Replace action on {r['address']} (import-only PRs must have zero replaces)")
    if classified["creates"]:
        for r in classified["creates"]:
            errors.append(f"Create (non-import) action on {r['address']} (import-only PRs must only have imports)")
    return errors


def check_single_resource_type(classified: dict, mode: str) -> list:
    """For import-only mode, check that only one resource type is being imported."""
    errors = []
    if mode != "import-only":
        return errors

    import_types = set(r["type"] for r in classified["imports"])
    if len(import_types) > 1:
        errors.append(
            f"Import PR contains multiple resource types: {', '.join(sorted(import_types))}. "
            f"Import-only PRs must contain exactly one resource type per PR."
        )
    return errors


def check_expected_types(classified: dict, expected_types: list, scope_expansion: bool) -> list:
    """Check that all resource changes use expected types only."""
    if not expected_types or scope_expansion:
        return []

    errors = []
    all_changes = (
        classified["creates"]
        + classified["imports"]
        + classified["updates"]
        + classified["deletes"]
        + classified["replaces"]
    )
    actual_types = set(r["type"] for r in all_changes)
    unexpected = actual_types - set(expected_types)
    if unexpected:
        errors.append(
            f"Plan contains unexpected resource types: {', '.join(sorted(unexpected))}. "
            f"Expected only: {', '.join(sorted(expected_types))}. "
            f"Add the 'scope-expansion' label if this is intentional."
        )
    return errors


def check_duplicate_imports(classified: dict) -> list:
    """Check that no remote object is imported to multiple addresses."""
    errors = []
    seen_ids = {}
    for r in classified["imports"]:
        import_id = r.get("import_id", "")
        if not import_id:
            continue
        if import_id in seen_ids:
            errors.append(
                f"Duplicate import: remote object '{import_id}' is imported to both "
                f"'{seen_ids[import_id]}' and '{r['address']}'"
            )
        else:
            seen_ids[import_id] = r["address"]
    return errors


def check_blast_radius(classified: dict, expected: dict) -> list:
    """Compare actual plan changes against declared blast radius."""
    errors = []
    checks = [
        ("creates", "expected_creates"),
        ("imports", "expected_imports"),
        ("updates", "expected_updates"),
        ("deletes", "expected_destroys"),
    ]
    for actual_key, expected_key in checks:
        if expected_key in expected:
            actual_count = len(classified[actual_key])
            expected_count = expected[expected_key]
            if actual_count > expected_count:
                errors.append(
                    f"Blast radius exceeded: {actual_key} count is {actual_count}, "
                    f"declared {expected_key} is {expected_count}"
                )

    if "expected_resource_types" in expected:
        all_changes = (
            classified["creates"]
            + classified["imports"]
            + classified["updates"]
            + classified["deletes"]
            + classified["replaces"]
        )
        actual_types = set(r["type"] for r in all_changes)
        expected_types = set(expected["expected_resource_types"])
        unexpected = actual_types - expected_types
        if unexpected:
            errors.append(
                f"Blast radius: unexpected resource types: {', '.join(sorted(unexpected))}"
            )

    return errors


def check_moved_blocks(classified: dict, plan: dict) -> list:
    """Advisory: warn if create+destroy of same type without moved blocks."""
    warnings = []

    create_types = set(r["type"] for r in classified["creates"])
    delete_types = set(r["type"] for r in classified["deletes"])
    overlap = create_types & delete_types

    if not overlap:
        return warnings

    # Check if there are moved blocks in the plan
    moves = classified.get("moves", [])
    has_moves = len(moves) > 0

    if not has_moves:
        for rtype in sorted(overlap):
            warnings.append(
                f"Plan shows both create and destroy of '{rtype}' without moved blocks. "
                f"If this is a refactor/rename, use moved blocks to preserve state continuity."
            )

    return warnings


def run_custom_checks(custom_checks_dir: str, plan_path: str) -> tuple:
    """Run pluggable static checks from a directory."""
    errors = []
    warnings = []

    if not custom_checks_dir or not os.path.isdir(custom_checks_dir):
        return errors, warnings

    check_dir = Path(custom_checks_dir)
    for check_file in sorted(check_dir.iterdir()):
        if not check_file.is_file() or not os.access(check_file, os.X_OK):
            continue

        try:
            result = subprocess.run(
                [str(check_file), plan_path],
                capture_output=True,
                text=True,
                timeout=30,
            )
            if result.returncode == 1:
                output = result.stdout.strip() or result.stderr.strip()
                errors.append(f"Custom check '{check_file.name}' failed: {output}")
            elif result.returncode == 2:
                output = result.stdout.strip() or result.stderr.strip()
                warnings.append(f"Custom check '{check_file.name}' warning: {output}")
        except subprocess.TimeoutExpired:
            errors.append(f"Custom check '{check_file.name}' timed out after 30s")
        except Exception as e:
            errors.append(f"Custom check '{check_file.name}' error: {e}")

    return errors, warnings


def parse_blast_radius_args(args) -> dict:
    """Build blast radius dict from CLI args."""
    result = {}
    if args.expected_creates is not None:
        result["expected_creates"] = args.expected_creates
    if args.expected_imports is not None:
        result["expected_imports"] = args.expected_imports
    if args.expected_updates is not None:
        result["expected_updates"] = args.expected_updates
    if args.expected_destroys is not None:
        result["expected_destroys"] = args.expected_destroys
    if args.expected_resource_types:
        result["expected_resource_types"] = args.expected_resource_types
    return result


def main():
    parser = argparse.ArgumentParser(description="OpenTofu plan JSON policy checker")
    parser.add_argument("plan_json", help="Path to plan JSON file (from tofu show -json)")
    parser.add_argument(
        "--mode",
        choices=["import-only", "mixed"],
        default="mixed",
        help="Policy mode: 'import-only' enforces zero update/delete/create; 'mixed' allows changes",
    )
    parser.add_argument(
        "--expected-types",
        nargs="+",
        help="Expected resource types (milestone-scoped allowlist)",
    )
    parser.add_argument(
        "--scope-expansion",
        action="store_true",
        help="Override scope restrictions (scope-expansion label present)",
    )
    parser.add_argument(
        "--expected-creates",
        type=int,
        default=None,
        help="Declared expected number of creates",
    )
    parser.add_argument(
        "--expected-imports",
        type=int,
        default=None,
        help="Declared expected number of imports",
    )
    parser.add_argument(
        "--expected-updates",
        type=int,
        default=None,
        help="Declared expected number of updates",
    )
    parser.add_argument(
        "--expected-destroys",
        type=int,
        default=None,
        help="Declared expected number of destroys",
    )
    parser.add_argument(
        "--expected-resource-types",
        nargs="+",
        help="Declared expected resource types for blast radius check",
    )
    parser.add_argument(
        "--custom-checks-dir",
        help="Directory containing custom check scripts",
    )

    args = parser.parse_args()

    plan = load_plan(args.plan_json)
    resource_changes = get_resource_changes(plan)
    classified = classify_actions(resource_changes)

    all_errors = []
    all_warnings = []

    # Print summary
    print(f"Plan summary:")
    print(f"  Imports:  {len(classified['imports'])}")
    print(f"  Creates:  {len(classified['creates'])}")
    print(f"  Updates:  {len(classified['updates'])}")
    print(f"  Deletes:  {len(classified['deletes'])}")
    print(f"  Replaces: {len(classified['replaces'])}")
    print(f"  No-ops:   {len(classified['no_ops'])}")
    print()

    # Import-only checks
    if args.mode == "import-only":
        all_errors.extend(check_import_only(classified))
        all_errors.extend(check_single_resource_type(classified, args.mode))

    # Milestone-scoped type check
    if args.expected_types:
        all_errors.extend(
            check_expected_types(classified, args.expected_types, args.scope_expansion)
        )

    # Duplicate import detection
    all_errors.extend(check_duplicate_imports(classified))

    # Blast radius
    blast_radius = parse_blast_radius_args(args)
    if blast_radius:
        all_errors.extend(check_blast_radius(classified, blast_radius))

    # Moved blocks advisory
    all_warnings.extend(check_moved_blocks(classified, plan))

    # Custom checks
    custom_errors, custom_warnings = run_custom_checks(args.custom_checks_dir, args.plan_json)
    all_errors.extend(custom_errors)
    all_warnings.extend(custom_warnings)

    # Report
    if all_warnings:
        print("WARNINGS:")
        for w in all_warnings:
            print(f"  ⚠ {w}")
        print()

    if all_errors:
        print("POLICY VIOLATIONS:")
        for e in all_errors:
            print(f"  ✗ {e}")
        print()
        print(f"Policy check FAILED with {len(all_errors)} violation(s).")
        sys.exit(1)

    if all_warnings:
        print(f"Policy check PASSED with {len(all_warnings)} warning(s).")
        sys.exit(2)

    print("Policy check PASSED.")
    sys.exit(0)


if __name__ == "__main__":
    main()
