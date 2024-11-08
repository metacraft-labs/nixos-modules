module mcl.commands.ci_matrix;

import std.stdio : writeln, stderr, stdout;
import std.traits : EnumMembers;
import std.string : indexOf, splitLines;
import std.algorithm : map, filter, reduce, chunkBy, find, any, sort, startsWith, each, canFind, fold;
import std.file : write, readText;
import std.range : array, front, join, split;
import std.conv : to;
import std.json : JSONValue, parseJSON, JSONOptions;
import core.cpuid : threadsPerCPU;
import std.path : buildPath;
import std.process : pipeProcess, wait, Redirect, kill;
import std.exception : enforce;
import std.format : fmt = format;
import std.logger : tracef, infof, errorf, warningf;

import mcl.utils.env : optional, MissingEnvVarsException, parseEnv;
import mcl.utils.string : enumToString, StringRepresentation, MaxWidth, writeRecordAsTable;
import mcl.utils.json : toJSON;
import mcl.utils.path : rootDir, resultDir, gcRootsDir, createResultDirs;
import mcl.utils.process : execute;
import mcl.utils.nix : nix, remoteStoreURL, extractHashFromNixStorePath;
import mcl.utils.cachix : cachixNixStoreUrl;

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
    GitHubOS os;
    SupportedSystem system;
    string derivation;
    string output;

    bool isCached() const => this.cacheUrl != null;
}

version (unittest)
{
    static immutable Package[] testPackageArray = [
        Package("testPackage", false, "testPackagePath", "https://testPackage.com", GitHubOS.ubuntuLatest, SupportedSystem.x86_64_linux, "testPackageOutput"),
        Package("testPackage2", true, "testPackagePath2", null, GitHubOS.macos14, SupportedSystem
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

immutable Params params;

version (unittest) {} else
shared static this()
{
    params = parseEnv!Params;
}

export void ci_matrix()
{
    createResultDirs();
    nixEvalForAllSystems(params.nixCaches).array.printTableForCacheStatus();
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

Package[] checkCacheStatus(Package[] packages, in NixCache[] caches)
{
    import std.array : appender;
    import std.parallelism : parallel;

    foreach (ref pkg; packages.parallel)
    {
        pkg = checkPackage(pkg, caches);
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

export void print_table()
{
    createResultDirs();

    getPrecalcMatrix()
        .checkCacheStatus(params.nixCaches)
        .printTableForCacheStatus();
}

struct Params
{
    @optional() string flakePre;
    @optional() string flakePost;
    @optional() string precalcMatrix;
    @optional() int maxWorkers;
    @optional() int maxMemory;
    @optional() bool isInitial;
    string cachixCache;
    string cachixAuthToken;

    void setup()
    {
        if (this.flakePre == "")
            this.flakePre = "checks";
    }

    NixCache[] nixCaches() const
    {
        return [
            NixCache(cachixNixStoreUrl(this.cachixCache), this.cachixAuthToken),
            NixCache("https://cache.nixos.org", null),
        ];
    }
}

struct NixCache {
    string endpoint;
    string authToken;
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
        "this is likely due to the use of the legacy table type."
    ];

Package packageFromNixEvalJobsJson(
    JSONValue json,
    string flakeAttrPrefix,
)
{
    return Package(
        name: json["attr"].str,
        allowedToFail: false,
        attrPath: flakeAttrPrefix ~ "." ~ json["attr"].str,
        system: getSystem(json["system"].str),
        os: systemToGHPlatform(getSystem(json["system"].str)),
        derivation: json["drvPath"].str,
        output: json["outputs"]["out"].str,
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
        );
        assert(testPackage == Package(
            name: "home/bean-desktop",
            allowedToFail: false,
            attrPath: "legacyPackages.x86_64-linux.mcl.matrix.shards.0.home/bean-desktop",
            system: SupportedSystem.x86_64_linux,
            os: GitHubOS.selfHosted,
            derivation: "/nix/store/jp7qgm9mgikksypzljrbhmxa31xmmq1x-home-manager-generation.drv",
            output: "/nix/store/30qrziyj0vbg6n43bbh08ql0xbnsy76d-home-manager-generation",
        ));
    }
}

Package[] nixEvalJobs(string flakeAttrPrefix, in NixCache[] caches, bool doCheck = true)
{
    Package[] result = [];

    int maxMemoryMB = getAvailableMemoryMB();
    int maxWorkers = getNixEvalWorkerCount();

    const args = [
        "nix-eval-jobs", "--quiet", "--option", "warn-dirty", "false",
        "--check-cache-status", "--gc-roots-dir", gcRootsDir, "--workers",
        maxWorkers.to!string, "--max-memory-size", maxMemoryMB.to!string,
        "--flake", rootDir ~ "#" ~ flakeAttrPrefix
    ];

    const commandString = args.join(" ");

    tracef("%-(%s %)", args);

    auto pipes = pipeProcess(args, Redirect.stdout | Redirect.stderr);

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

        Package pkg = json.packageFromNixEvalJobsJson(flakeAttrPrefix);

        if (doCheck)pkg = pkg.checkPackage(caches);

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
        .filter!(line => !uselessWarnings.canFind(line))
        .join("\n");

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

Package[] nixEvalForAllSystems(in NixCache[] caches)
{
    const systems = getSupportedSystems();

    infof("Evaluating flake for: %s", systems);

    return systems.map!(system =>
            flakeAttr(params.flakePre, system, params.flakePost)
                .nixEvalJobs(caches)
        )
        .reduce!((a, b) => a ~ b)
        .array
        .sort!((a, b) => a.name < b.name)
        .array;
}

int getNixEvalWorkerCount()
{
    return params.maxWorkers == 0 ? (threadsPerCPU() < 8 ? threadsPerCPU() : 8) : params.maxWorkers;
}

@("getNixEvalWorkerCount")
unittest
{
    assert(getNixEvalWorkerCount() == (threadsPerCPU() < 8 ? threadsPerCPU() : 8));
}

int getAvailableMemoryMB()
{

    // free="$(< /proc/meminfo grep MemFree | tr -s ' ' | cut -d ' ' -f 2)"
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
    int maxMemoryMB = params.maxMemory == 0 ? ((free + cached + buffers + shmem) / 1024)
        : params.maxMemory;
    return maxMemoryMB;
}

@("getAvailableMemoryMB")
unittest
{
    assert(getAvailableMemoryMB() > 0);
}

void saveGHCIMatrix(Package[] packages)
{
    auto matrix = JSONValue([
        "include": JSONValue(packages.map!(pkg => pkg.toJSON()).array)
    ]);
    string resPath = rootDir.buildPath(params.isInitial ? "matrix-pre.json" : "matrix-post.json");
    resPath.write(JSONValue(matrix).toString(JSONOptions.doNotEscapeSlashes));
}

@("saveGHCIMatrix")
unittest
{
    import std.file : rmdirRecurse;

    createResultDirs();
    saveGHCIMatrix(cast(Package[]) testPackageArray);
    JSONValue matrix = rootDir
        .buildPath(params.isInitial ? "matrix-pre.json" : "matrix-post.json")
        .readText
        .parseJSON;
    assert(testPackageArray[0].name == matrix["include"][0]["name"].str);
}

void saveGHCIComment(in SummaryTableEntry[] tableSummaryJSON)
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
    saveGHCIComment(testSummaryTableEntryArray);
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
        const cacheUrl = pkg[key]["cacheUrl"].str;
        if (cacheUrl != null)
        {
            return "[✅ cached](" ~ cacheUrl ~ ")";
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

void printTableForCacheStatus(Package[] packages)
{
    if (params.precalcMatrix == "")
    {
        saveGHCIMatrix(packages);
    }
    saveGHCIComment(convertNixEvalToTableSummary(packages, params.isInitial));
}

Package checkPackage(Package pkg, in NixCache[] caches)
{
    import std.algorithm : canFind;
    import std.string : lineSplitter;
    import std.net.curl : HTTP, httpGet = get, HTTPStatusException;

    if (pkg.isCached) return pkg;

    const storeHash = extractHashFromNixStorePath(pkg.output);

    foreach (cache; caches)
    {
        if (pkg.isCached) break;

        auto http = HTTP();
        const cacheUrl = remoteStoreURL(cache.endpoint, storeHash);

        if (cache.authToken != null)
        {
            http.addRequestHeader("Authorization", "Bearer " ~ cache.authToken);
        }

        try
        {
            const isCached = httpGet(cacheUrl, http)
                .lineSplitter
                .canFind("StorePath: " ~ pkg.output);

            pkg.cacheUrl = isCached
                ? cacheUrl
                : null;
        }
        catch (HTTPStatusException e)
        {
            if (e.status != 404)
                throw e;
        }
    }

    return pkg;
}

@("checkPackage")
unittest
{
    const nixosCacheEndpoint = "https://cache.nixos.org";
    const storePathHash = "mdb034kf7sq6g03ric56jxr4a7043l41";
    const storePath = "/nix/store/" ~ storePathHash ~ "-hello-2.12.1";

    auto testPackage = Package(output: storePath);

    assert(!testPackage.isCached);
    assert(checkPackage(testPackage, [NixCache(nixosCacheEndpoint, null)]).isCached);

    testPackage.cacheUrl = null;
    assert(!checkPackage(testPackage, [NixCache(nixosCacheEndpoint ~ "/nonexistent", null)]).isCached);
}

Package[] getPrecalcMatrix()
{
    auto precalcMatrixStr = params.precalcMatrix == "" ? "{\"include\": []}" : params.precalcMatrix;
    enforce!MissingEnvVarsException(
        params.precalcMatrix != "",
        "missing environment variables: %s".fmt("precalcMatrix")
    );
    return parseJSON(precalcMatrixStr)["include"].array.map!((pkg) {
        Package result = {
            name: pkg["name"].str,
            allowedToFail: pkg["allowedToFail"].boolean,
            attrPath: pkg["attrPath"].str,
            os: getGHOS(pkg["os"].str),
            system: getSystem(pkg["system"].str),
            output: pkg["output"].str,
            cacheUrl: pkg["cacheUrl"].str,
        };
        return result;
    }).array;
}
