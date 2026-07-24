module mcl.commands.deploy_apply;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.file : deleteme, exists, readText, remove, write;
import std.json : JSONValue, parseJSON;
import std.process : environment;
import std.stdio : stdin;
import std.string : endsWith, startsWith, strip;
import std.typecons : Nullable;

import argparse : AllowedValues, Command, Description, EnvFallback, NamedArgument,
    Placeholder;

import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest,
    manifestDeploymentId, manifestDesiredSystemPath, manifestSequence, manifestSystem,
    manifestTarget, verifyManifestSignature;
import mcl.utils.deploy_state : markDeploymentState, recordDesiredManifest;
import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, deploymentEventLogPathFromEnv,
    queryClosureSummary, stderrSummary;
import mcl.utils.process : ProcessResult, ProcessRunner, runProcessCapture;

enum DeploymentActivationMode
{
    nixos,

    @AllowedValues("nix-darwin")
    nixDarwin,
}

enum deployApplyDeferredExitCode = 75;

@(Command("deploy-apply")
    .Description("Target-side signed deployment apply wrapper"))
struct DeployApplyArgs
{
    @(NamedArgument(["manifest"])
        .Placeholder("manifest.json|-")
        .Description("Signed desired-state manifest; '-' reads stdin"))
    string manifest = "-";

    @(NamedArgument(["target"])
        .Placeholder("name")
        .Description("Expected deployment target name"))
    string target;

    @(NamedArgument(["trusted-manifest-public-key"])
        .Placeholder("KEY")
        .Description("OpenSSH public key trusted to sign manifests")
        .EnvFallback("MCL_DEPLOY_MANIFEST_PUBLIC_KEY"))
    string trustedManifestPublicKey;

    @(NamedArgument(["allowed-signers"])
        .Placeholder("PATH")
        .Description("OpenSSH allowed signers file trusted for manifest verification"))
    string allowedSigners;

    @(NamedArgument(["state-dir"])
        .Placeholder("DIR")
        .Description("Durable target-local deployment state directory"))
    string stateDir = "/var/lib/mcl/deployments";

    @(NamedArgument(["activation-mode"])
        .Placeholder("nixos|nix-darwin")
        .Description("System activation contract; nixos remains the default"))
    DeploymentActivationMode activationMode = DeploymentActivationMode.nixos;

    @(NamedArgument(["system-profile"])
        .Placeholder("PATH")
        .Description("nix-darwin system profile updated atomically before activation"))
    string systemProfile = "/nix/var/nix/profiles/system";

    @(NamedArgument(["pre-switch-hook"])
        .Placeholder("PATH")
        .Description("Executable readiness hook called with DESIRED PREVIOUS; exit 75 defers deployment"))
    string preSwitchHook;

    @(NamedArgument(["post-switch-hook"])
        .Placeholder("PATH")
        .Description("Executable cleanup hook called with DESIRED PREVIOUS OUTCOME"))
    string postSwitchHook;

    @(NamedArgument(["event-log"])
        .Placeholder("events.jsonl")
        .Description("Write deployment events as JSONL")
        .EnvFallback("MCL_DEPLOY_EVENT_LOG"))
    string eventLog;

    @(NamedArgument(["dry-run"])
        .Description("Verify and record state, but do not restore, switch, health-check, or rollback"))
    bool dryRun;

    @(NamedArgument(["reject-ssh-original-command"])
        .Description("Reject non-empty SSH_ORIGINAL_COMMAND for forced-command keys"))
    bool rejectSshOriginalCommand;

    @(NamedArgument(["restore-command"])
        .Placeholder("COMMAND")
        .Description("Override closure restore command for deterministic tests")
        .EnvFallback("MCL_DEPLOY_RESTORE_COMMAND"))
    string restoreCommand;

    @(NamedArgument(["switch-command"])
        .Placeholder("COMMAND")
        .Description("Override switch command for deterministic tests")
        .EnvFallback("MCL_DEPLOY_SWITCH_COMMAND"))
    string switchCommand;

    @(NamedArgument(["rollback-command"])
        .Placeholder("COMMAND")
        .Description("Override rollback command for deterministic tests")
        .EnvFallback("MCL_DEPLOY_ROLLBACK_COMMAND"))
    string rollbackCommand;

    @(NamedArgument(["generation-command"])
        .Placeholder("COMMAND")
        .Description("Override command that prints the current generation path")
        .EnvFallback("MCL_DEPLOY_GENERATION_COMMAND"))
    string generationCommand;

    @(NamedArgument(["no-detach-switch"])
        .Description("Run switch-to-configuration in-process instead of a detached systemd-run scope. "
            ~ "Detaching is the default and prevents the agent unit from deadlocking when the switch "
            ~ "restarts mcl-deploy-agent.service; disable only in environments without systemd."))
    bool noDetachSwitch;

    @(NamedArgument(["transport"])
        .Placeholder("NAME")
        .Description("Deployment transport recorded in target-side events"))
    string transport = "ssh";

    @(NamedArgument(["controller"])
        .Placeholder("NAME")
        .Description("Deployment controller recorded in target-side events"))
    string controller = "mcl-reconciler";
}

struct DeployApplyDependencies
{
    ProcessRunner runProcess;
    ProcessRunner queryProcess;
}

export int deploy_apply(DeployApplyArgs args)
{
    return deployApplyImpl(args, DeployApplyDependencies(
        runProcess: (string[] command) => runProcessCapture(command, true),
        queryProcess: (string[] command) => runProcessCapture(command),
    ));
}

string readManifestText(string path)
{
    if (path == "-")
        return stdin.byLine.join("\n").to!string;
    return path.readText;
}

string[] manifestSubstituters(JSONValue manifest)
{
    string[] result;
    foreach (substituter; manifest["cacheRequirements"]["substituters"].array)
        result ~= substituter["url"].str;
    return result;
}

string[] manifestTrustedPublicKeys(JSONValue manifest)
{
    string[] result;
    foreach (substituter; manifest["cacheRequirements"]["substituters"].array)
        if (substituter["trustedPublicKey"].str != "")
            result ~= substituter["trustedPublicKey"].str;
    return result;
}

bool automaticRollbackRequested(JSONValue manifest)
{
    auto policy = manifest["rollbackPolicy"];
    return policy["mode"].str == "automatic"
        && policy["onHealthCheckFailure"].str == "rollback"
        && policy["maxAttempts"].integer > 0;
}

ProcessResult shell(ProcessRunner runner, string command)
{
    return runner(["/bin/sh", "-c", command]);
}

// Run an activation command (switch-to-configuration) detached from the caller's
// systemd unit.
//
// The pull agent and the reconciler both run switch-to-configuration from inside
// their own oneshot unit's cgroup. The activated closure legitimately contains a
// new version of that very unit, so switch-to-configuration issues
// `systemctl start/restart mcl-deploy-agent.service` (the timer-wanted oneshot).
// systemd cannot complete that start while the current invocation is still alive,
// so switch-to-configuration blocks forever waiting on a job that can never finish,
// wedging the deploy until the service start-timeout kills it.
//
// systemd-run moves the switch into its own transient scope with a distinct cgroup,
// so systemd is free to (re)start mcl-deploy-agent.service concurrently. --wait
// propagates the switch exit code back to the agent, --pipe forwards stdout/stderr
// so events keep their diagnostics, and --collect garbage-collects the transient
// unit even if it fails.
ProcessResult detachedSwitch(ProcessRunner runner, string command, bool detach)
{
    if (!detach)
        return shell(runner, command);

    import std.uuid : randomUUID;

    auto unitName = "mcl-deploy-activate-" ~ randomUUID.toString;

    // The transient scope does not inherit the agent unit's environment, so
    // forward PATH explicitly; switch-to-configuration's activation scripts call
    // unqualified tools (mkdir, systemctl, ...) that must resolve on PATH.
    auto path = environment.get("PATH", "");

    string[] cmd = [
        "systemd-run",
        "--collect",
        "--pipe",
        "--wait",
        "--quiet",
        "--service-type=exec",
        "--unit=" ~ unitName,
    ];
    if (path != "")
        cmd ~= "--setenv=PATH=" ~ path;
    cmd ~= ["/bin/sh", "-c", command];
    return runner(cmd);
}

ProcessResult currentGeneration(
    DeployApplyArgs args,
    ProcessRunner runner,
)
{
    if (args.generationCommand != "")
        return shell(runner, args.generationCommand);

    final switch (args.activationMode)
    {
        case DeploymentActivationMode.nixos:
            return shell(runner, "readlink -f /run/current-system");
        case DeploymentActivationMode.nixDarwin:
            return runner(["nix-store", "--realise", args.systemProfile]);
    }
}

ProcessResult runLifecycleHook(
    ProcessRunner runner,
    string hook,
    string desired,
    string previous,
    string outcome = "",
)
{
    if (hook == "")
        return ProcessResult(0, "", "");

    auto command = [hook, desired, previous];
    if (outcome != "")
        command ~= outcome;
    return runner(command);
}

ProcessResult setDarwinSystemProfile(
    ProcessRunner runner,
    string profile,
    string generation,
)
{
    return runner(["nix-env", "--profile", profile, "--set", generation]);
}

ProcessResult activateDarwinGeneration(ProcessRunner runner, string generation)
{
    return runner([generation ~ "/activate"]);
}

int deployApplyImpl(DeployApplyArgs args, DeployApplyDependencies deps)
{
    import std.json : JSONOptions;

    enforce(args.target != "", "--target is required.");
    enforce(args.trustedManifestPublicKey != "" || args.allowedSigners != "",
        "--trusted-manifest-public-key or --allowed-signers is required.");
    if (args.activationMode == DeploymentActivationMode.nixDarwin)
    {
        enforce(args.systemProfile != "", "--system-profile must not be empty for nix-darwin activation.");
        enforce(args.switchCommand == "",
            "--switch-command is incompatible with explicit nix-darwin activation.");
        enforce(args.rollbackCommand == "",
            "--rollback-command is incompatible with explicit nix-darwin activation.");
    }

    if (args.rejectSshOriginalCommand)
        enforce(environment.get("SSH_ORIGINAL_COMMAND", "") == "",
            "Forced-command deployment key does not accept arbitrary SSH commands.");

    ProcessResult defaultRunner(string[] command) { return runProcessCapture(command); }
    auto runner = deps.runProcess is null ? &defaultRunner : deps.runProcess;
    auto queryRunner = deps.queryProcess is null ? runner : deps.queryProcess;
    auto manifest = readManifestText(args.manifest).parseJSON;
    enforce(manifestTarget(manifest) == args.target,
        "Manifest target '" ~ manifestTarget(manifest) ~ "' does not match expected target '" ~ args.target ~ "'.");
    enforce(manifest.verifyManifestSignature(args.trustedManifestPublicKey, args.allowedSigners),
        "Manifest signature verification failed.");

    auto accepted = recordDesiredManifest(args.stateDir, manifest);
    auto eventLogPath = args.eventLog != "" ? args.eventLog : deploymentEventLogPathFromEnv();
    auto context = DeploymentEventContext(
        eventLogPath: eventLogPath,
        deploymentId: manifestDeploymentId(manifest),
        correlationId: "",
        cache: "",
        substituters: manifestSubstituters(manifest),
        system: manifestSystem(manifest),
        kind: manifestSystem(manifest).endsWith("-darwin") ? "darwin" : "server",
        transport: args.transport,
        controller: args.controller,
    );
    auto closure = queryClosureSummary(manifestDesiredSystemPath(manifest), queryRunner);

    void emit(
        string phase,
        string commandName,
        string[] argv,
        string status,
        int exitCode,
        string errorMessage = "",
        string errorCode = "command_failed",
        string errorDetails = "",
        JSONValue[string] metadata = null,
        bool errorRetryable = false,
    )
    {
        appendDeploymentEvent(eventLogPath, deploymentEventJson(
            context,
            phase,
            manifestTarget(manifest),
            manifestDesiredSystemPath(manifest),
            commandName,
            argv,
            status,
            exitCode,
            closure,
            errorMessage,
            errorCode,
            errorDetails,
            metadata,
            errorRetryable,
        ));
    }

    if (!accepted)
    {
        emit("activate-requested", "mcl deploy-apply", ["mcl", "deploy-apply"], "skipped", 0,
            "", "superseded", "", [
                "sequence": JSONValue(cast(long) manifestSequence(manifest)),
                "reason": JSONValue("A newer deployment is already accepted for this target."),
            ]);
        return 0;
    }

    emit("activate-requested", "mcl deploy-apply", ["mcl", "deploy-apply"], "succeeded", 0,
        "", "command_failed", "", [
            "sequence": JSONValue(cast(long) manifestSequence(manifest)),
            "dryRun": JSONValue(args.dryRun),
        ]);

    if (args.dryRun)
    {
        markDeploymentState(args.stateDir, manifest, "succeeded", "Dry-run verified signed manifest.");
        emit("complete", "mcl deploy-apply --dry-run", ["mcl", "deploy-apply", "--dry-run"], "succeeded", 0);
        return 0;
    }

    ProcessResult restore;
    string[] restoreArgv;
    if (args.restoreCommand != "")
    {
        restoreArgv = ["sh", "-c", args.restoreCommand];
        restore = shell(runner, args.restoreCommand);
    }
    else
    {
        auto restoreCommand = manifestSubstituters(manifest).length
            ? ["nix", "copy", "--from", manifestSubstituters(manifest)[0], manifestDesiredSystemPath(manifest)]
            : ["nix", "path-info", manifestDesiredSystemPath(manifest)];
        auto keys = manifestTrustedPublicKeys(manifest);
        if (keys.length)
            restoreCommand ~= ["--option", "trusted-public-keys", keys.join(" ")];

        restoreArgv = restoreCommand;
        restore = runner(restoreCommand);
    }
    emit("agent-restore", "nix restore deployment closure", restoreArgv,
        restore.succeeded ? "succeeded" : "failed",
        restore.exitCode,
        restore.succeeded ? "" : "Failed to restore deployment closure",
        "cache_restore_failed",
        restore.succeeded ? "" : restore.stderr.stderrSummary);
    if (!restore.succeeded)
    {
        markDeploymentState(args.stateDir, manifest, "failed", "Closure restore failed.");
        return 1;
    }

    auto desired = manifestDesiredSystemPath(manifest);
    auto previousResult = currentGeneration(args, queryRunner);
    auto previous = previousResult.stdout.strip;
    if (
        args.activationMode == DeploymentActivationMode.nixDarwin
        && (!previousResult.succeeded || previous == "")
    )
    {
        emit("switch", "query current generation", [], "failed", previousResult.exitCode,
            "Failed to determine current system generation", "generation_query_failed",
            previousResult.stderr.stderrSummary);
        markDeploymentState(args.stateDir, manifest, "failed",
            "Could not determine the previous system generation.");
        return 1;
    }

    auto preHook = runLifecycleHook(runner, args.preSwitchHook, desired, previous);
    if (args.preSwitchHook != "")
        emit("switch", "deployment readiness hook",
            [args.preSwitchHook, desired, previous],
            preHook.succeeded ? "succeeded"
                : preHook.exitCode == deployApplyDeferredExitCode ? "skipped" : "failed",
            preHook.exitCode,
            preHook.succeeded ? ""
                : preHook.exitCode == deployApplyDeferredExitCode
                    ? "Deployment readiness hook deferred activation"
                    : "Deployment readiness hook failed",
            preHook.succeeded ? "command_failed"
                : preHook.exitCode == deployApplyDeferredExitCode
                    ? "deployment_deferred" : "pre_switch_hook_failed",
            preHook.succeeded ? "" : preHook.stderr.stderrSummary,
            [
                "lifecycleStage": JSONValue("pre-switch"),
                "desiredGeneration": JSONValue(desired),
                "previousGeneration": JSONValue(previous),
            ],
            preHook.exitCode == deployApplyDeferredExitCode);
    if (!preHook.succeeded)
    {
        auto deferred = preHook.exitCode == deployApplyDeferredExitCode;
        markDeploymentState(args.stateDir, manifest, deferred ? "deferred" : "failed",
            deferred
                ? "Readiness hook deferred deployment; retry budget was not consumed."
                : "Readiness hook failed.");
        emit("complete", "mcl deploy-apply", ["mcl", "deploy-apply"],
            deferred ? "skipped" : "failed",
            deferred ? deployApplyDeferredExitCode : 1,
            deferred ? "Deployment readiness conditions are not met."
                : "Deployment readiness hook failed.",
            deferred ? "deployment_deferred" : "pre_switch_hook_failed", "", [
                "lifecycleStage": JSONValue("pre-switch"),
                "outcome": JSONValue(deferred ? "deferred" : "failed"),
            ], deferred);
        return deferred ? deployApplyDeferredExitCode : 1;
    }

    bool switchOk;
    string current;
    string outcome;
    string state;
    string stateMessage;

    if (args.activationMode == DeploymentActivationMode.nixos)
    {
        auto switchCommand = args.switchCommand == ""
            ? desired ~ "/bin/switch-to-configuration switch"
            : args.switchCommand;
        auto switched = detachedSwitch(runner, switchCommand, !args.noDetachSwitch);
        auto currentResult = currentGeneration(args, queryRunner);
        current = currentResult.stdout.strip;
        switchOk = switched.succeeded;
        emit("switch", "switch-to-configuration", ["sh", "-c", switchCommand],
            switched.succeeded ? "succeeded" : "failed",
            switched.exitCode,
            switched.succeeded ? "" : "System switch failed",
            "switch_failed",
            switched.succeeded ? "" : switched.stderr.stderrSummary,
            [
                "previousGeneration": JSONValue(previous),
                "newGeneration": JSONValue(current),
            ]);
    }
    else
    {
        auto profileSet = setDarwinSystemProfile(runner, args.systemProfile, desired);
        auto activated = profileSet.succeeded
            ? activateDarwinGeneration(runner, desired)
            : ProcessResult(profileSet.exitCode, "", profileSet.stderr);
        switchOk = profileSet.succeeded && activated.succeeded;
        current = currentGeneration(args, queryRunner).stdout.strip;
        auto switchArgv = profileSet.succeeded
            ? [desired ~ "/activate"]
            : ["nix-env", "--profile", args.systemProfile, "--set", desired];
        auto switchError = profileSet.succeeded ? activated : profileSet;
        emit("switch", "nix-darwin profile activation", switchArgv,
            switchOk ? "succeeded" : "failed",
            switchError.exitCode,
            switchOk ? "" : "nix-darwin system switch failed",
            "switch_failed",
            switchOk ? "" : switchError.stderr.stderrSummary,
            [
                "previousGeneration": JSONValue(previous),
                "newGeneration": JSONValue(current),
                "systemProfile": JSONValue(args.systemProfile),
            ]);

        if (profileSet.succeeded && !activated.succeeded)
        {
            auto profileRestored = setDarwinSystemProfile(runner, args.systemProfile, previous);
            auto generationRestored = activateDarwinGeneration(runner, previous);
            auto rollbackOk = profileRestored.succeeded && generationRestored.succeeded;
            current = currentGeneration(args, queryRunner).stdout.strip;
            auto rollbackError = !profileRestored.succeeded ? profileRestored : generationRestored;
            emit("rollback", "nix-darwin activation rollback",
                ["nix-env", "--profile", args.systemProfile, "--set", previous,
                    "&&", previous ~ "/activate"],
                rollbackOk ? "succeeded" : "failed",
                rollbackOk ? 0 : rollbackError.exitCode,
                rollbackOk ? "" : "Failed to restore previous nix-darwin generation",
                "rollback_failed",
                rollbackOk ? "" : rollbackError.stderr.stderrSummary,
                [
                    "previousGeneration": JSONValue(previous),
                    "failedGeneration": JSONValue(desired),
                    "systemProfile": JSONValue(args.systemProfile),
                ]);
        }
    }

    bool healthOk = switchOk;
    if (switchOk)
    {
        foreach (check; manifest["healthChecks"].array)
        {
            string[] command;
            if (check["kind"].str == "command")
                command = [
                    "timeout", check["timeoutSeconds"].integer.to!string,
                    "sh", "-c", check["target"].str,
                ];
            else if (check["kind"].str == "systemd")
                command = ["systemctl", "is-active", "--quiet", check["target"].str];
            else
                command = ["false"];

            auto result = runner(command);
            healthOk = healthOk && result.succeeded;
            emit("healthcheck", check["name"].str, command,
                result.succeeded ? "succeeded" : "failed",
                result.exitCode,
                result.succeeded ? "" : "Health check failed",
                "healthcheck_failed",
                result.succeeded ? "" : result.stderr.stderrSummary,
                [
                    "kind": JSONValue(check["kind"].str),
                    "target": JSONValue(check["target"].str),
                ]);
        }
    }

    if (!switchOk)
    {
        outcome = "switch-failed";
        state = "failed";
        stateMessage = "System switch failed.";
    }
    else if (!healthOk)
    {
        outcome = "healthcheck-failed";
        state = "failed";
        stateMessage = "Health check failed.";
        if (automaticRollbackRequested(manifest) && previous != "")
        {
            ProcessResult rollback;
            string[] rollbackArgv;
            if (args.activationMode == DeploymentActivationMode.nixos)
            {
                auto rollbackCommand = args.rollbackCommand == ""
                    ? previous ~ "/bin/switch-to-configuration switch"
                    : args.rollbackCommand;
                rollback = detachedSwitch(runner, rollbackCommand, !args.noDetachSwitch);
                rollbackArgv = ["sh", "-c", rollbackCommand];
            }
            else
            {
                auto profileRestored = setDarwinSystemProfile(runner, args.systemProfile, previous);
                auto generationRestored = activateDarwinGeneration(runner, previous);
                rollback = !profileRestored.succeeded ? profileRestored : generationRestored;
                rollbackArgv = ["nix-env", "--profile", args.systemProfile, "--set", previous,
                    "&&", previous ~ "/activate"];
            }
            emit("rollback", args.activationMode == DeploymentActivationMode.nixos
                    ? "switch-to-configuration rollback"
                    : "nix-darwin health-check rollback",
                rollbackArgv,
                rollback.succeeded ? "succeeded" : "failed",
                rollback.exitCode,
                rollback.succeeded ? "" : "Automatic rollback failed",
                "rollback_failed",
                rollback.succeeded ? "" : rollback.stderr.stderrSummary,
                [
                    "previousGeneration": JSONValue(previous),
                    "failedGeneration": JSONValue(current),
                ]);
            if (rollback.succeeded)
            {
                outcome = "rolled-back";
                state = "rolled-back";
                stateMessage = "Health check failed; rolled back.";
                current = currentGeneration(args, queryRunner).stdout.strip;
            }
            else
            {
                stateMessage = "Health check and rollback failed.";
            }
        }
    }
    else
    {
        outcome = "succeeded";
        state = "succeeded";
        stateMessage = "Deployment converged.";
    }

    auto postHook = runLifecycleHook(runner, args.postSwitchHook, desired, previous, outcome);
    if (args.postSwitchHook != "")
        emit("switch", "deployment cleanup hook",
            [args.postSwitchHook, desired, previous, outcome],
            postHook.succeeded ? "succeeded" : "failed",
            postHook.exitCode,
            postHook.succeeded ? "" : "Deployment cleanup hook failed",
            "post_switch_hook_failed",
            postHook.succeeded ? "" : postHook.stderr.stderrSummary,
            [
                "lifecycleStage": JSONValue("post-switch"),
                "desiredGeneration": JSONValue(desired),
                "previousGeneration": JSONValue(previous),
                "outcome": JSONValue(outcome),
            ]);
    if (!postHook.succeeded && state == "succeeded")
    {
        state = "failed";
        stateMessage = "Post-switch lifecycle hook failed.";
    }

    markDeploymentState(args.stateDir, manifest, state, stateMessage);
    auto succeeded = state == "succeeded";
    emit("complete", "mcl deploy-apply", ["mcl", "deploy-apply"],
        succeeded ? "succeeded" : "failed", succeeded ? 0 : 1,
        succeeded ? "" : "Deployment did not converge",
        succeeded ? "command_failed" : "deployment_failed", "", [
            "previousGeneration": JSONValue(previous),
            "newGeneration": JSONValue(current),
            "outcome": JSONValue(outcome),
        ]);
    return succeeded ? 0 : 1;
}

@("test_deploy_apply_rejects_ssh_original_command")
unittest
{
    import std.exception : assertThrown;

    DeployApplyArgs args;
    args.target = "app-1";
    args.trustedManifestPublicKey = "ssh-ed25519 AAAATEST test";
    args.rejectSshOriginalCommand = true;

    environment["SSH_ORIGINAL_COMMAND"] = "sh";
    scope(exit) environment.remove("SSH_ORIGINAL_COMMAND");
    assertThrown!Exception(deployApplyImpl(args, DeployApplyDependencies()));
}

@("test_deploy_apply_rejects_wrong_manifest_target")
unittest
{
    import std.exception : assertThrown;
    import std.json : JSONOptions;

    auto manifestPath = deleteme ~ ".manifest.json";
    scope(exit)
    {
        if (manifestPath.exists) manifestPath.remove;
    }

    manifestPath.write(
        buildManifest(ManifestBuildRequest(
            deploymentId: "deploy-1",
            target: "app-2",
            gitRevision: "0123456789abcdef0123456789abcdef01234567",
            sequence: 1,
            desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system",
        )).toString(JSONOptions.doNotEscapeSlashes)
    );

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "app-1";
    args.trustedManifestPublicKey = "ssh-ed25519 AAAATEST test";

    assertThrown!Exception(deployApplyImpl(args, DeployApplyDependencies()));
}

@("test_deploy_apply_nix_darwin_switches_profile_and_activates")
unittest
{
    import std.algorithm : any, canFind;
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestSigningRequest, signManifest;
    import mcl.utils.deploy_state : manifestStatePath;

    auto base = deleteme ~ ".deploy-apply-darwin-success";
    auto keyPath = base ~ ".ed25519";
    auto manifestPath = base ~ ".manifest.json";
    auto stateDir = base ~ ".state";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto desired = "/nix/store/22222222222222222222222222222222-darwin-system";
    auto previous = "/nix/store/11111111111111111111111111111111-darwin-system";
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-darwin-success",
        target: "m3",
        system: "aarch64-darwin",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: desired,
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    string current = previous;
    string[][] commands;
    ProcessResult fakeRun(string[] command)
    {
        commands ~= command.dup;
        if (command == ["nix-env", "--profile", base ~ ".profile", "--set", desired])
            current = desired;
        return ProcessResult(0, "", "");
    }
    ProcessResult fakeQuery(string[] command)
    {
        if (command == ["/bin/sh", "-c", "current-generation"])
            return ProcessResult(0, current ~ "\n", "");
        return ProcessResult(0, "{}", "");
    }

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "m3";
    args.trustedManifestPublicKey = (keyPath ~ ".pub").readText.strip;
    args.stateDir = stateDir;
    args.activationMode = DeploymentActivationMode.nixDarwin;
    args.systemProfile = base ~ ".profile";
    args.generationCommand = "current-generation";
    args.restoreCommand = "restore";

    assert(deployApplyImpl(args, DeployApplyDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 0);
    assert(current == desired);
    assert(commands.canFind(["nix-env", "--profile", args.systemProfile, "--set", desired]));
    assert(commands.canFind([desired ~ "/activate"]));
    assert(!commands.any!(command => command.canFind("systemd-run")));
    assert(manifestStatePath(stateDir, "converged", "deploy-darwin-success").exists);
}

@("test_deploy_apply_nix_darwin_restores_previous_profile_on_activation_failure")
unittest
{
    import std.algorithm : canFind;
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestSigningRequest, signManifest;
    import mcl.utils.deploy_state : manifestStatePath;

    auto base = deleteme ~ ".deploy-apply-darwin-rollback";
    auto keyPath = base ~ ".ed25519";
    auto manifestPath = base ~ ".manifest.json";
    auto stateDir = base ~ ".state";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub", manifestPath])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto desired = "/nix/store/44444444444444444444444444444444-darwin-system";
    auto previous = "/nix/store/33333333333333333333333333333333-darwin-system";
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-darwin-rollback",
        target: "m3",
        system: "aarch64-darwin",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: desired,
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    string current = previous;
    string[][] commands;
    ProcessResult fakeRun(string[] command)
    {
        commands ~= command.dup;
        if (command.length >= 5 && command[0] == "nix-env")
            current = command[$ - 1];
        if (command == [desired ~ "/activate"])
            return ProcessResult(31, "", "desired activation failed");
        return ProcessResult(0, "", "");
    }
    ProcessResult fakeQuery(string[] command)
    {
        if (command == ["/bin/sh", "-c", "current-generation"])
            return ProcessResult(0, current ~ "\n", "");
        return ProcessResult(0, "{}", "");
    }

    DeployApplyArgs args;
    args.manifest = manifestPath;
    args.target = "m3";
    args.trustedManifestPublicKey = (keyPath ~ ".pub").readText.strip;
    args.stateDir = stateDir;
    args.activationMode = DeploymentActivationMode.nixDarwin;
    args.systemProfile = base ~ ".profile";
    args.generationCommand = "current-generation";
    args.restoreCommand = "restore";

    assert(deployApplyImpl(args, DeployApplyDependencies(
        runProcess: &fakeRun,
        queryProcess: &fakeQuery,
    )) == 1);
    assert(current == previous);
    assert(commands.canFind(["nix-env", "--profile", args.systemProfile, "--set", desired]));
    assert(commands.canFind([desired ~ "/activate"]));
    assert(commands.canFind(["nix-env", "--profile", args.systemProfile, "--set", previous]));
    assert(commands.canFind([previous ~ "/activate"]));
    assert(manifestStatePath(stateDir, "failed", "deploy-darwin-rollback").exists);
}

@("test_deploy_apply_post_switch_restores_resources_on_success_and_failure")
unittest
{
    import std.algorithm : all, canFind, filter;
    import std.array : array;
    import std.file : rmdirRecurse;
    import std.json : JSONOptions;
    import mcl.utils.deploy_manifest : ManifestHealthCheck, ManifestSigningRequest,
        signManifest;
    import mcl.utils.deploy_state : manifestStatePath;
    import mcl.utils.deployment_events : readDeploymentEvents;

    auto base = deleteme ~ ".deploy-apply-post-hook";
    auto keyPath = base ~ ".ed25519";
    auto scenarios = [
        "success",
        "profile-failure",
        "activation-failure",
        "health-failure-no-rollback",
        "health-rollback-profile-failure",
        "health-rollback-activation-failure",
    ];
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub"])
            if (path.exists) path.remove;
        foreach (scenario; scenarios)
        {
            foreach (suffix; [".manifest.json", ".events.jsonl"])
                if ((base ~ "." ~ scenario ~ suffix).exists)
                    (base ~ "." ~ scenario ~ suffix).remove;
            auto stateDir = base ~ "." ~ scenario ~ "-state";
            if (stateDir.exists) stateDir.rmdirRecurse;
        }
    }

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto desired = "/nix/store/66666666666666666666666666666666-darwin-system;literal";
    auto previous = "/nix/store/55555555555555555555555555555555-darwin-system previous";
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    foreach (scenario; scenarios)
    {
        auto manifestPath = base ~ "." ~ scenario ~ ".manifest.json";
        auto eventLog = base ~ "." ~ scenario ~ ".events.jsonl";
        auto stateDir = base ~ "." ~ scenario ~ "-state";
        auto failProfileSet = scenario == "profile-failure";
        auto failActivation = scenario == "activation-failure";
        auto healthFailure = scenario.startsWith("health-");
        auto failRollbackProfile = scenario == "health-rollback-profile-failure";
        auto failRollbackActivation = scenario == "health-rollback-activation-failure";
        auto automaticRollback = failRollbackProfile || failRollbackActivation;
        ManifestHealthCheck[] healthChecks;
        if (healthFailure)
            healthChecks = [ManifestHealthCheck(
                name: "forced failure",
                target: "health-command",
                timeoutSeconds: 5,
            )];
        auto deploymentId = "deploy-post-hook-" ~ scenario;
        auto manifest = signManifest(buildManifest(ManifestBuildRequest(
            deploymentId: deploymentId,
            target: "m3",
            system: "aarch64-darwin",
            gitRevision: "0123456789abcdef0123456789abcdef01234567",
            sequence: 1,
            desiredSystemPath: desired,
            healthChecks: healthChecks,
            rollbackMode: automaticRollback ? "automatic" : "manual",
            rollbackMaxAttempts: automaticRollback ? 1 : 0,
            onHealthCheckFailure: automaticRollback ? "rollback" : "mark-failed",
        )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
        manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

        string current = previous;
        string[][] commands;
        string[][] postCalls;
        ProcessResult fakeRun(string[] command)
        {
            commands ~= command.dup;
            if (command.length >= 5 && command[0] == "nix-env")
            {
                if (command[$ - 1] == desired && failProfileSet)
                    return ProcessResult(41, "", "profile update failed");
                if (command[$ - 1] == previous && failRollbackProfile)
                    return ProcessResult(51, "", "profile restoration failed");
                current = command[$ - 1];
            }
            if (command == [desired ~ "/activate"] && failActivation)
                return ProcessResult(42, "", "activation failed");
            if (command == [previous ~ "/activate"] && failRollbackActivation)
                return ProcessResult(52, "", "previous activation failed");
            if (command == ["timeout", "5", "sh", "-c", "health-command"])
                return ProcessResult(61, "", "health check failed");
            if (command.length > 0 && command[0] == "/hooks/post")
                postCalls ~= command.dup;
            return ProcessResult(0, "", "");
        }
        ProcessResult fakeQuery(string[] command)
        {
            if (command == ["/bin/sh", "-c", "current-generation"])
                return ProcessResult(0, current ~ "\n", "");
            return ProcessResult(0, "{}", "");
        }

        DeployApplyArgs args;
        args.manifest = manifestPath;
        args.target = "m3";
        args.trustedManifestPublicKey = publicKey;
        args.stateDir = stateDir;
        args.activationMode = DeploymentActivationMode.nixDarwin;
        args.systemProfile = base ~ ".profile";
        args.generationCommand = "current-generation";
        args.restoreCommand = "restore";
        args.postSwitchHook = "/hooks/post";
        args.eventLog = eventLog;

        auto expectSuccess = scenario == "success";
        assert(deployApplyImpl(args, DeployApplyDependencies(
            runProcess: &fakeRun,
            queryProcess: &fakeQuery,
        )) == (expectSuccess ? 0 : 1));
        assert(postCalls.length == 1);
        auto expectedOutcome = expectSuccess ? "succeeded"
            : healthFailure ? "healthcheck-failed" : "switch-failed";
        assert(postCalls[0] == [args.postSwitchHook, desired, previous, expectedOutcome]);
        assert(commands[$ - 1] == postCalls[0]);

        auto stateCategory = expectSuccess ? "converged" : "failed";
        auto statePath = manifestStatePath(stateDir, stateCategory, deploymentId);
        assert(statePath.exists);
        assert(statePath.readText.parseJSON["currentState"].str
            == (expectSuccess ? "succeeded" : "failed"));

        auto events = readDeploymentEvents(eventLog);
        assert(events.length > 0);
        assert(events.all!(event => event["target"]["kind"].str == "darwin"));
        auto postEvents = events.filter!(event =>
            "metadata" in event.object
            && "lifecycleStage" in event["metadata"].object
            && event["metadata"]["lifecycleStage"].str == "post-switch").array;
        assert(postEvents.length == 1);
        assert(postEvents[0]["phase"].str == "switch");
        assert(postEvents[0]["command"]["status"].str == "succeeded");
        assert(postEvents[0]["command"]["argv"].array
            .map!(arg => arg.str).array == postCalls[0]);
        assert(postEvents[0]["metadata"]["outcome"].str == expectedOutcome);
        auto completeEvents = events.filter!(event => event["phase"].str == "complete").array;
        assert(completeEvents.length == 1);
        assert(completeEvents[0]["command"]["status"].str
            == (expectSuccess ? "succeeded" : "failed"));

        auto healthEvents = events.filter!(event => event["phase"].str == "healthcheck").array;
        assert(healthEvents.length == (healthFailure ? 1 : 0));
        if (healthFailure)
            assert(healthEvents[0]["command"]["status"].str == "failed");

        auto rollbackEvents = events.filter!(event => event["phase"].str == "rollback").array;
        auto expectsActivationRollback = failActivation;
        auto expectsHealthRollback = automaticRollback;
        assert(rollbackEvents.length == (expectsActivationRollback || expectsHealthRollback ? 1 : 0));
        if (expectsActivationRollback)
            assert(rollbackEvents[0]["command"]["status"].str == "succeeded");
        if (expectsHealthRollback)
        {
            assert(rollbackEvents[0]["command"]["status"].str == "failed");
            assert(rollbackEvents[0]["command"]["exitCode"].integer
                == (failRollbackProfile ? 51 : 52));
            assert(commands.canFind([
                "nix-env", "--profile", args.systemProfile, "--set", previous,
            ]));
            assert(commands.canFind([previous ~ "/activate"]));
        }
        if (scenario == "health-failure-no-rollback")
        {
            assert(!commands.canFind([
                "nix-env", "--profile", args.systemProfile, "--set", previous,
            ]));
            assert(!commands.canFind([previous ~ "/activate"]));
        }
    }
}
