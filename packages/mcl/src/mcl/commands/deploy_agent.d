module mcl.commands.deploy_agent;

import std.algorithm : canFind, filter, map, sort;
import std.array : array, join;
import std.conv : to;
import std.exception : enforce;
import std.file : SpanMode, deleteme, dirEntries, exists, mkdir, mkdirRecurse,
    readText, remove, rmdirRecurse, tempDir, write;
import std.json : JSONOptions, JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName;
import std.stdio : writeln;
import std.string : endsWith, startsWith, strip;
import std.typecons : Nullable;
import std.uuid : randomUUID;

import argparse : Command, Description, EnvFallback, NamedArgument, Placeholder;

import mcl.commands.deploy_apply : DeployApplyArgs, DeployApplyDependencies,
    deployApplyImpl;
import mcl.utils.deploy_manifest : manifestDeploymentId, manifestDesiredSystemPath,
    manifestSequence, manifestSystem, manifestTarget, verifyManifestSignature;
import mcl.utils.deploy_state : ensureDeployStateDirs, manifestStatePath,
    safeTargetName;
import mcl.utils.deployment_events : deploymentEventLogPathFromEnv, utcTimestamp;
import mcl.utils.process : ProcessResult, ProcessRunner, runProcessCapture;

@(Command("deploy-agent")
    .Description("Target-side pull agent for signed desired-state manifests"))
struct DeployAgentArgs
{
    @(NamedArgument(["target"])
        .Placeholder("name")
        .Description("Expected deployment target name"))
    string target;

    @(NamedArgument(["manifest"])
        .Placeholder("PATH|URL")
        .Description("Signed desired-state manifest source; repeatable"))
    string[] manifests;

    @(NamedArgument(["manifest-dir"])
        .Placeholder("DIR")
        .Description("Directory containing signed desired-state manifests; repeatable"))
    string[] manifestDirs;

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

    @(NamedArgument(["max-attempts"])
        .Placeholder("N")
        .Description("Maximum apply attempts for one deployment before marking it non-retryable"))
    ulong maxAttempts = 3;

    @(NamedArgument(["fetch-timeout-seconds"])
        .Placeholder("N")
        .Description("Timeout used when fetching HTTP(S) manifest sources"))
    ulong fetchTimeoutSeconds = 30;

    @(NamedArgument(["dry-run"])
        .Description("Verify and record state, but do not restore, switch, health-check, or rollback"))
    bool dryRun;

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

    @(NamedArgument(["no-detach-switch"])
        .Description("Run switch-to-configuration in-process instead of a detached systemd-run scope. "
            ~ "Detaching is the default and prevents this agent unit from deadlocking when the switch "
            ~ "restarts mcl-deploy-agent.service; disable only in environments without systemd."))
    bool noDetachSwitch;
}

struct DeployAgentDependencies
{
    ProcessRunner fetchProcess;
    ProcessRunner runProcess;
    ProcessRunner queryProcess;
}

struct AgentCandidate
{
    string source;
    JSONValue manifest;
}

export int deploy_agent(DeployAgentArgs args)
{
    return deployAgentImpl(args, DeployAgentDependencies(
        fetchProcess: (string[] command) => runProcessCapture(command),
        runProcess: (string[] command) => runProcessCapture(command, true),
        queryProcess: (string[] command) => runProcessCapture(command),
    ));
}

string agentStatusPath(string stateDir, string target)
{
    return stateDir.buildPath("agent-status", safeTargetName(target) ~ ".json");
}

Nullable!JSONValue loadAgentStatus(string stateDir, string target)
{
    auto path = agentStatusPath(stateDir, target);
    return path.exists ? Nullable!JSONValue(path.readText.parseJSON) : Nullable!JSONValue.init;
}

ulong statusAttempts(Nullable!JSONValue status, string deploymentId)
{
    if (status.isNull || status.get.type != JSONType.object)
        return 0;
    if (auto id = "deploymentId" in status.get.object)
        if (id.str != deploymentId)
            return 0;
    if (auto attempts = "attempts" in status.get.object)
        return attempts.integer.to!ulong;
    return 0;
}

JSONValue writeAgentStatus(
    string stateDir,
    string target,
    string deploymentId,
    ulong sequence,
    string state,
    ulong attempts,
    ulong maxAttempts,
    bool retryable,
    string message,
    string errorCode = "",
    string observedTarget = "",
)
{
    ensureDeployStateDirs(stateDir);
    JSONValue[string] status = [
        "target": JSONValue(target),
        "deploymentId": JSONValue(deploymentId),
        "sequence": JSONValue(cast(long) sequence),
        "currentState": JSONValue(state),
        "attempts": JSONValue(cast(long) attempts),
        "maxAttempts": JSONValue(cast(long) maxAttempts),
        "retryable": JSONValue(retryable),
        "updatedAt": JSONValue(utcTimestamp()),
        "message": JSONValue(message),
    ];
    if (errorCode != "")
        status["errorCode"] = JSONValue(errorCode);
    if (observedTarget != "")
        status["observedTarget"] = JSONValue(observedTarget);

    auto path = agentStatusPath(stateDir, target);
    if (path.dirName != "" && !path.dirName.exists)
        path.dirName.mkdirRecurse;
    path.write(JSONValue(status).toString(JSONOptions.doNotEscapeSlashes));
    return JSONValue(status);
}

bool isUrlSource(string source)
{
    return source.startsWith("https://") || source.startsWith("http://");
}

bool isMissingHttpManifest(ProcessResult result)
{
    return result.exitCode == 22 && result.stderr.canFind("404");
}

Nullable!string readManifestSource(string source, ulong timeoutSeconds, ProcessRunner fetchRunner)
{
    if (!isUrlSource(source))
        return Nullable!string(source.readText);

    ProcessResult defaultFetch(string[] command) { return runProcessCapture(command); }
    auto runner = fetchRunner is null ? &defaultFetch : fetchRunner;
    auto result = runner([
        "curl",
        "-fsSL",
        "--connect-timeout",
        timeoutSeconds.to!string,
        "--max-time",
        timeoutSeconds.to!string,
        source,
    ]);
    if (!result.succeeded && isMissingHttpManifest(result))
        return Nullable!string.init;
    enforce(result.succeeded, "Manifest fetch failed for " ~ source ~ ": " ~ result.stderr.strip);
    return Nullable!string(result.stdout);
}

string[] manifestSources(DeployAgentArgs args)
{
    string[] sources = args.manifests;
    foreach (dir; args.manifestDirs)
    {
        enforce(dir.exists, "Manifest directory does not exist: " ~ dir);
        auto paths = dirEntries(dir, SpanMode.shallow)
            .filter!(entry => entry.isFile && entry.name.endsWith(".json"))
            .map!(entry => entry.name)
            .array
            .sort
            .array;
        sources ~= paths;
    }
    return sources;
}

AgentCandidate[] loadAgentCandidates(DeployAgentArgs args, ProcessRunner fetchRunner)
{
    AgentCandidate[] candidates;
    foreach (source; manifestSources(args))
    {
        auto content = readManifestSource(source, args.fetchTimeoutSeconds, fetchRunner);
        if (content.isNull)
            continue;
        candidates ~= AgentCandidate(
            source: source,
            manifest: content.get.parseJSON,
        );
    }
    return candidates;
}

AgentCandidate latestCandidate(AgentCandidate[] candidates)
{
    enforce(candidates.length > 0, "No desired-state manifests found.");
    auto sorted = candidates
        .sort!((a, b) => manifestSequence(a.manifest) < manifestSequence(b.manifest))
        .array;
    auto latest = sorted[$ - 1];
    foreach (candidate; sorted)
    {
        if (
            manifestSequence(candidate.manifest) == manifestSequence(latest.manifest)
            && manifestDeploymentId(candidate.manifest) != manifestDeploymentId(latest.manifest)
        )
            throw new Exception(
                "Ambiguous desired state: multiple deployments share sequence "
                ~ manifestSequence(latest.manifest).to!string
            );
    }
    return latest;
}

bool isConverged(string stateDir, JSONValue manifest)
{
    return manifestStatePath(stateDir, "converged", manifestDeploymentId(manifest)).exists;
}

int deployAgentImpl(DeployAgentArgs args, DeployAgentDependencies deps)
{
    enforce(args.target != "", "--target is required.");
    enforce(args.trustedManifestPublicKey != "" || args.allowedSigners != "",
        "--trusted-manifest-public-key or --allowed-signers is required.");
    enforce(args.maxAttempts > 0, "--max-attempts must be greater than zero.");
    enforce(args.manifests.length > 0 || args.manifestDirs.length > 0,
        "At least one --manifest or --manifest-dir source is required.");

    auto eventLogPath = args.eventLog != "" ? args.eventLog : deploymentEventLogPathFromEnv();

    AgentCandidate[] candidates;
    try
    {
        candidates = loadAgentCandidates(args, deps.fetchProcess);
    }
    catch (Exception e)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, "", 0, "failed", 0,
            args.maxAttempts, true, e.msg, "source_read_failed");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    if (candidates.length == 0)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, "", 0, "waiting", 0,
            args.maxAttempts, true, "No desired-state manifests found.");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 0;
    }

    foreach (candidate; candidates)
    {
        auto observedTarget = manifestTarget(candidate.manifest);
        if (observedTarget != args.target)
        {
            auto status = writeAgentStatus(args.stateDir, args.target,
                manifestDeploymentId(candidate.manifest), manifestSequence(candidate.manifest),
                "non-retryable", 0, args.maxAttempts, false,
                "Manifest target does not match this agent target.", "wrong_target", observedTarget);
            writeln(status.toString(JSONOptions.doNotEscapeSlashes));
            return 1;
        }

        if (!candidate.manifest.verifyManifestSignature(args.trustedManifestPublicKey, args.allowedSigners))
        {
            auto status = writeAgentStatus(args.stateDir, args.target,
                manifestDeploymentId(candidate.manifest), manifestSequence(candidate.manifest),
                "non-retryable", 0, args.maxAttempts, false,
                "Manifest signature verification failed.", "invalid_signature");
            writeln(status.toString(JSONOptions.doNotEscapeSlashes));
            return 1;
        }
    }

    AgentCandidate selected;
    try
    {
        selected = latestCandidate(candidates);
    }
    catch (Exception e)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, "", 0, "non-retryable", 0,
            args.maxAttempts, false, e.msg, "ambiguous_sequence");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    auto manifest = selected.manifest;
    auto deploymentId = manifestDeploymentId(manifest);
    auto sequence = manifestSequence(manifest);
    auto previousStatus = loadAgentStatus(args.stateDir, args.target);
    auto previousAttempts = statusAttempts(previousStatus, deploymentId);

    if (isConverged(args.stateDir, manifest))
    {
        auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
            "succeeded", previousAttempts, args.maxAttempts, false,
            "Deployment already converged.");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 0;
    }

    if (previousAttempts >= args.maxAttempts)
    {
        auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
            "non-retryable", previousAttempts, args.maxAttempts, false,
            "Retry budget exhausted for this deployment.", "retry_budget_exhausted");
        writeln(status.toString(JSONOptions.doNotEscapeSlashes));
        return 1;
    }

    auto temp = tempDir.buildPath("mcl-deploy-agent-" ~ randomUUID.toString);
    temp.mkdir;
    auto manifestPath = temp.buildPath("manifest.json");
    scope(exit) if (temp.exists) temp.rmdirRecurse;
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    DeployApplyArgs applyArgs;
    applyArgs.manifest = manifestPath;
    applyArgs.target = args.target;
    applyArgs.trustedManifestPublicKey = args.trustedManifestPublicKey;
    applyArgs.allowedSigners = args.allowedSigners;
    applyArgs.stateDir = args.stateDir;
    applyArgs.eventLog = eventLogPath;
    applyArgs.dryRun = args.dryRun;
    applyArgs.restoreCommand = args.restoreCommand;
    applyArgs.switchCommand = args.switchCommand;
    applyArgs.rollbackCommand = args.rollbackCommand;
    applyArgs.generationCommand = args.generationCommand;
    applyArgs.noDetachSwitch = args.noDetachSwitch;
    applyArgs.transport = "pull-agent";
    applyArgs.controller = "mcl-deploy-agent";

    auto result = deployApplyImpl(applyArgs, DeployApplyDependencies(
        runProcess: deps.runProcess,
        queryProcess: deps.queryProcess,
    ));

    auto attempts = previousAttempts + 1;
    auto succeeded = result == 0;
    auto exhausted = !succeeded && attempts >= args.maxAttempts;
    auto status = writeAgentStatus(args.stateDir, args.target, deploymentId, sequence,
        succeeded ? "succeeded" : exhausted ? "non-retryable" : "failed",
        attempts,
        args.maxAttempts,
        !succeeded && !exhausted,
        succeeded ? "Deployment converged."
            : exhausted ? "Retry budget exhausted for this deployment."
            : "Deployment apply failed; retry remains available.",
        succeeded ? "" : exhausted ? "retry_budget_exhausted" : "apply_failed");
    writeln(status.toString(JSONOptions.doNotEscapeSlashes));
    return result;
}

@("test_deploy_agent_filters_to_latest_signed_target")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = deleteme ~ ".deploy-agent-latest";
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestDir = base ~ ".manifests";
    scope(exit)
    {
        foreach (path; [base, keyPath, keyPath ~ ".pub"])
            if (path.exists) path.remove;
        if (stateDir.exists) stateDir.rmdirRecurse;
        if (manifestDir.exists) manifestDir.rmdirRecurse;
    }
    manifestDir.mkdirRecurse;

    auto keygen = runProcessCapture([
        "ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", keyPath,
    ]);
    assert(keygen.succeeded, keygen.stderr);
    auto publicKey = (keyPath ~ ".pub").readText.strip;

    auto oldManifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-41",
        target: "target",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 41,
        desiredSystemPath: "/nix/store/11111111111111111111111111111111-system-old",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    auto newManifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42",
        target: "target",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/22222222222222222222222222222222-system-new",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestDir.buildPath("old.json").write(oldManifest.toString(JSONOptions.doNotEscapeSlashes));
    manifestDir.buildPath("new.json").write(newManifest.toString(JSONOptions.doNotEscapeSlashes));

    DeployAgentArgs args;
    args.target = "target";
    args.manifestDirs = [manifestDir];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.dryRun = true;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        queryProcess: (string[] command) => ProcessResult(0, "{}", ""),
    )) == 0);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["deploymentId"].str == "deploy-42");
    assert(status["sequence"].integer == 42);
    assert(status["currentState"].str == "succeeded");
    assert(manifestStatePath(stateDir, "converged", "deploy-42").exists);
    assert(!manifestStatePath(stateDir, "converged", "deploy-41").exists);
}

@("test_deploy_agent_rejects_wrong_target")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = deleteme ~ ".deploy-agent-wrong-target";
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
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
    auto publicKey = (keyPath ~ ".pub").readText.strip;
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-1",
        target: "other-target",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/11111111111111111111111111111111-system",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        queryProcess: (string[] command) => ProcessResult(0, "{}", ""),
    )) == 1);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["currentState"].str == "non-retryable");
    assert(status["errorCode"].str == "wrong_target");
    assert(status["observedTarget"].str == "other-target");
}

@("test_deploy_agent_waits_when_http_manifest_is_missing")
unittest
{
    auto stateDir = deleteme ~ ".deploy-agent-missing-http.state";
    scope(exit) if (stateDir.exists) stateDir.rmdirRecurse;

    ProcessResult missingFetch(string[] command)
    {
        assert(command.canFind("curl"));
        return ProcessResult(22, "", "curl: (22) The requested URL returned error: 404");
    }

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = ["https://cache.example.test/mcl-deployments/target/latest.json"];
    args.trustedManifestPublicKey = "ssh-ed25519 test-key";
    args.stateDir = stateDir;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        fetchProcess: &missingFetch,
    )) == 0);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["target"].str == "target");
    assert(status["currentState"].str == "waiting");
    assert(status["retryable"].boolean is true);
    assert(status["message"].str == "No desired-state manifests found.");
    assert(("errorCode" in status.object) is null);
}

@("test_deploy_agent_fails_on_non_missing_http_fetch_error")
unittest
{
    auto stateDir = deleteme ~ ".deploy-agent-http-error.state";
    scope(exit) if (stateDir.exists) stateDir.rmdirRecurse;

    ProcessResult failingFetch(string[] command)
    {
        assert(command.canFind("curl"));
        return ProcessResult(22, "", "curl: (22) The requested URL returned error: 503");
    }

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = ["https://cache.example.test/mcl-deployments/target/latest.json"];
    args.trustedManifestPublicKey = "ssh-ed25519 test-key";
    args.stateDir = stateDir;

    assert(deployAgentImpl(args, DeployAgentDependencies(
        fetchProcess: &failingFetch,
    )) == 1);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["target"].str == "target");
    assert(status["currentState"].str == "failed");
    assert(status["retryable"].boolean is true);
    assert(status["errorCode"].str == "source_read_failed");
}

@("test_deploy_agent_bounds_failed_apply_retries")
unittest
{
    import mcl.utils.deploy_manifest : ManifestBuildRequest, ManifestSigningRequest,
        buildManifest, signManifest;

    auto base = deleteme ~ ".deploy-agent-retry";
    auto keyPath = base ~ ".ed25519";
    auto stateDir = base ~ ".state";
    auto manifestPath = base ~ ".manifest.json";
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
    auto publicKey = (keyPath ~ ".pub").readText.strip;
    auto manifest = signManifest(buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-1",
        target: "target",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/11111111111111111111111111111111-system",
    )), ManifestSigningRequest(keyPath: keyPath, keyId: "mcl-deployment"));
    manifestPath.write(manifest.toString(JSONOptions.doNotEscapeSlashes));

    uint restoreRuns;
    ProcessResult fakeRun(string[] command)
    {
        if (command.canFind("false"))
            restoreRuns++;
        return ProcessResult(1, "", "restore failed");
    }

    DeployAgentArgs args;
    args.target = "target";
    args.manifests = [manifestPath];
    args.trustedManifestPublicKey = publicKey;
    args.stateDir = stateDir;
    args.maxAttempts = 2;
    args.restoreCommand = "false";

    foreach (i; 0 .. 3)
        assert(deployAgentImpl(args, DeployAgentDependencies(
            runProcess: &fakeRun,
            queryProcess: (string[] command) => ProcessResult(0, "{}", ""),
        )) == 1);

    auto status = agentStatusPath(stateDir, "target").readText.parseJSON;
    assert(status["currentState"].str == "non-retryable");
    assert(status["attempts"].integer == 2);
    assert(status["errorCode"].str == "retry_budget_exhausted");
    assert(restoreRuns == 2);
}
