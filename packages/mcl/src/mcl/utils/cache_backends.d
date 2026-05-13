module mcl.utils.cache_backends;

import std.algorithm : any, canFind, map;
import std.array : array, join;
import std.file : deleteme, exists, mkdirRecurse, rmdirRecurse;
import std.json : JSONValue;
import std.string : splitLines, strip, toLower;
import std.typecons : Nullable;

import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, queryClosureSummary, stderrSummary;
import mcl.utils.process : ProcessResult, ProcessRunner;

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
)
{
    if (runner is null)
        return CacheProbeResult(path, "narinfo-missing", 1, "no process runner configured");

    auto pathInfoCommand = [
        "nix", "path-info", "--store", substituter, path,
    ];
    if (trustedPublicKeys.length)
        pathInfoCommand ~= ["--option", "trusted-public-keys", trustedPublicKeys.join(" ")];

    auto pathInfo = runner(pathInfoCommand);
    if (!pathInfo.succeeded)
        return CacheProbeResult(path, classifyProbeFailure(pathInfo.stderr), pathInfo.exitCode,
            pathInfo.stderr.stderrSummary);

    auto tempStore = deleteme ~ ".mcl-cache-probe-store";
    scope(exit)
        if (tempStore.exists)
            tempStore.rmdirRecurse;
    mkdirRecurse(tempStore);

    auto copyCommand = [
        "nix", "copy", "--from", substituter, "--to", "file://" ~ tempStore, path,
    ];
    if (trustedPublicKeys.length)
        copyCommand ~= ["--option", "trusted-public-keys", trustedPublicKeys.join(" ")];

    auto copy = runner(copyCommand);
    if (copy.succeeded)
        return CacheProbeResult(path, "successful-substitute", 0, "");

    return CacheProbeResult(path, classifyProbeFailure(copy.stderr), copy.exitCode,
        copy.stderr.stderrSummary);
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
)
{
    JSONValue[] probeJson;
    ulong successful;
    foreach (probe; probes)
    {
        if (probe.successful)
            successful++;
        probeJson ~= JSONValue([
            "path": JSONValue(probe.path),
            "outcome": JSONValue(probe.outcome),
            "exitCode": JSONValue(cast(long) probe.exitCode),
            "message": JSONValue(probe.message),
        ]);
    }

    JSONValue[string] metadata = [
        "backend": JSONValue(cacheBackendName(request.backend)),
        "controller": JSONValue(plan.controller),
        "coverage": JSONValue([
            "rootPathCount": JSONValue(cast(long) request.storePaths.length),
            "probedPathCount": JSONValue(cast(long) probes.length),
            "successfulSubstituteCount": JSONValue(cast(long) successful),
            "complete": JSONValue(probes.length > 0 && successful == probes.length),
        ]),
        "probes": JSONValue(probeJson),
    ];

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
    const missingRequiredSubstituter = pushResult.succeeded
        && request.requireSubstitute
        && plan.substituters.length == 0;

    if (pushResult.succeeded && request.requireSubstitute && plan.substituters.length)
    {
        foreach (root; request.storePaths)
            foreach (path; queryClosurePaths(root, queryRunner))
                probes ~= probeCacheSubstitute(path, plan.substituters[0],
                    request.trustedPublicKeys, queryRunner);
    }

    const probeFailed = probes.any!(probe => !probe.successful);
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
            cachePushMetadata(request, plan, probes).object,
        ));

    enforce(status != "failed", errorMessage == "" ? "Cache push failed" : errorMessage);
    return 0;
}

string probeFailureSummary(CacheProbeResult[] probes)
{
    foreach (probe; probes)
        if (!probe.successful)
            return probe.path ~ ": " ~ probe.outcome ~
                (probe.message == "" ? "" : ": " ~ probe.message);
    return "";
}

@("test_cache_push_closure_invokes_backend")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.string : splitLines;
    import std.algorithm : filter;

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

@("test_cache_probe_classifies_failures")
unittest
{
    assert(classifyProbeFailure("404 Not Found") == "narinfo-missing");
    assert(classifyProbeFailure("cannot download NAR object") == "narinfo-present-object-unavailable");
    assert(classifyProbeFailure("path is not signed by a trusted key") == "signature-not-trusted");
}
