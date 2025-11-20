module mcl.commands.ci_matrix;

import std.stdio : writeln, stderr, stdout;
import std.traits : EnumMembers;
import std.string : indexOf, splitLines, strip;
import std.algorithm : map, filter, reduce, chunkBy, find, any, sort, startsWith, each, canFind, fold;
import std.file : write, readText;
import std.range : array, front, join, split;
import std.conv : to;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.regex : matchFirst;
import core.cpuid : threadsPerCPU;
import std.path : buildPath;
import std.process : pipeProcess, wait, Redirect, kill;
import std.exception : enforce;
import std.format : fmt = format;
import std.logger : tracef, infof, errorf, warningf;

import argparse : Command, Description, NamedArgument, Required, Placeholder, EnvFallback;

import mcl.utils.string : enumToString, StringRepresentation, MaxWidth, writeRecordAsTable;
import mcl.utils.json : toJSON;
import mcl.utils.path : rootDir, resultDir, gcRootsDir, createResultDirs;
import mcl.utils.process : execute;
import mcl.utils.nix : nix;

import mcl.commands.ci: CiArgs;
import mcl.commands.deploy_spec: DeploySpecArgs;

enum GitHubOS
{
    @StringRepresentation("ubuntu-latest") ubuntuLatest,
    @StringRepresentation("self-hosted") selfHosted,

    @StringRepresentation("macos-14") macos14
}

enum SupportedSystem
{
    @StringRepresentation("x86_64-linux") x86_64_linux,

    @StringRepresentation("x86_64-darwin") x86_64_darwin,

    @StringRepresentation("aarch64-darwin") aarch64_darwin
}

GitHubOS getGHOS(string os)
{
    switch (os)
    {
    case "self-hosted":
        return GitHubOS.selfHosted;
    case "ubuntu-latest":
        return GitHubOS.ubuntuLatest;
    case "macos-14":
        return GitHubOS.macos14;
    default:
        return GitHubOS.selfHosted;
    }
}

@("getGHOS")
unittest
{
    assert(getGHOS("ubuntu-latest") == GitHubOS.ubuntuLatest);
    assert(getGHOS("macos-14") == GitHubOS.macos14);
    assert(getGHOS("crazyos-inator-2000") == GitHubOS.selfHosted);
}

SupportedSystem getSystem(string system)
{
    switch (system)
    {
    case "x86_64-linux":
        return SupportedSystem.x86_64_linux;
    case "x86_64-darwin":
        return SupportedSystem.x86_64_darwin;
    case "aarch64-darwin":
        return SupportedSystem.aarch64_darwin;
    default:
        return SupportedSystem.x86_64_linux;
    }
}

@("getSystem")
unittest
{
    assert(getSystem("x86_64-linux") == SupportedSystem.x86_64_linux);
    assert(getSystem("x86_64-darwin") == SupportedSystem.x86_64_darwin);
    assert(getSystem("aarch64-darwin") == SupportedSystem.aarch64_darwin);
    assert(getSystem("bender-bending-rodriguez-os") == SupportedSystem.x86_64_linux);
}

struct Package
{
    string name;
    bool allowedToFail = false;
    string attrPath;
    string cacheUrl;
    bool isCached;
    GitHubOS os;
    SupportedSystem system;
    string derivation;
    string output;
}

version (unittest)
{
    static immutable Package[] testPackageArray = [
        Package("testPackage", false, "testPackagePath", "https://testPackage.com", true, GitHubOS.ubuntuLatest, SupportedSystem.x86_64_linux, "testPackageOutput"),
        Package("testPackage2", true, "testPackagePath2", "https://testPackage2.com", false, GitHubOS.macos14, SupportedSystem
                .aarch64_darwin, "testPackageOutput2")
    ];
}

struct Matrix
{
    Package[] include;
}

struct SummaryTableEntry_x86_64
{
    string linux;
    string darwin;
}

struct SummaryTableEntry_aarch64
{
    string darwin;
}

struct SummaryTableEntry
{
    string name;
    SummaryTableEntry_x86_64 x86_64;
    SummaryTableEntry_aarch64 aarch64;
}

version (unittest)
{
    static immutable SummaryTableEntry[] testSummaryTableEntryArray = [
        SummaryTableEntry("testPackage", SummaryTableEntry_x86_64("✅ cached", "✅ cached"), SummaryTableEntry_aarch64("🚫 not supported")),
        SummaryTableEntry("testPackage2", SummaryTableEntry_x86_64("⏳ building...", "❌ build failed"), SummaryTableEntry_aarch64(
                "⏳ building..."))
    ];
}

mixin template CiMatrixBaseArgs()
{
    import argparse : Command, Description, NamedArgument, Required, Placeholder, EnvFallback;

    @(NamedArgument(["flake-pre"])
        .Placeholder("prefix")
    )
    string flakePre = "checks";

    @(NamedArgument(["flake-post"])
        .Placeholder("postfix")
    )
    string flakePost;

    @(NamedArgument(["max-workers"])
        .Placeholder("count")
    )
    int maxWorkers;

    @(NamedArgument(["max-memory"])
        .Placeholder("mb")
    )
    int maxMemory;

    @(NamedArgument(["initial"])
    )
    bool isInitial;

    @(NamedArgument(["cachix-cache"])
        .Placeholder("cache")
        .EnvFallback("CACHIX_CACHE")
        .Required()
    )
    string cachixCache;

    @(NamedArgument(["cachix-auth-token"])
        .Placeholder("token")
        .EnvFallback("CACHIX_AUTH_TOKEN")
        .Required()
    )
    string cachixAuthToken;
}

@(Command("ci-matrix", "ci_matrix")
    .Description("Print a table of the cache status of each package"))
struct CiMatrixArgs
{
    mixin CiMatrixBaseArgs!();
}

@(Command("print-table", "print_table")
    .Description("Print a table of the cache status of each package"))
struct PrintTableArgs
{
    mixin CiMatrixBaseArgs!();

    @(NamedArgument(["precalc-matrix"])
        .Placeholder("matrix")
    )
    string precalcMatrix;
}

export int ci_matrix(CiMatrixArgs args)
{
    createResultDirs();
    nixEvalForAllSystems(args).array.printTableForCacheStatus(args);
    return 0;
}

export int print_table(PrintTableArgs args)
{
    createResultDirs();

    getPrecalcMatrix(args)
        .checkCacheStatus(args)
        .printTableForCacheStatus(args);

    return 0;
}

string flakeAttr(string prefix, SupportedSystem system, string postfix)
{
    postfix = postfix == "" ? "" : "." ~ postfix;
    return "%s.%s%s".fmt(prefix, system.enumToString, postfix);
}

string flakeAttr(string prefix, string arch, string os, string postfix)
{
    postfix = postfix == "" ? "" : "." ~ postfix;
    return "%s.%s-%s%s".fmt(prefix, arch, os, postfix);
}

Package[] checkCacheStatus(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    import std.array : appender;
    import std.parallelism : parallel;

    foreach (ref pkg; packages.parallel)
    {
        pkg = checkPackage(pkg, args);
        struct Output { string isCached, name, storePath; }
        auto res = appender!string;
        writeRecordAsTable(
            Output(pkg.isCached ? "✅" : "❌", pkg.name, pkg.output),
            res
        );
        tracef("%s", res.data[0..$-1]);
    }
    return packages;
}



GitHubOS systemToGHPlatform(SupportedSystem os)
{
    return os == SupportedSystem.x86_64_linux ? GitHubOS.selfHosted : GitHubOS.macos14;
}

@("systemToGHPlatform")
unittest
{
    assert(systemToGHPlatform(SupportedSystem.x86_64_linux) == GitHubOS.selfHosted);
    assert(systemToGHPlatform(SupportedSystem.x86_64_darwin) == GitHubOS.macos14);
    assert(systemToGHPlatform(SupportedSystem.aarch64_darwin) == GitHubOS.macos14);
}

static immutable string[] uselessWarnings =
    ["allowed-users", "trusted-users", "bash-prompt-prefix"].map!(
        setting => "warning: unknown setting '" ~ setting ~ "'").array ~
    [
        "warning: ignoring untrusted flake configuration setting 'extra-substituters'.",
        "warning: ignoring untrusted flake configuration setting 'extra-trusted-public-keys'.",
        "Pass '--accept-flake-config' to trust it",
        "SQLite database",
        "trace: warning: The legacy table is outdated and should not be used. We recommend using the gpt type instead.",
        "Please note that certain features, such as the test framework, may not function properly with the legacy table type.",
        "If you encounter errors similar to:",
        "error: The option `disko.devices.disk.disk1.content.partitions",
        "this is likely due to the use of the legacy table type.",
        "warning: system.stateVersion is not set, defaulting to",
        "warning: Runner registration tokens have been deprecated and disabled by default in GitLab >= 17.0.",
        "Consider migrating to runner authentication tokens by setting `services.gitlab-runner.services.codetracer.authenticationTokenConfigFile`.",
        "https://docs.gitlab.com/17.0/ee/ci/runners/new_creation_workflow.html",
        "for a migration you can follow the guide at https://github.com/nix-community/disko/blob/master/docs/table-to-gpt.md"
    ];

Package packageFromNixEvalJobsJson(
    JSONValue json,
    string flakeAttrPrefix,
    string binaryCacheHttpEndpoint = "https://cache.nixos.org"
)
{
    return Package(
        name: json["attr"].str,
        allowedToFail: false,
        attrPath: flakeAttrPrefix ~ "." ~ json["attr"].str,
        isCached: json["isCached"].boolean,
        system: getSystem(json["system"].str),
        os: systemToGHPlatform(getSystem(json["system"].str)),
        derivation: json["drvPath"].str,
        output: json["outputs"]["out"].str,
        cacheUrl: binaryCacheHttpEndpoint ~ "/" ~ json["outputs"]["out"].str.matchFirst(
            "^/nix/store/(?P<hash>[^-]+)-")["hash"] ~ ".narinfo"
    );
}

@("packageFromNixEvalJobsJson")
unittest
{
    {
        auto testJSON = `{
            "attr": "home/bean-desktop",
            "attrPath": [ "home/bean-desktop" ],
            "cacheStatus": "notBuilt",
            "drvPath": "/nix/store/jp7qgm9mgikksypzljrbhmxa31xmmq1x-home-manager-generation.drv",
            "inputDrvs": {
                "/nix/store/0hkqmn0z40yx89kd5wgfjxzqckvjkiw3-home-manager-files.drv": [ "out" ],
                "/nix/store/0khqc4m8jrv5gkg2jwf5xz46bkmz2qxl-dconf-keys.json.drv": [ "out" ],
                "/nix/store/5rydfkrpd5vdpz4qxsypivxwy9y6z8gl-bash-5.2p26.drv": [ "out" ],
                "/nix/store/7vgw0fqilqwa9l26arqpym1l4iisgff1-stdenv-linux.drv": [ "out" ],
                "/nix/store/96ji6f4cijfc23jz98x45xm1dvzz5hq8-activation-script.drv": [ "out" ],
                "/nix/store/m60vlf9j0g8y82avg5x90nbg554wshva-home-manager-path.drv": [ "out" ]
            },
            "isCached": false,
            "name": "home-manager-generation",
            "outputs": {
                "out": "/nix/store/30qrziyj0vbg6n43bbh08ql0xbnsy76d-home-manager-generation"
            },
            "system": "x86_64-linux"
        }`.parseJSON;

        auto testPackage = testJSON.packageFromNixEvalJobsJson(
            "legacyPackages.x86_64-linux.mcl.matrix.shards.0",
            "https://binary-cache.internal"
        );
        assert(testPackage == Package(
            name: "home/bean-desktop",
            allowedToFail: false,
            attrPath: "legacyPackages.x86_64-linux.mcl.matrix.shards.0.home/bean-desktop",
            isCached: false,
            system: SupportedSystem.x86_64_linux,
            os: GitHubOS.selfHosted,
            derivation: "/nix/store/jp7qgm9mgikksypzljrbhmxa31xmmq1x-home-manager-generation.drv",
            output: "/nix/store/30qrziyj0vbg6n43bbh08ql0xbnsy76d-home-manager-generation",
            cacheUrl: "https://binary-cache.internal/30qrziyj0vbg6n43bbh08ql0xbnsy76d.narinfo"
        ));
    }
}
Package[] nixEvalJobs(T)(string flakeAttrPrefix, string cachixUrl, auto ref T args, bool doCheck = true)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    Package[] result = [];

    bool hasError = false;

    int maxMemoryMB = getAvailableMemoryMB(args);
    int maxWorkers = getNixEvalWorkerCount(args);

    const nixArgs = [
        "nix-eval-jobs", "--quiet", "--option", "warn-dirty", "false",
        "--check-cache-status", "--gc-roots-dir", gcRootsDir, "--workers",
        maxWorkers.to!string, "--max-memory-size", maxMemoryMB.to!string,
        "--flake", rootDir ~ "#" ~ flakeAttrPrefix
    ];

    const commandString = nixArgs.join(" ");

    tracef("%-(%s %)", nixArgs);

    auto pipes = pipeProcess(nixArgs, Redirect.stdout | Redirect.stderr);

    void logWarning(const char[] msg)
    {
        warningf("Command `%s` stderr:\n---\n%s\n---", commandString, msg);
    }

    void logError(const char[] msg)
    {
        errorf("Command `%s` failed with error:\n---\n%s\n---", commandString, msg);
    }

    const errorsReported = pipes.stdout.byLine.fold!((errorsReported, line) {
        auto json = parseJSON(line);

        if (auto err = "error" in json)
        {
            logError((*err).str);
            return true;
        }

        Package pkg = json.packageFromNixEvalJobsJson(
            flakeAttrPrefix, cachixUrl);

        if (doCheck)pkg = pkg.checkPackage(args);

        result ~= pkg;

        struct Output {
            bool isCached;
            GitHubOS os;
            @MaxWidth(50) string attr;
            @MaxWidth(80) string output;
        }

        Output(
            isCached: pkg.isCached,
            os: pkg.os,
            attr: pkg.attrPath,
            output: pkg.output
        ).writeRecordAsTable(stderr.lockingTextWriter);

        return errorsReported;
    })(false);

    const stderrLogs = pipes.stderr.byLine
        .filter!(line => !uselessWarnings.any!(w => line.canFind(w)))
        .join("\n");

    if (stderrLogs.strip != "")
        logWarning(stderrLogs);

    int status = wait(pipes.pid);

    enforce(status == 0 && !errorsReported, "Command `%s` failed with status %s".fmt(commandString, status));

    return result;
}

SupportedSystem[] getSupportedSystems(string flakeRef = ".")
{
    import std.path : isValidPath, absolutePath, buildNormalizedPath;

    if (flakeRef.isValidPath) {
        flakeRef = flakeRef.absolutePath.buildNormalizedPath;
    }

    const json = nix.eval!JSONValue("", [
        "--impure",
        "--expr",
        `builtins.attrNames (builtins.getFlake "` ~ flakeRef ~ `").outputs.legacyPackages`
    ]);

    return json.array.map!(system => getSystem(system.str)).array;
}

Package[] nixEvalForAllSystems(T)(auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    const cachixUrl = "https://" ~ args.cachixCache ~ ".cachix.org";
    const systems = getSupportedSystems();

    infof("Evaluating flake for: %s", systems);

    return systems.map!(system =>
            flakeAttr(args.flakePre, system, args.flakePost)
                .nixEvalJobs(cachixUrl, args)
        )
        .reduce!((a, b) => a ~ b)
        .array
        .sort!((a, b) => a.name < b.name)
        .array;
}

int getNixEvalWorkerCount(T)(auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    return args.maxWorkers == 0 ? (threadsPerCPU() < 8 ? threadsPerCPU() : 8) : args.maxWorkers;
}

@("getNixEvalWorkerCount")
unittest
{
    CiMatrixArgs args;
    args.maxWorkers = 0;
    assert(getNixEvalWorkerCount(args) == (threadsPerCPU() < 8 ? threadsPerCPU() : 8));

    args.maxWorkers = 4;
    assert(getNixEvalWorkerCount(args) == 4);
}

int getAvailableMemoryMB(T)(auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    int free = "/proc/meminfo".readText
        .splitLines
        .find!(a => a.indexOf("MemFree") != -1)
        .front
        .split[1].to!int;
    int cached = "/proc/meminfo".readText
        .splitLines
        .find!(a => a.indexOf("Cached") != -1 && a.indexOf("SwapCached") == -1)
        .front
        .split[1].to!int;
    int buffers = "/proc/meminfo".readText
        .splitLines
        .find!(a => a.indexOf("Buffers") != -1)
        .front
        .split[1].to!int;
    int shmem = "/proc/meminfo".readText
        .splitLines
        .find!(a => a.indexOf("Shmem:") != -1)
        .front
        .split[1].to!int;
    int maxMemoryMB = args.maxMemory == 0 ? ((free + cached + buffers + shmem) / 1024)
        : args.maxMemory;
    return maxMemoryMB;
}

@("getAvailableMemoryMB")
unittest
{
    CiMatrixArgs args;
    args.maxMemory = 0;
    assert(getAvailableMemoryMB(args) > 0);

    args.maxMemory = 1024;
    assert(getAvailableMemoryMB(args) == 1024);
}

void saveCachixDeploySpec(Package[] packages)
{
    auto agents = packages.filter!(pkg => pkg.isCached == false).map!(pkg => JSONValue([
            "package": pkg.name,
            "out": pkg.output
        ])).array;
    auto resPath = resultDir.buildPath("cachix-deploy-spec.json");
    resPath.write(JSONValue(agents).toString(JSONOptions.doNotEscapeSlashes));
}

@("saveCachixDeploySpec")
unittest
{
    import std.file : rmdirRecurse;

    createResultDirs();
    saveCachixDeploySpec(cast(Package[]) testPackageArray);
    JSONValue deploySpec = parseJSON(resultDir.buildPath("cachix-deploy-spec.json").readText);
    assert(testPackageArray[1].name == deploySpec[0]["package"].str);
    assert(testPackageArray[1].output == deploySpec[0]["out"].str);
}

void saveGHCIMatrix(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    auto matrix = JSONValue([
        "include": JSONValue(packages.map!(pkg => pkg.toJSON()).array)
    ]);
    string resPath = rootDir.buildPath(args.isInitial ? "matrix-pre.json" : "matrix-post.json");
    resPath.write(JSONValue(matrix).toString(JSONOptions.doNotEscapeSlashes));
}

@("saveGHCIMatrix")
unittest
{
    import std.file : rmdirRecurse;

    createResultDirs();
    CiMatrixArgs args;
    args.isInitial = false;
    saveGHCIMatrix(cast(Package[]) testPackageArray, args);
    JSONValue matrix = rootDir
        .buildPath(args.isInitial ? "matrix-pre.json" : "matrix-post.json")
        .readText
        .parseJSON;
    assert(testPackageArray[0].name == matrix["include"][0]["name"].str);
}

void saveGHCIComment(SummaryTableEntry[] tableSummaryJSON)
{
    import std.path : buildNormalizedPath, absolutePath;

    string comment = "Thanks for your Pull Request!";
    comment ~= "\n\nBelow you will find a summary of the cachix status of each package, for each supported platform.";
    comment ~= "\n\n| package | `x86_64-linux` | `x86_64-darwin` | `aarch64-darwin` |";
    comment ~= "\n| ------- | -------------- | --------------- | ---------------- |";
    comment ~= tableSummaryJSON.map!(
        pkg => "\n| " ~ pkg.name ~ " | " ~ pkg.x86_64.linux ~ " | " ~ pkg.x86_64.darwin ~ " | " ~ pkg.aarch64.darwin ~ " |")
        .join("");

    auto outputPath = rootDir.buildNormalizedPath("comment.md");
    write(outputPath, comment);
    infof("Wrote GitHub comment file to '%s'", outputPath);
}

@("saveGHCIComment")
unittest
{
    import std.file : rmdirRecurse;

    createResultDirs();
    saveGHCIComment(cast(SummaryTableEntry[]) testSummaryTableEntryArray);
    string comment = rootDir.buildPath("comment.md").readText;
    foreach (pkg; testSummaryTableEntryArray)
    {
        assert(comment.indexOf(pkg.name) != -1);
        assert(comment.indexOf(pkg.x86_64.linux) != -1);
        assert(comment.indexOf(pkg.x86_64.darwin) != -1);
        assert(comment.indexOf(pkg.aarch64.darwin) != -1);
    }
}

string getStatus(JSONValue pkg, string key, bool isInitial)
{
    if (key in pkg)
    {
        if (pkg[key]["isCached"].boolean)
        {
            return "[✅ cached](" ~ pkg[key]["cacheUrl"].str ~ ")";
        }
        else if (isInitial)
        {
            return "⏳ building...";
        }
        else
        {
            return "❌ build failed";
        }
    }
    else
    {
        return "🚫 not supported";
    }
}

SummaryTableEntry[] convertNixEvalToTableSummary(
    const Package[] packages,
    bool isInitial
)
{

    SummaryTableEntry[] tableSummary = packages
        .chunkBy!((a, b) => a.name == b.name)
        .map!((group) {
            JSONValue pkg;
            string name = group.array.front.name;
            pkg["name"] = JSONValue(name);
            foreach (item; group)
            {
                pkg[item.system.to!string] = item.toJSON();
            }
            SummaryTableEntry entry = {
                name, {
                    getStatus(pkg, "x86_64_linux", isInitial),
                    getStatus(pkg, "x86_64_darwin", isInitial)
                }, {
                    getStatus(pkg, "aarch64_darwin", isInitial)
                }
            };
            return entry;
        })
        .array
        .sort!((a, b) => a.name < b.name)
        .release;
    return tableSummary;
}

@("convertNixEvalToTableSummary/getStatus")
unittest
{
    auto tableSummary = convertNixEvalToTableSummary(
        testPackageArray,
        isInitial: false
    );
    assert(tableSummary[0].name == testPackageArray[0].name);
    assert(tableSummary[0].x86_64.linux == "[✅ cached](https://testPackage.com)");
    assert(tableSummary[0].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[0].aarch64.darwin == "🚫 not supported");
    assert(tableSummary[1].name == testPackageArray[1].name);
    assert(tableSummary[1].x86_64.linux == "🚫 not supported");
    assert(tableSummary[1].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[1].aarch64.darwin == "❌ build failed");

    tableSummary = convertNixEvalToTableSummary(
        testPackageArray,
        isInitial: true
    );
    assert(tableSummary[0].name == testPackageArray[0].name);
    assert(tableSummary[0].x86_64.linux == "[✅ cached](https://testPackage.com)");
    assert(tableSummary[0].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[0].aarch64.darwin == "🚫 not supported");
    assert(tableSummary[1].name == testPackageArray[1].name);
    assert(tableSummary[1].x86_64.linux == "🚫 not supported");
    assert(tableSummary[1].x86_64.darwin == "🚫 not supported");
    assert(tableSummary[1].aarch64.darwin == "⏳ building...");

}

void printTableForCacheStatus(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    static if (is(T == PrintTableArgs)) {
        if (args.precalcMatrix == "")
        {
            saveGHCIMatrix(packages, args);
        }
    }
    saveCachixDeploySpec(packages);
    saveGHCIComment(convertNixEvalToTableSummary(packages, args.isInitial));
}

Package checkPackage(T)(Package pkg, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    import std.algorithm : canFind;
    import std.string : lineSplitter;
    import std.net.curl : HTTP, httpGet = get, HTTPStatusException;

    auto http = HTTP();
    http.addRequestHeader("Authorization", "Bearer " ~ args.cachixAuthToken);

    try
    {
        pkg.isCached = httpGet(pkg.cacheUrl, http)
            .lineSplitter
            .canFind("StorePath: " ~ pkg.output);
    }
    catch (HTTPStatusException e)
    {
        if (e.status == 404)
            pkg.isCached = false;
        else
            throw e;
    }

    return pkg;
}

@("checkPackage")
unittest
{
    const nixosCacheEndpoint = "https://cache.nixos.org/";
    const storePathHash = "mdb034kf7sq6g03ric56jxr4a7043l41";
    const storePath = "/nix/store/" ~ storePathHash ~ "-hello-2.12.1";

    auto testPackage = Package(
        output: storePath,
        cacheUrl: nixosCacheEndpoint ~ storePathHash ~ ".narinfo",
    );

    CiMatrixArgs args;
    args.cachixAuthToken = "";

    assert(!testPackage.isCached);
    assert(checkPackage(testPackage, args).isCached);

    testPackage.cacheUrl = nixosCacheEndpoint ~ "nonexistent.narinfo";

    assert(!checkPackage(testPackage, args).isCached);
}

Package[] getPrecalcMatrix(PrintTableArgs args)
{
    auto precalcMatrixStr = args.precalcMatrix == "" ? "{\"include\": []}" : args.precalcMatrix;
    return parseJSON(precalcMatrixStr)["include"].array.map!((pkg) {
        Package result = {
            name: pkg["name"].str,
            allowedToFail: pkg["allowedToFail"].boolean,
            attrPath: pkg["attrPath"].str,
            cacheUrl: pkg["cacheUrl"].str,
            isCached: pkg["isCached"].boolean,
            os: getGHOS(pkg["os"].str),
            system: getSystem(pkg["system"].str),
            output: pkg["output"].str};
            return result;
        }).array;
}
