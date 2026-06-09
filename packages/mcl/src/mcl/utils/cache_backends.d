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
    if (runner is null)
        return CacheProbeResult(path, substituter, "narinfo-missing", 1,
            "no process runner configured");

    auto pathInfoCommand = [
        "nix", "path-info", "--store", substituter, path,
    ];
    if (trustedPublicKeys.length)
        pathInfoCommand ~= ["--option", "trusted-public-keys", trustedPublicKeys.join(" ")];

    auto pathInfo = runner(cacheProbeTimeoutCommand(pathInfoCommand, timeoutSeconds));
    if (!pathInfo.succeeded)
    {
        auto outcome = isTimeoutExitCode(pathInfo.exitCode)
            ? "probe-timeout"
            : classifyProbeFailure(pathInfo.stderr);
        auto message = pathInfo.stderr.stderrSummary;
        if (outcome == "probe-timeout" && message == "")
            message = "substitute probe exceeded " ~ timeoutSeconds.to!string ~ "s timeout";
        return CacheProbeResult(path, substituter, outcome, pathInfo.exitCode, message);
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
    return CacheProbeResult(path, substituter, "successful-substitute", 0, "");
}

string[] cacheProbeTimeoutCommand(string[] command, ulong timeoutSeconds)
{
    return ["timeout", "--kill-after=5s", timeoutSeconds.to!string ~ "s"] ~ command;
}

bool isTimeoutExitCode(int exitCode)
{
    return exitCode == 124 || exitCode == 137 || exitCode == 143;
}

string classifyProbeFailure(string stderr)
{
    auto text = stderr.toLower;
    if (text.canFind("lacks a signature") || text.canFind("not signed")
        || text.canFind("not trusted") || text.canFind("bad signature")
        || text.canFind("signature"))
        return "signature-not-trusted";
    if (text.canFind("nar") || text.canFind("object") || text.canFind("unexpected eof")
        || text.canFind("unexpected end") || text.canFind("hash mismatch")
        || text.canFind("corrupt"))
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
        // for deploys" — not "every path lives on the primary cache" — is what
        // matters. Record each attempted substituter until the first success so
        // failure events can explain timeouts and later misses.
        foreach (root; request.storePaths)
            foreach (path; queryClosurePaths(root, queryRunner))
            {
                CacheProbeResult last;
                foreach (substituter; plan.substituters)
                {
                    if (substituter in unavailableSubstituters)
                        continue;

                    last = probeCacheSubstitute(path, substituter,
                        request.trustedPublicKeys, queryRunner,
                        request.probeTimeoutSeconds);
                    probes ~= last;
                    if (last.outcome == "probe-timeout")
                    {
                        unavailableSubstituters[substituter] = true;
                        unavailableSubstituterList ~= substituter;
                    }
                    if (last.successful)
                        break;
                }
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
    return probe.substituter ~ ": " ~ probe.outcome ~
        (probe.message == "" ? "" : ": " ~ probe.message);
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
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info"
            && command.canFind("--store"))
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
    string[][] commands;
    ProcessResult fakeRunner(string[] command)
    {
        commands ~= command;
        return ProcessResult(0, "", "");
    }

    auto root = "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root";
    auto result = probeCacheSubstitute(root, "https://cache.example",
        ["cache.example-1:abc"], &fakeRunner, 7);

    assert(result.successful);
    assert(commands.length == 1);
    assert(commands[0] == [
        "timeout", "--kill-after=5s", "7s",
        "nix", "path-info", "--store", "https://cache.example", root,
        "--option", "trusted-public-keys", "cache.example-1:abc",
    ]);
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
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example"))
            return ProcessResult(124, "", "");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, command[$ - 1] ~ "\n", "");
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
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 3);
    assert(events[0]["metadata"]["unavailableSubstituters"].array.length == 1);
    assert(events[0]["metadata"]["unavailableSubstituters"][0].str == "https://slow.example");
}

@("test_cache_probe_non_timeout_failure_does_not_skip_later_paths")
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
            return ProcessResult(0, root ~ "\n" ~ dep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://slow.example")
            && command.canFind(root))
            return ProcessResult(1, "", "404 Not Found");
        if (command.canFind("--store") && command.canFind("https://slow.example")
            && command.canFind(dep))
            return ProcessResult(0, dep ~ "\n", "");
        if (command.canFind("--store") && command.canFind("https://good.example"))
            return ProcessResult(0, command[$ - 1] ~ "\n", "");
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
    assert(events.length == 1);
    assert(events[0]["command"]["status"].str == "succeeded");
    assert(events[0]["metadata"]["coverage"]["complete"].boolean);
    assert(events[0]["metadata"]["coverage"]["probeAttemptCount"].integer == 3);
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

@("test_cache_probe_classifies_failures")
unittest
{
    assert(classifyProbeFailure("404 Not Found") == "narinfo-missing");
    assert(classifyProbeFailure("cannot download NAR object") == "narinfo-present-object-unavailable");
    assert(classifyProbeFailure("path is not signed by a trusted key") == "signature-not-trusted");
}
