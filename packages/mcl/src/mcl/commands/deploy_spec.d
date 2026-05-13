module mcl.commands.deploy_spec;

import std.algorithm : canFind, filter, map;
import std.array : array;
import std.logger : infof, warningf;
import std.file : exists;
import std.path : buildPath;
import std.range : empty;
import std.typecons : Nullable;

import argparse : Command, Description, EnvFallback, NamedArgument, Placeholder;

import mcl.utils.process : ProcessResult, ProcessRunner, runProcessCapture,
    runProcessInlineCapture, spawnProcessInline;
import mcl.utils.path : resultDir;
import mcl.utils.cachix : DeploySpec, createMachineDeploySpec;
import mcl.utils.tui : bold;
import mcl.utils.json : tryDeserializeFromJsonFile, writeJsonFile;
import mcl.utils.deployment_events : ClosureSummary, DeploymentEventContext,
    appendDeploymentEvent, deploymentEventJson, deploymentEventLogPathFromEnv,
    queryClosureSummary, stderrSummary;

import mcl.commands.ci_matrix : nixEvalJobs, CiMatrixBaseArgs;


@(Command("deploy-spec", "deploy_spec")
    .Description("Evaluate the Nixos machine configurations in bareMetalMachines and deploy them to cachix."))
struct DeploySpecArgs {
    mixin CiMatrixBaseArgs!();

    @(NamedArgument(["event-log"])
        .Placeholder("events.jsonl")
        .Description("Write backend-neutral deployment events as JSONL")
        .EnvFallback("MCL_DEPLOY_EVENT_LOG"))
    string eventLog;
}

struct DeploySpecDependencies
{
    ProcessRunner runProcess;
    ProcessRunner queryProcess;
}

private void pushDeploymentClosure(DeploySpec spec, string cachixCache)
{
    infof(
        "Pushing deployment closure for %s agents to Cachix cache '%s'.",
        spec.agents.length,
        cachixCache
    );

    spawnProcessInline([
        "bash", "-euo", "pipefail", "-c",
        q{
cache="$1"
shift

nix-store -r "$@"
nix-store -qR "$@" | cachix push "$cache"
        },
        "mcl-push-deployment-closure",
        cachixCache,
    ] ~ spec.agents.values);
}

export int deploy_spec(DeploySpecArgs args)
{
    return deploySpecImpl(args, DeploySpecDependencies(
        runProcess: (string[] command) => runProcessInlineCapture(command),
        queryProcess: (string[] command) => runProcessCapture(command),
    ));
}

int deploySpecImpl(DeploySpecArgs args, DeploySpecDependencies deps, string deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json"))
{
    import std.exception : enforce;
    import std.json : JSONValue;

    DeploySpec spec;
    auto eventLogPath = args.eventLog != "" ? args.eventLog : deploymentEventLogPathFromEnv();
    auto context = DeploymentEventContext(
        eventLogPath: eventLogPath,
        cache: args.cachixCache,
        substituters: args.binaryCacheUrls,
    );
    auto queryRunner = deps.queryProcess is null ? deps.runProcess : deps.queryProcess;
    const eventLoggingEnabled = eventLogPath != "";

    if (!exists(deploySpecFile))
    {
        auto nixosConfigs = "legacyPackages.x86_64-linux.serverMachines"
            .nixEvalJobs(args);

        auto pkgsNotFoundInCache = nixosConfigs.filter!(c => c.cachedAt.empty);

        foreach (pkg; pkgsNotFoundInCache.save())
        {
            warningf(
                "Nixos configuration '%s' is not in cachix.\nExpected Cachix URL: %s\n",
                pkg.name.bold,
                pkg.getNarInfoUrl(args.binaryCacheUrls[0]).bold
            );
        }

        foreach (pkg; nixosConfigs)
        {
            auto closure = eventLoggingEnabled
                ? queryClosureSummary(pkg.output, queryRunner)
                : Nullable!ClosureSummary.init;
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "evaluate",
                pkg.name,
                pkg.output,
                "nix-eval-jobs",
                ["nix-eval-jobs", "--flake", "legacyPackages.x86_64-linux.serverMachines"],
                "succeeded",
                0,
                closure,
                "",
                "command_failed",
                "",
                [
                    "attrPath": JSONValue(pkg.attrPath),
                    "derivation": JSONValue(pkg.derivation),
                ],
            ));
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "build",
                pkg.name,
                pkg.output,
                "ci build",
                ["nix", "build", ".#" ~ pkg.attrPath],
                "skipped",
                0,
                closure,
                "",
                "command_failed",
                "",
                [
                    "reason": JSONValue("build phase is performed by the reusable workflow before deploy-spec"),
                ],
            ));
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "closure-prefill",
                pkg.name,
                pkg.output,
                "cache availability check",
                ["mcl", "deploy-spec"],
                pkg.cachedAt.empty ? "failed" : "succeeded",
                pkg.cachedAt.empty ? 1 : 0,
                closure,
                pkg.cachedAt.empty ? "System closure is not available in the configured caches" : "",
                "closure_not_cached",
                pkg.cachedAt.empty ? pkg.getNarInfoUrl(args.binaryCacheUrls[0]) : "",
                [
                    "cachedAt": JSONValue(pkg.cachedAt.map!(url => JSONValue(url)).array),
                ],
            ));
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "cache-push",
                pkg.name,
                pkg.output,
                "cachix push",
                ["cachix", "push", args.cachixCache, pkg.output],
                "skipped",
                0,
                closure,
                "",
                "command_failed",
                "",
                [
                    "reason": JSONValue("cache push is performed by the reusable workflow build job"),
                ],
            ));
        }

        if (!pkgsNotFoundInCache.empty)
            throw new Exception("Some Nixos configurations are not in cachix. Please cache them first.");

        spec = nixosConfigs.createMachineDeploySpec();
        writeJsonFile(spec, deploySpecFile);
    }
    else
    {
        warningf("Reusing existing deploy spec at:\n'%s'", deploySpecFile.bold);
        spec = deploySpecFile.tryDeserializeFromJsonFile!DeploySpec();
        foreach (target, systemPath; spec.agents)
            appendDeploymentEvent(eventLogPath, deploymentEventJson(
                context,
                "evaluate",
                target,
                systemPath,
                "deploy spec reuse",
                ["mcl", "deploy-spec"],
                "skipped",
                0,
                Nullable!ClosureSummary.init,
                "",
                "command_failed",
                "",
                [
                    "deploySpecFile": JSONValue(deploySpecFile),
                    "reused": JSONValue(true),
                ],
            ));
    }

    infof("\n---\n%s\n---", spec);
    infof("%s machines will be deployed.", spec.agents.length);

    if (!spec.agents.length)
        return 0;

    pushDeploymentClosure(spec, args.cachixCache);

    auto activateCommand = [
        "cachix", "deploy", "activate", deploySpecFile, "--async"
    ];

    if (!eventLoggingEnabled)
    {
        spawnProcessInline(activateCommand);
        return 0;
    }

    auto result = deps.runProcess(activateCommand);
    foreach (target, systemPath; spec.agents)
        appendDeploymentEvent(eventLogPath, deploymentEventJson(
            context,
            "activate-requested",
            target,
            systemPath,
            "cachix deploy activate",
            activateCommand,
            result.succeeded ? "succeeded" : "failed",
            result.exitCode,
            queryClosureSummary(systemPath, queryRunner),
            result.succeeded ? "" : "Activation request failed",
            "activation_request_failed",
            result.succeeded ? "" : result.stderr.stderrSummary,
            [
                "deploySpecFile": JSONValue(deploySpecFile),
            ],
        ));

    enforce(result.succeeded, "Process failed.");

    return 0;
}

@("test_deploy_event_log_success_shape")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.algorithm : filter;
    import std.string : splitLines;

    auto tempBase = deleteme;
    auto eventLog = tempBase ~ ".success.events.jsonl";
    auto specFile = tempBase ~ ".success.spec.json";
    scope(exit)
    {
        if (tempBase.exists) tempBase.remove;
        if (eventLog.exists) eventLog.remove;
        if (specFile.exists) specFile.remove;
    }

    DeploySpecArgs args;
    args.cachixCache = "example-cache";
    args.cachixAuthToken = "token";
    args.eventLog = eventLog;

    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info")
            return ProcessResult(
                0,
                `{"/nix/store/0123456789abcdfghijklmnpqrsvwxyz-root":{"narSize":7},"/nix/store/1123456789abcdfghijklmnpqrsvwxyz-dep":{"narSize":11}}`,
                "",
            );
        return ProcessResult(0, "", "");
    }

    writeJsonFile(DeploySpec(agents: [
        "app-server-01": "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01",
    ]), specFile);

    assert(deploySpecImpl(args, DeploySpecDependencies(&fakeRunner), specFile) == 0);

    auto events = eventLog.readText.splitLines.filter!(line => line != "").map!(line => line.parseJSON).array;
    assert(events.length == 2);
    assert(events[0]["phase"].str == "evaluate");
    assert(events[1]["phase"].str == "activate-requested");
    assert(events[1]["command"]["status"].str == "succeeded");
    assert(events[1]["storePaths"]["closure"]["count"].integer == 2);
    assert(events[1]["storePaths"]["closure"]["totalBytes"].integer == 18);
}

@("test_deploy_event_log_failure_shape")
unittest
{
    import std.file : deleteme, readText, remove;
    import std.json : parseJSON;
    import std.algorithm : filter;
    import std.string : splitLines;
    import std.exception : assertThrown;

    auto tempBase = deleteme;
    auto eventLog = tempBase ~ ".failure.events.jsonl";
    auto specFile = tempBase ~ ".failure.spec.json";
    scope(exit)
    {
        if (tempBase.exists) tempBase.remove;
        if (eventLog.exists) eventLog.remove;
        if (specFile.exists) specFile.remove;
    }

    DeploySpecArgs args;
    args.cachixCache = "example-cache";
    args.cachixAuthToken = "token";
    args.eventLog = eventLog;

    ProcessResult fakeRunner(string[] command)
    {
        if (command.length >= 2 && command[0] == "nix" && command[1] == "path-info")
            return ProcessResult(0, `{}`, "");
        return ProcessResult(23, "", "activation stderr details");
    }

    writeJsonFile(DeploySpec(agents: [
        "app-server-01": "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-nixos-system-app-server-01",
    ]), specFile);

    assertThrown!Exception(deploySpecImpl(args, DeploySpecDependencies(&fakeRunner), specFile));

    auto events = eventLog.readText.splitLines.filter!(line => line != "").map!(line => line.parseJSON).array;
    auto failed = events[$ - 1];
    assert(failed["phase"].str == "activate-requested");
    assert(failed["command"]["status"].str == "failed");
    assert(failed["command"]["exitCode"].integer == 23);
    assert(failed["error"]["details"]["stderrSummary"].str.canFind("activation stderr details"));
}
