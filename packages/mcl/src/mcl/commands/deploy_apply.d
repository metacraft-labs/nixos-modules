module mcl.commands.deploy_apply;

import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.file : deleteme, exists, readText, remove, write;
import std.json : JSONValue, parseJSON;
import std.process : environment;
import std.stdio : stdin;
import std.string : strip;
import std.typecons : Nullable;

import argparse : Command, Description, EnvFallback, NamedArgument, Placeholder;

import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest,
    manifestDeploymentId, manifestDesiredSystemPath, manifestSequence, manifestSystem,
    manifestTarget, verifyManifestSignature;
import mcl.utils.deploy_state : markDeploymentState, recordDesiredManifest;
import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, deploymentEventLogPathFromEnv,
    queryClosureSummary, stderrSummary;
import mcl.utils.process : ProcessResult, ProcessRunner, runProcessCapture;

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
        .Description("Command that prints the current system generation path")
        .EnvFallback("MCL_DEPLOY_GENERATION_COMMAND"))
    string generationCommand = "readlink -f /run/current-system";
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
    return runner(["sh", "-c", command]);
}

int deployApplyImpl(DeployApplyArgs args, DeployApplyDependencies deps)
{
    import std.json : JSONOptions;

    enforce(args.target != "", "--target is required.");
    enforce(args.trustedManifestPublicKey != "" || args.allowedSigners != "",
        "--trusted-manifest-public-key or --allowed-signers is required.");

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
        kind: "server",
        transport: "ssh",
        controller: "mcl-reconciler",
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

    auto previous = shell(queryRunner, args.generationCommand).stdout.strip;
    auto switchCommand = args.switchCommand == ""
        ? manifestDesiredSystemPath(manifest) ~ "/bin/switch-to-configuration switch"
        : args.switchCommand;
    auto switched = shell(runner, switchCommand);
    auto current = shell(queryRunner, args.generationCommand).stdout.strip;
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
    if (!switched.succeeded)
    {
        markDeploymentState(args.stateDir, manifest, "failed", "System switch failed.");
        return 1;
    }

    bool healthOk = true;
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

    if (!healthOk)
    {
        if (automaticRollbackRequested(manifest) && previous != "")
        {
            auto rollbackCommand = args.rollbackCommand == ""
                ? previous ~ "/bin/switch-to-configuration switch"
                : args.rollbackCommand;
            auto rollback = shell(runner, rollbackCommand);
            emit("rollback", "switch-to-configuration rollback", ["sh", "-c", rollbackCommand],
                rollback.succeeded ? "succeeded" : "failed",
                rollback.exitCode,
                rollback.succeeded ? "" : "Automatic rollback failed",
                "rollback_failed",
                rollback.succeeded ? "" : rollback.stderr.stderrSummary,
                [
                    "previousGeneration": JSONValue(previous),
                    "failedGeneration": JSONValue(current),
                ]);
            markDeploymentState(args.stateDir, manifest,
                rollback.succeeded ? "rolled-back" : "failed",
                rollback.succeeded ? "Health check failed; rolled back." : "Health check and rollback failed.");
        }
        else
        {
            markDeploymentState(args.stateDir, manifest, "failed", "Health check failed.");
        }
        emit("complete", "mcl deploy-apply", ["mcl", "deploy-apply"], "failed", 1,
            "Deployment did not converge", "deployment_failed");
        return 1;
    }

    markDeploymentState(args.stateDir, manifest, "succeeded", "Deployment converged.");
    emit("complete", "mcl deploy-apply", ["mcl", "deploy-apply"], "succeeded", 0,
        "", "command_failed", "", [
            "previousGeneration": JSONValue(previous),
            "newGeneration": JSONValue(current),
        ]);
    return 0;
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
