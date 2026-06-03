module mcl.utils.deploy_state;

import std.algorithm : canFind, filter, map, sort;
import std.array : array;
import std.conv : to;
import std.file : dirEntries, exists, mkdirRecurse, readText, SpanMode, write;
import std.json : JSONOptions, JSONValue, parseJSON;
import std.path : baseName, buildPath;
import std.string : endsWith;
import std.typecons : Nullable;

import mcl.utils.deploy_manifest : manifestDeploymentId, manifestDesiredSystemPath,
    manifestSequence, manifestTarget;
import mcl.utils.deployment_events : utcTimestamp;

string safePathComponent(string value)
{
    string result;
    foreach (ch; value)
    {
        const ok = (ch >= 'a' && ch <= 'z')
            || (ch >= 'A' && ch <= 'Z')
            || (ch >= '0' && ch <= '9')
            || ch == '.'
            || ch == '_'
            || ch == '-';
        result ~= ok ? ch : '_';
    }
    return result == "" ? "unknown" : result;
}

string safeTargetName(string target) => safePathComponent(target);

void ensureDeployStateDirs(string stateDir)
{
    foreach (name; [
        "desired",
        "current",
        "failed",
        "superseded",
        "converged",
        "targets",
        "locks",
        "agent-status",
    ])
        mkdirRecurse(stateDir.buildPath(name));
}

string manifestStatePath(string stateDir, string category, string deploymentId)
{
    return stateDir.buildPath(category, safePathComponent(deploymentId) ~ ".json");
}

string targetLatestPath(string stateDir, string target)
{
    return stateDir.buildPath("targets", safeTargetName(target) ~ ".json");
}

Nullable!JSONValue loadManifestFile(string path)
{
    if (!path.exists)
        return Nullable!JSONValue.init;
    return Nullable!JSONValue(path.readText.parseJSON);
}

Nullable!JSONValue loadLatestManifest(string stateDir, string target)
{
    return loadManifestFile(targetLatestPath(stateDir, target));
}

JSONValue supersededStateFor(JSONValue manifest)
{
    return JSONValue([
        "deploymentId": JSONValue(manifestDeploymentId(manifest)),
        "sequence": JSONValue(cast(long) manifestSequence(manifest)),
        "supersededAt": JSONValue(utcTimestamp()),
    ]);
}

Nullable!JSONValue supersededStateForLatest(string stateDir, string target, ulong newSequence)
{
    auto latest = loadLatestManifest(stateDir, target);
    if (latest.isNull)
        return Nullable!JSONValue.init;

    if (manifestSequence(latest.get) >= newSequence)
        throw new Exception(
            "Desired deployment sequence " ~ newSequence.to!string
            ~ " is not newer than latest sequence "
            ~ manifestSequence(latest.get).to!string
            ~ " for target " ~ target
        );

    return Nullable!JSONValue(supersededStateFor(latest.get));
}

JSONValue statusJson(JSONValue manifest, string state, string message = "")
{
    JSONValue[string] status = [
        "target": JSONValue(manifestTarget(manifest)),
        "deploymentId": JSONValue(manifestDeploymentId(manifest)),
        "sequence": JSONValue(cast(long) manifestSequence(manifest)),
        "desiredSystemPath": JSONValue(manifestDesiredSystemPath(manifest)),
        "currentState": JSONValue(state),
        "updatedAt": JSONValue(utcTimestamp()),
    ];
    if (message != "")
        status["message"] = JSONValue(message);
    return JSONValue(status);
}

void writeManifest(string stateDir, string category, JSONValue manifest)
{
    ensureDeployStateDirs(stateDir);
    manifestStatePath(stateDir, category, manifestDeploymentId(manifest))
        .write(manifest.toString(JSONOptions.doNotEscapeSlashes));
}

void writeStatus(string stateDir, string category, JSONValue manifest, string state, string message = "")
{
    ensureDeployStateDirs(stateDir);
    manifestStatePath(stateDir, category, manifestDeploymentId(manifest))
        .write(statusJson(manifest, state, message).toString(JSONOptions.doNotEscapeSlashes));
}

bool recordDesiredManifest(string stateDir, JSONValue manifest)
{
    ensureDeployStateDirs(stateDir);
    writeManifest(stateDir, "desired", manifest);

    auto target = manifestTarget(manifest);
    auto latest = loadLatestManifest(stateDir, target);
    if (
        !latest.isNull
        && manifestDeploymentId(latest.get) != manifestDeploymentId(manifest)
        && manifestSequence(latest.get) >= manifestSequence(manifest)
    )
    {
        writeStatus(stateDir, "superseded", manifest, "superseded",
            "A newer desired deployment is already latest for this target.");
        return false;
    }

    if (!latest.isNull && manifestDeploymentId(latest.get) != manifestDeploymentId(manifest))
        writeStatus(stateDir, "superseded", latest.get, "superseded",
            "Superseded by " ~ manifestDeploymentId(manifest) ~ ".");

    targetLatestPath(stateDir, target).write(manifest.toString(JSONOptions.doNotEscapeSlashes));
    writeStatus(stateDir, "current", manifest, "accepted");
    return true;
}

void markDeploymentState(string stateDir, JSONValue manifest, string state, string message = "")
{
    const category = state == "succeeded" ? "converged"
        : state == "failed" ? "failed"
        : state == "superseded" ? "superseded"
        : "current";
    writeStatus(stateDir, category, manifest, state, message);
}

JSONValue[] loadLatestManifests(string stateDir, string[] selectedTargets = null)
{
    ensureDeployStateDirs(stateDir);
    JSONValue[] result;
    auto selected = selectedTargets;

    foreach (entry; dirEntries(stateDir.buildPath("targets"), SpanMode.shallow))
    {
        if (!entry.name.endsWith(".json"))
            continue;
        auto manifest = entry.name.readText.parseJSON;
        if (selected.length == 0 || selected.canFind(manifestTarget(manifest)))
            result ~= manifest;
    }

    return result
        .sort!((a, b) => manifestTarget(a) < manifestTarget(b))
        .array;
}

@("test_latest_only_state_supersedes_older_deployment")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.supersede";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto oldManifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-41",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 41,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system-41",
    ));
    auto newManifest = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system-42",
    ));

    assert(recordDesiredManifest(stateDir, oldManifest));
    assert(recordDesiredManifest(stateDir, newManifest));
    assert(manifestDeploymentId(loadLatestManifest(stateDir, "app-1").get) == "deploy-42");
    assert(manifestStatePath(stateDir, "superseded", "deploy-41").exists);
}

@("test_deploy_state_sanitizes_deployment_id_paths")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.sanitize-deployment-id";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto manifest = buildManifest(ManifestBuildRequest(
        deploymentId: "../targets/owned",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 1,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system",
    ));

    assert(recordDesiredManifest(stateDir, manifest));
    assert(stateDir.buildPath("desired", ".._targets_owned.json").exists);
    assert(!stateDir.buildPath("targets", "owned.json").exists);
    assert(stateDir.buildPath("targets", "app-1.json").exists);
}

@("test_latest_only_state_rejects_stale_deployment")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.reject";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto newer = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system-42",
    ));
    auto stale = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-41",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 41,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system-41",
    ));

    assert(recordDesiredManifest(stateDir, newer));
    assert(!recordDesiredManifest(stateDir, stale));
    assert(manifestDeploymentId(loadLatestManifest(stateDir, "app-1").get) == "deploy-42");
    assert(manifestStatePath(stateDir, "superseded", "deploy-41").exists);
}

@("test_latest_only_state_rejects_same_sequence_different_deployment")
unittest
{
    import std.file : deleteme, rmdirRecurse;
    import mcl.utils.deploy_manifest : ManifestBuildRequest, buildManifest;

    auto stateDir = deleteme ~ ".state.same-sequence";
    scope(exit)
    {
        if (stateDir.exists) stateDir.rmdirRecurse;
    }

    auto accepted = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42-a",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234567",
        sequence: 42,
        desiredSystemPath: "/nix/store/0123456789abcdfghijklmnpqrsvwxyz-system-42a",
    ));
    auto duplicateSequence = buildManifest(ManifestBuildRequest(
        deploymentId: "deploy-42-b",
        target: "app-1",
        gitRevision: "0123456789abcdef0123456789abcdef01234568",
        sequence: 42,
        desiredSystemPath: "/nix/store/1123456789abcdfghijklmnpqrsvwxyz-system-42b",
    ));

    assert(recordDesiredManifest(stateDir, accepted));
    assert(!recordDesiredManifest(stateDir, duplicateSequence));
    assert(manifestDeploymentId(loadLatestManifest(stateDir, "app-1").get) == "deploy-42-a");
    assert(manifestStatePath(stateDir, "superseded", "deploy-42-b").exists);
}
