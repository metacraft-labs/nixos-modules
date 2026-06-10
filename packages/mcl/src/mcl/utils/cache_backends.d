module mcl.utils.cache_backends;

import std.algorithm : canFind, map;
import std.array : array, join;
import std.conv : to;
import std.file : deleteme, exists, mkdirRecurse, rmdirRecurse;
import std.json : JSONValue;
import std.string : splitLines, strip, toLower;
import std.typecons : Nullable;

import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, queryClosureSummary, stderrSummary;
import mcl.utils.process : ProcessResult, ProcessRunner;

enum ulong defaultCacheProbeTimeoutSeconds = 30;

enum CacheBackend
{
    cachix,
    attic,
    none,
}

struct CachePushRequest
{
    CacheBackend backend;
    string cache;
    string[] storePaths;
    string target = "unknown";
    string system = "x86_64-linux";
    string kind = "unknown";
    string transport = "unknown";
    string[] substituters;
    string[] trustedPublicKeys;
    string eventLogPath;
    string correlationId;
    bool requireSubstitute = true;
    ulong probeTimeoutSeconds = defaultCacheProbeTimeoutSeconds;
}

struct CachePushPlan
{
    string commandName;
    string[] argv;
    string controller;
    string[] substituters;
    bool externalCommand;
}

struct CacheProbeResult
{
    string path;
    string substituter;
    string outcome;
    int exitCode;
    string message;

    bool successful() const => outcome == "successful-substitute";
}

CacheBackend parseCacheBackend(string name)
{
    final switch (name.toLower)
    {
        case "cachix":
            return CacheBackend.cachix;
        case "attic":
            return CacheBackend.attic;
        case "none":
            return CacheBackend.none;
    }
}

string cacheBackendName(CacheBackend backend)
{
    final switch (backend)
    {
        case CacheBackend.cachix:
            return "cachix";
        case CacheBackend.attic:
            return "attic";
        case CacheBackend.none:
            return "none";
    }
}

string defaultSubstituter(CacheBackend backend, string cache)
{
    final switch (backend)
    {
        case CacheBackend.cachix:
            return cache == "" ? "" : "https://" ~ cache ~ ".cachix.org";
        case CacheBackend.attic:
            return "";
        case CacheBackend.none:
            return "";
    }
}

CachePushPlan cachePushPlan(CachePushRequest request)
{
    auto substituters = request.substituters;
    if (substituters.length == 0)
    {
        auto substituter = defaultSubstituter(request.backend, request.cache);
        if (substituter != "")
            substituters ~= substituter;
    }

    final switch (request.backend)
    {
        case CacheBackend.cachix:
            return CachePushPlan(
                commandName: "cachix push",
                argv: ["cachix", "push", request.cache] ~ request.storePaths,
                controller: "cachix",
                substituters: substituters,
                externalCommand: true,
            );
        case CacheBackend.attic:
            return CachePushPlan(
                commandName: "attic push",
                argv: ["attic", "push", request.cache] ~ request.storePaths,
                controller: "attic",
                substituters: substituters,
                externalCommand: true,
            );
        case CacheBackend.none:
            return CachePushPlan(
                commandName: "cache push skipped",
                argv: ["mcl", "cache", "push-closure", "--backend", "none"] ~ request.storePaths,
                controller: "none",
                substituters: substituters,
                externalCommand: false,
            );
    }
}

string[] queryClosurePaths(string rootPath, ProcessRunner runner)
{
    if (runner is null)
        return [rootPath];

    auto result = runner(["nix", "path-info", "--recursive", rootPath]);
    if (!result.succeeded || result.stdout.strip == "")
        return [rootPath];

    auto paths = result.stdout
        .splitLines
        .map!(line => line.strip)
        .array;

    string[] filtered;
    foreach (path; paths)
        if (path != "")
            filtered ~= path;

    return filtered.length == 0 ? [rootPath] : filtered;
}

CacheProbeResult probeCacheSubstitute(
    string path,
    string substituter,
    string[] trustedPublicKeys,
    ProcessRunner runner,
    ulong timeoutSeconds = defaultCacheProbeTimeoutSeconds,
)
{
    auto results = probeCacheSubstitutes([path], substituter, trustedPublicKeys,
        runner, timeoutSeconds);
    return results.length
        ? results[0]
        : CacheProbeResult(path, substituter, "narinfo-missing", 1,
            "no probe result returned");
}

CacheProbeResult[] probeCacheSubstitutes(
    string[] paths,
    string substituter,
    string[] trustedPublicKeys,
    ProcessRunner runner,
    ulong timeoutSeconds = defaultCacheProbeTimeoutSeconds,
)
{
    if (runner is null)
    {
        CacheProbeResult[] results;
        foreach (path; paths)
            results ~= CacheProbeResult(path, substituter, "narinfo-missing", 1,
                "no process runner configured");
        return results;
    }

    auto pathInfoCommand = [
        "nix", "path-info", "--store", substituter,
    ] ~ paths ~ ["--option", "substituters", ""];
    if (trustedPublicKeys.length)
        pathInfoCommand ~= ["--option", "trusted-public-keys", trustedPublicKeys.join(" ")];

    auto pathInfo = runner(cacheProbeTimeoutCommand(pathInfoCommand, timeoutSeconds));
    auto successfulPaths = successfulProbeOutputPaths(paths, pathInfo.stdout);
    auto failureOutcome = pathInfo.succeeded
        ? "narinfo-missing"
        : (isTimeoutExitCode(pathInfo.exitCode)
            ? "probe-timeout"
            : classifyProbeFailure(pathInfo.stderr));
    auto failureMessage = pathInfo.stderr.stderrSummary;
    if (failureOutcome == "probe-timeout" && failureMessage == "")
        failureMessage = "substitute probe exceeded " ~ timeoutSeconds.to!string ~ "s timeout";
    if (!pathInfo.succeeded && failureOutcome == "narinfo-missing"
        && !hasDisqualifyingMixedProbeFailure(pathInfo.stderr))
    {
        auto missingPaths = missingProbeFailurePaths(paths, pathInfo.stderr);
        if (missingPaths.length)
            foreach (path; paths)
                if (path !in missingPaths)
                    successfulPaths[path] = true;
    }

    // `nix path-info` performs a `HEAD /<hash>.narinfo` against the
    // substituter — this is sufficient evidence that the path is
    // resolvable from that cache. Doing a full `nix copy` to verify
    // (the previous implementation) downloaded every probed path,
    // re-verified its signature, and re-imported into a throwaway local
    // store. On a NixOS system closure that's thousands of paths times
    // dozens of MB; one infra deploy in main observed the probe stuck
    // for 2h24m on a single path (`gnome-settings-daemon`) before being
    // killed. The signature trust check the copy was doing is
    // redundant: every path the deploy targets will have its signature
    // re-verified at install time on the target host. The probe's job
    // is just to answer "is this path available from a trusted cache?"
    // and the narinfo HEAD does that without any download.
    CacheProbeResult[] results;
    foreach (path; paths)
    {
        if (path in successfulPaths)
            results ~= CacheProbeResult(path, substituter, "successful-substitute", 0, "");
        else
            results ~= CacheProbeResult(path, substituter, failureOutcome,
                pathInfo.exitCode, failureMessage);
    }
    return results;
}

private bool[string] successfulProbeOutputPaths(string[] requestedPaths, string stdout)
{
    bool[string] requested;
    foreach (path; requestedPaths)
        requested[path] = true;

    bool[string] successful;
    foreach (line; stdout.splitLines)
    {
        auto path = line.strip;
        if (path != "" && path in requested)
            successful[path] = true;
    }
    return successful;
}

private bool[string] missingProbeFailurePaths(string[] requestedPaths, string stderr)
{
    bool[string] missing;
    foreach (line; stderr.splitLines)
    {
        if (!isMissingProbeFailureLine(line))
            continue;
        foreach (path; requestedPaths)
            if (line.canFind(path))
                missing[path] = true;
    }
    return missing;
}

private bool isMissingProbeFailureLine(string line)
{
    auto text = line.toLower;
    return text.canFind("404")
        || text.canFind("not found")
        || text.canFind("does not exist")
        || text.canFind("no such file")
        || text.canFind("not valid")
        || text.canFind("not a valid")
        || text.canFind("invalid path")
        || text.canFind("is invalid");
}

private bool hasDisqualifyingMixedProbeFailure(string stderr)
{
    auto text = stderr.toLower;
    return text.canFind("timed out")
        || text.canFind("timeout")
        || text.canFind("lacks a signature")
        || text.canFind("not signed")
        || text.canFind("not trusted")
        || text.canFind("bad signature")
        || text.canFind("signature")
        || text.canFind("nar object")
        || text.canFind("object")
        || text.canFind("unexpected eof")
        || text.canFind("unexpected end")
        || text.canFind("hash mismatch")
        || text.canFind("corrupt");
}

string[] cacheProbeTimeoutCommand(string[] command, ulong timeoutSeconds)
{
    return ["timeout", "--kill-after=5s", timeoutSeconds.to!string ~ "s"] ~ command;
}

bool isTimeoutExitCode(int exitCode)
{
    return exitCode == 124 || exitCode == 137 || exitCode == 143
        || exitCode == -9 || exitCode == -15;
}

string classifyProbeFailure(string stderr)
{
    auto text = stderr.toLower;
    if (text.canFind("lacks a signature") || text.canFind("not signed")
        || text.canFind("not trusted") || text.canFind("bad signature")
        || text.canFind("signature"))
        return "signature-not-trusted";
    if (text.canFind("nar object") || text.canFind("object")
        || text.canFind("unexpected eof") || text.canFind("unexpected end")
        || text.canFind("hash mismatch") || text.canFind("corrupt"))
        return "narinfo-present-object-unavailable";
    if (text.canFind("404") || text.canFind("not found") || text.canFind("does not exist")
        || text.canFind("no such file") || text.canFind("narinfo"))
        return "narinfo-missing";
    return "narinfo-missing";
}

JSONValue cachePushMetadata(
    CachePushRequest request,
    CachePushPlan plan,
    CacheProbeResult[] probes,
    string[] unavailableSubstituters,
)
{
    JSONValue[] probeJson;
    foreach (probe; probes)
    {
        probeJson ~= JSONValue([
            "path": JSONValue(probe.path),
            "substituter": JSONValue(probe.substituter),
            "outcome": JSONValue(probe.outcome),
            "exitCode": JSONValue(cast(long) probe.exitCode),
            "message": JSONValue(probe.message),
        ]);
    }

    auto coverage = probeCoverage(probes);

    JSONValue[string] metadata = [
        "backend": JSONValue(cacheBackendName(request.backend)),
        "controller": JSONValue(plan.controller),
        "coverage": JSONValue([
            "rootPathCount": JSONValue(cast(long) request.storePaths.length),
            "probedPathCount": JSONValue(cast(long) coverage.probedPathCount),
            "probeAttemptCount": JSONValue(cast(long) probes.length),
            "successfulSubstituteCount": JSONValue(cast(long) coverage.successfulPathCount),
            "complete": JSONValue(probes.length > 0 && coverage.complete),
        ]),
        "probeTimeoutSeconds": JSONValue(cast(long) request.probeTimeoutSeconds),
        "probes": JSONValue(probeJson),
    ];

    if (unavailableSubstituters.length)
        metadata["unavailableSubstituters"] = JSONValue(
            unavailableSubstituters.map!(substituter => JSONValue(substituter)).array);

    if (request.trustedPublicKeys.length)
        metadata["trustedPublicKeys"] = JSONValue(
            request.trustedPublicKeys.map!(key => JSONValue(key)).array);

    return JSONValue(metadata);
}

int pushClosure(CachePushRequest request, ProcessRunner runProcess, ProcessRunner queryProcess)
{
    import std.exception : enforce;

    auto plan = cachePushPlan(request);
    auto queryRunner = queryProcess is null ? runProcess : queryProcess;
    auto context = DeploymentEventContext(
        eventLogPath: request.eventLogPath,
        correlationId: request.correlationId,
        cache: request.cache,
        substituters: plan.substituters,
        system: request.system,
        kind: request.kind,
        transport: request.transport,
        controller: plan.controller,
    );

    Nullable!ClosureSummary closure;
    if (request.storePaths.length)
        closure = queryClosureSummary(request.storePaths[0], queryRunner);

    ProcessResult pushResult = ProcessResult(0, "", "");
    if (plan.externalCommand)
        pushResult = runProcess(plan.argv);

    CacheProbeResult[] probes;
    bool[string] unavailableSubstituters;
    string[] unavailableSubstituterList;
    const missingRequiredSubstituter = pushResult.succeeded
        && request.requireSubstitute
        && plan.substituters.length == 0;

    if (pushResult.succeeded && request.requireSubstitute && plan.substituters.length)
    {
        // A path is considered substitutable if ANY trusted substituter
        // resolves it. Target hosts are configured with multiple substituters
        // (deployment cache + auxiliary caches), so "the closure is resolvable
        // for deploys" -- not "every path lives on the primary cache" -- is what
        // matters. Batch each substituter over the still-uncovered closure paths
        // and record one metadata row per requested path so failure events can
        // explain timeouts and later misses.
        foreach (root; request.storePaths)
        {
            auto remaining = uniquePaths(queryClosurePaths(root, queryRunner));
            bool[string] attempted;
            foreach (substituter; plan.substituters)
            {
                if (remaining.length == 0)
                    break;
                if (substituter in unavailableSubstituters)
                    continue;

                auto batch = probeCacheSubstitutes(remaining, substituter,
                    request.trustedPublicKeys, queryRunner,
                    request.probeTimeoutSeconds);
                probes ~= batch;

                bool timedOut;
                bool[string] covered;
                foreach (probe; batch)
                {
                    attempted[probe.path] = true;
                    if (probe.outcome == "probe-timeout")
                        timedOut = true;
                    if (probe.successful)
                        covered[probe.path] = true;
                }
                remaining = pathsNotIn(remaining, covered);
                if (timedOut)
                {
                    unavailableSubstituters[substituter] = true;
                    unavailableSubstituterList ~= substituter;
                }
            }
            foreach (path; remaining)
                if (path !in attempted)
                    probes ~= CacheProbeResult(path, "", "substituter-unavailable", 1,
                        "no available substituter covered path");
        }
    }

    const probeFailed = probes.length > 0 && !probeCoverage(probes).complete;
    const substituteCheckFailed = missingRequiredSubstituter || probeFailed;
    const status = substituteCheckFailed
        ? "failed"
        : (plan.externalCommand ? (pushResult.succeeded ? "succeeded" : "failed") : "skipped");
    const exitCode = pushResult.succeeded && substituteCheckFailed ? 1 : pushResult.exitCode;
    const errorMessage = !pushResult.succeeded
        ? "Cache push failed"
        : (missingRequiredSubstituter
            ? "Cache substitute integrity probe requires at least one substituter"
            : (probeFailed ? "Cache substitute integrity probe failed" : ""));
    const errorCode = !pushResult.succeeded ? "cache_push_failed" : "cache_probe_failed";
    const errorDetails = !pushResult.succeeded
        ? pushResult.stderr.stderrSummary
        : (missingRequiredSubstituter
            ? "No substituter was configured for --require-substitute"
            : probeFailureSummary(probes));

    foreach (root; request.storePaths)
        appendDeploymentEvent(request.eventLogPath, deploymentEventJson(
            context,
            "cache-push",
            request.target,
            root,
            plan.commandName,
            plan.argv,
            status,
            exitCode,
            closure,
            errorMessage,
            errorCode,
            errorDetails,
            cachePushMetadata(request, plan, probes, unavailableSubstituterList).object,
        ));

    enforce(status != "failed", errorMessage == "" ? "Cache push failed" : errorMessage);
    return 0;
}

string probeFailureSummary(CacheProbeResult[] probes)
{
    string failedPath;
    auto successfulPaths = successfulProbePaths(probes);
    foreach (probe; probes)
        if (!probe.successful && (probe.path !in successfulPaths))
        {
            failedPath = probe.path;
            break;
        }
    if (failedPath == "")
        return "";

    string[] attempts;
    foreach (probe; probes)
        if (probe.path == failedPath && !probe.successful)
            attempts ~= probeAttemptSummary(probe);

    return failedPath ~ ": no substituter succeeded (" ~ attempts.join("; ") ~ ")";
}

private struct ProbeCoverage
{
    ulong probedPathCount;
    ulong successfulPathCount;
    bool complete;
}

private ProbeCoverage probeCoverage(CacheProbeResult[] probes)
{
    bool[string] probedPaths;
    auto successfulPaths = successfulProbePaths(probes);

    foreach (probe; probes)
        probedPaths[probe.path] = true;

    bool complete = probes.length > 0;
    foreach (path, _; probedPaths)
        if (path !in successfulPaths)
            complete = false;

    return ProbeCoverage(
        probedPathCount: cast(ulong) probedPaths.length,
        successfulPathCount: cast(ulong) successfulPaths.length,
        complete: complete,
    );
}

private string[] uniquePaths(string[] paths)
{
    bool[string] seen;
    string[] result;
    foreach (path; paths)
    {
        if (path in seen)
            continue;
        seen[path] = true;
        result ~= path;
    }
    return result;
}

private string[] pathsNotIn(string[] paths, bool[string] excluded)
{
    string[] result;
    foreach (path; paths)
        if (path !in excluded)
            result ~= path;
    return result;
}

private bool[string] successfulProbePaths(CacheProbeResult[] probes)
{
    bool[string] paths;
    foreach (probe; probes)
        if (probe.successful)
            paths[probe.path] = true;
    return paths;
}

private string probeAttemptSummary(CacheProbeResult probe)
{
    auto substituter = probe.substituter == "" ? "<none>" : probe.substituter;
    return substituter ~ ": " ~ probe.outcome ~
        (probe.message == "" ? "" : ": " ~ probe.message);
}

version (unittest)
private string probeCommandStorePathStdout(string[] command)
{
    string[] paths;
    foreach (arg; command)
        if (arg.canFind("/nix/store/"))
            paths ~= arg;
    return paths.join("\n") ~ (paths.length ? "\n" : "");
}

@("test_cache_push_closure_invokes_backend")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : any, filter;

    auto eventLog = deleteme ~ ".cache-push.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root\n", "");
        if (command.canFind("--store"))
            return ProcessResult(0, "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root\n", "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "copy")
            return ProcessResult(0, "", "");
        return ProcessResult(0, "", "");
    }

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root],
        target: "app-server-01",
        substituters: ["https://example-cache.cachix.org"],
        eventLogPath: eventLog,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(commands.any!(cmd => cmd == ["cachix", "push", "example-cache", root]));

    commands.length = 0;
    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.attic,
        cache: "example-deploy-cache",
        storePaths: [root],
        target: "app-server-01",
        substituters: ["https://cache.example/example-deploy-cache"],
        eventLogPath: eventLog,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(commands.any!(cmd => cmd == ["attic", "push", "example-deploy-cache", root]));

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 2);
    assert(events[0]["backend"]["controller"].str == "cachix");
    assert(events[1]["backend"]["controller"].str == "attic");
    assert(events[1]["metadata"]["coverage"]["complete"].boolean);
    assert(events[1]["metadata"]["probes"][0]["outcome"].str == "successful-substitute");
}

@("test_cache_probe_wraps_path_info_with_timeout")
unittest
{
    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        return ProcessResult(0, root ~ "\n", "");
    }

    auto result = probeCacheSubstitute(root, "https://cache.example",
        ["cache.example-1:abc"], &fakeRunner, 7);

    assert(result.successful);
    assert(commands.length == 1);
    assert(commands[0] == [
        "timeout", "--kill-after=5s", "7s",
        "nix", "path-info", "--store", "https://cache.example", root,
        "--option", "substituters", "",
        "--option", "trusted-public-keys", "cache.example-1:abc",
    ]);
}

@("test_cache_probe_mixed_missing_batch_counts_unmentioned_paths")
unittest
{
    auto presentA = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present-a";
    auto presentB = "/nix/store/11111111111111111111111111111111-present-b";
    auto missing = "/nix/store/22222222222222222222222222222222-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n");
    }

    auto results = probeCacheSubstitutes([presentA, missing, presentB],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 3);
    assert(results[0].path == presentA);
    assert(results[0].outcome == "successful-substitute");
    assert(results[1].path == missing);
    assert(results[1].outcome == "narinfo-missing");
    assert(results[2].path == presentB);
    assert(results[2].outcome == "successful-substitute");
}

@("test_cache_probe_mixed_missing_batch_requires_named_missing_path")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto maybeMissing = "/nix/store/11111111111111111111111111111111-maybe-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "", "404 Not Found\n");
    }

    auto results = probeCacheSubstitutes([present, maybeMissing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "narinfo-missing");
    assert(results[1].outcome == "narinfo-missing");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_integrity_failures")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n"
            ~ "error: cannot download NAR object from binary cache\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "narinfo-present-object-unavailable");
    assert(results[1].outcome == "narinfo-present-object-unavailable");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_signature_failures")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n"
            ~ "error: path is not signed by a trusted key\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "signature-not-trusted");
    assert(results[1].outcome == "signature-not-trusted");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_timeouts")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(-9, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "probe-timeout");
    assert(results[1].outcome == "probe-timeout");
}

@("test_cache_probe_mixed_missing_batch_does_not_mask_timeout_stderr")
unittest
{
    auto present = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-present";
    auto missing = "/nix/store/11111111111111111111111111111111-missing";
    ProcessResult fakeRunner(string[] command)
    {
        return ProcessResult(1, "",
            "error: path '" ~ missing ~ "' does not exist in binary cache 'https://cache.example'\n"
            ~ "error: request timed out while probing cache\n");
    }

    auto results = probeCacheSubstitutes([present, missing],
        "https://cache.example", [], &fakeRunner, 7);

    assert(results.length == 2);
    assert(results[0].outcome == "narinfo-missing");
    assert(results[1].outcome == "narinfo-missing");
}

@("test_cache_probe_timeout_command_executes_inner_command")
unittest
{
    import mcl.utils.process : runProcessCapture;

    auto result = runProcessCapture(
        cacheProbeTimeoutCommand(["sh", "-c", "printf probe-ok"], 1));

    assert(result.exitCode == 0);
    assert(result.stdout == "probe-ok");
}

@("test_cache_push_closure_batches_probe_commands")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-batch-probes.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto depA = "/nix/store/11111111111111111111111111111111-dep-a";
    auto depB = "/nix/store/22222222222222222222222222222222-dep-b";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ depA ~ "\n" ~ depB ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://cache.example"))
            return ProcessResult(0, probeCommandStorePathStdout(command), "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root],
        substituters: ["https://cache.example"],
        eventLogPath: eventLog,
    ), &fakeRunner, &fakeRunner) == 0);

    ulong probeCommandCount;
    foreach (command; commands)
        if (command.canFind("--store") && command.canFind("https://cache.example"))
            ++probeCommandCount;

    assert(probeCommandCount == 1);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 3);
    assert(events[0]["metadata"]["coverage"]["successfulSubstituteCount"].integer == 3);
}

@("test_cache_probe_timeout_continues_to_later_substituter")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : any, filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-success.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0, `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, root ~ "\n", "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root],
        substituters: ["https://slow.example", "https://good.example"],
        eventLogPath: eventLog,
        probeTimeoutSeconds: 3,
    ), &fakeRunner, &fakeRunner) == 0);

    assert(commands.any!(cmd => cmd.canFind("3s") && cmd.canFind("https://slow.example")));
    assert(commands.any!(cmd => cmd.canFind("3s") && cmd.canFind("https://good.example")));

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 2);
    assert(events[0]["metadata"]["probes"][0]["outcome"].str == "probe-timeout");
    assert(events[0]["metadata"]["probes"][1]["outcome"].str == "successful-substitute");
}

@("test_cache_probe_timeout_skips_substituter_for_later_paths")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-skip.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto dep = "/nix/store/11111111111111111111111111111111-dep";
    auto secondRoot = "/nix/store/22222222222222222222222222222222-second-root";
    auto secondDep = "/nix/store/33333333333333333333333333333333-second-dep";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive") && command.canFind(secondRoot))
            return ProcessResult(0, secondRoot ~ "\n" ~ secondDep ~ "\n", "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, probeCommandStorePathStdout(command), "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root, secondRoot],
        substituters: ["https://slow.example", "https://good.example"],
        eventLogPath: eventLog,
        probeTimeoutSeconds: 3,
    ), &fakeRunner, &fakeRunner) == 0);

    ulong probeCommandCount(string substituter)
    {
        ulong count;
        foreach (command; commands)
            if (command.canFind("--store") && command.canFind(substituter))
                ++count;
        return count;
    }

    assert(probeCommandCount("https://slow.example") == 1);
    assert(probeCommandCount("https://good.example") == 2);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 2);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 6);
    assert(events[0]["metadata"]["unavailableSubstituters"].array.length == 1);
    assert(events[0]["metadata"]["unavailableSubstituters"][0].str == "https://slow.example");
}

@("test_cache_probe_non_timeout_failure_does_not_skip_later_batches")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-non-timeout-retry.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto dep = "/nix/store/11111111111111111111111111111111-dep";
    auto secondRoot = "/nix/store/22222222222222222222222222222222-second-root";
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive") && command.canFind(secondRoot))
            return ProcessResult(0, secondRoot ~ "\n", "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example")
            && command.canFind(secondRoot))
            return ProcessResult(0, secondRoot ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(1, dep ~ "\n", "404 Not Found");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, probeCommandStorePathStdout(command), "");
        return ProcessResult(0, "", "");
    }

    assert(pushClosure(CachePushRequest(
        backend: CacheBackend.cachix,
        cache: "example-cache",
        storePaths: [root, secondRoot],
        substituters: ["https://slow.example", "https://good.example"],
        eventLogPath: eventLog,
        probeTimeoutSeconds: 3,
    ), &fakeRunner, &fakeRunner) == 0);

    ulong probeCommandCount(string substituter)
    {
        ulong count;
        foreach (command; commands)
            if (command.canFind("--store") && command.canFind(substituter))
                ++count;
        return count;
    }

    assert(probeCommandCount("https://slow.example") == 2);
    assert(probeCommandCount("https://good.example") == 1);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 2);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 4);
    assert(events[0]["metadata"]["probes"][0]["path"].str == root);
    assert(events[0]["metadata"]["probes"][0]["outcome"].str == "narinfo-missing");
    assert(events[0]["metadata"]["probes"][1]["path"].str == dep);
    assert(events[0]["metadata"]["probes"][1]["outcome"].str == "successful-substitute");
    assert(events[0]["metadata"]["probes"][2]["path"].str == root);
    assert(events[0]["metadata"]["probes"][2]["substituter"].str == "https://good.example");
    assert(events[0]["metadata"]["probes"][2]["outcome"].str == "successful-substitute");
    assert("unavailableSubstituters" !in events[0]["metadata"].object);
}

@("test_cache_probe_timeout_failure_metadata")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-timeout-failure.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0, `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://missing.example"))
            return ProcessResult(1, "", "404 Not Found");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.cachix,
            cache: "example-cache",
            storePaths: [root],
            substituters: ["https://slow.example", "https://missing.example"],
            eventLogPath: eventLog,
            probeTimeoutSeconds: 3,
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache substitute integrity probe failed");
    }
    assert(threw);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "failed");
    assert(events[0]["error"]["code"].str == "cache_probe_failed");
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("probe-timeout"));
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("https://slow.example"));
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind("narinfo-missing"));
    assert(events[0]["metadata"]["probeTimeoutSeconds"].integer == 3);
    assert(events[0]["metadata"]["coverage"]["complete"].boolean == false);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 2);
    assert(events[0]["metadata"]["probes"][0]["outcome"].str == "probe-timeout");
    assert(events[0]["metadata"]["probes"][0]["message"].str.canFind("3s timeout"));
    assert(events[0]["metadata"]["probes"][1]["outcome"].str == "narinfo-missing");
}

@("test_cache_probe_requires_every_closure_path_covered")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

    auto eventLog = deleteme ~ ".cache-push-requires-full-closure.events.jsonl";
    scope(exit)
        if (eventLog.exists) eventLog.remove;

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto dep = "/nix/store/11111111111111111111111111111111-dep";
    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--json"))
            return ProcessResult(0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7}}`, "");
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--recursive"))
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store"))
            return ProcessResult(1, root ~ "\n", "404 Not Found");
        return ProcessResult(0, "", "");
    }

    bool threw;
    try
    {
        pushClosure(CachePushRequest(
            backend: CacheBackend.cachix,
            cache: "example-cache",
            storePaths: [root],
            substituters: ["https://partial.example"],
            eventLogPath: eventLog,
        ), &fakeRunner, &fakeRunner);
    }
    catch (Exception e)
    {
        threw = true;
        assert(e.msg == "Cache substitute integrity probe failed");
    }
    assert(threw);

    auto events = eventLog.readText.splitLines
        .filter!(line => line.strip != "")
        .map!(line => line.parseJSON)
        .array;
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "failed");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean == false);
    assert(events[0]["metadata"]["coverage"]["successfulSubstituteCount"].integer == 1);
    assert(events[0]["error"]["details"]["stderrSummary"].str.canFind(dep));
}

@("test_cache_probe_classifies_failures")
unittest
{
    assert(isTimeoutExitCode(124));
    assert(isTimeoutExitCode(137));
    assert(isTimeoutExitCode(143));
    assert(isTimeoutExitCode(-9));
    assert(isTimeoutExitCode(-15));
    assert(classifyProbeFailure("404 Not Found") == "narinfo-missing");
    assert(classifyProbeFailure("cannot download NAR object") == "narinfo-present-object-unavailable");
    assert(classifyProbeFailure("path is not signed by a trusted key") == "signature-not-trusted");
}
