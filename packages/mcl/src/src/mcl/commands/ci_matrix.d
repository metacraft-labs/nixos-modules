module mcl.commands.ci_matrix;

import std.stdio : writeln, stderr, stdout;
import std.traits : EnumMembers;
import std.string : indexOf, splitLines;
import std.algorithm : map, filter, reduce, chunkBy, find, any, sort, startsWith, each, canFind, fold;
import std.file : write, readText;
import std.range : array, front, join, split;
import std.conv : to;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.regex : matchFirst;
import core.cpuid : threadsPerCPU;
import std.path : buildPath;
import std.process : pipeProcess, wait, Redirect, kill;
import std.exception : enforce, assumeUnique;
import std.format : fmt = format;
import std.logger : tracef, infof, errorf, warningf;

import mcl.utils.env : optional, MissingEnvVarsException, parseEnv;
import mcl.utils.string : enumToString, StringRepresentation, MaxWidth, writeRecordAsTable;
import mcl.utils.json : toJSON;
import mcl.utils.path : rootDir, resultDir, gcRootsDir, createResultDirs;
import mcl.utils.process : execute;
import mcl.utils.nix : nix;

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

immutable GitHubOS[string] osMap;

shared static this()
{
    import std.exception : assumeUnique;
    import std.conv : to;

    GitHubOS[string] temp = [
        "ubuntu-latest": GitHubOS.ubuntuLatest,
        "self-hosted": GitHubOS.selfHosted,
        "macos-14": GitHubOS.macos14
    ];
    temp.rehash;

    osMap = assumeUnique(temp);
}

GitHubOS getGHOS(string os)
{
    return os in osMap ? osMap[os] : GitHubOS.selfHosted;
}

void assertGHOS(string input, GitHubOS expected)
{
    auto actual = getGHOS(input);
    assert(actual == expected, fmt("getGHOS(\"%s\") should return %s, but returned %s", input, expected, actual));
}

@("getGHOS")
unittest
{
    assertGHOS("ubuntu-latest", GitHubOS.ubuntuLatest);
    assertGHOS("macos-14", GitHubOS.macos14);
    assertGHOS("crazyos-inator-2000", GitHubOS.selfHosted);
}

immutable SupportedSystem[string] systemMap;

shared static this()
{
    import std.exception : assumeUnique;
    import std.conv : to;

    SupportedSystem[string] temp = [
        "x86_64-linux": SupportedSystem.x86_64_linux,
        "x86_64-darwin": SupportedSystem.x86_64_darwin,
        "aarch64-darwin": SupportedSystem.aarch64_darwin
    ];
    temp.rehash;

    systemMap = assumeUnique(temp);
}

SupportedSystem getSystem(string system)
{
    return system in systemMap ? systemMap[system] : SupportedSystem.x86_64_linux;
}

void assertSystem(string input, SupportedSystem expected)
{
    auto actual = getSystem(input);
    assert(actual == expected, fmt("getSystem(\"%s\") should return %s, but returned %s", input, expected, actual));
}

@("getSystem")
unittest
{
    assertSystem("x86_64-linux", SupportedSystem.x86_64_linux);
    assertSystem("x86_64-darwin", SupportedSystem.x86_64_darwin);
    assertSystem("aarch64-darwin", SupportedSystem.aarch64_darwin);
    assertSystem("bender-bending-rodriguez-os", SupportedSystem.x86_64_linux);
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

enum Status : string
{
    cached = "✅ cached",
    notSupported = "🚫 not supported",
    building = "⏳ building...",
    buildFailed = "❌ build failed"
}

version (unittest)
{
    static immutable SummaryTableEntry[] testSummaryTableEntryArray = [
        SummaryTableEntry("testPackage",
            SummaryTableEntry_x86_64(Status.cached, Status.cached),
            SummaryTableEntry_aarch64(Status.notSupported)),
        SummaryTableEntry("testPackage2",
            SummaryTableEntry_x86_64(Status.building, Status.buildFailed),
            SummaryTableEntry_aarch64(Status.building))
    ];
}

Params params;

version (unittest) {} else
shared static this()
{
    params = parseEnv!Params;
}

export void ci_matrix()
{
    createResultDirs();
    nixEvalForAllSystems().array.printTableForCacheStatus();
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

Package[] checkCacheStatus(Package[] packages)
{
    import std.array : appender;
    import std.parallelism : parallel;

    foreach (ref pkg; packages.parallel)
    {
        pkg = checkPackage(pkg);
        struct Output
        {
            string isCached, name, storePath;
        }

        auto res = appender!string;
        writeRecordAsTable(
            Output(pkg.isCached ? "✅" : "❌", pkg.name, pkg.output),
            res
        );
        tracef("%s", res.data[0 .. $ - 1]);
    }
    return packages;
}

export void print_table()
{
    createResultDirs();

    getPrecalcMatrix()
        .checkCacheStatus()
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
}

GitHubOS systemToGHPlatform(SupportedSystem os) =>
    os == SupportedSystem.x86_64_linux ? GitHubOS.selfHosted : GitHubOS.macos14;

void assertGHPlatform(SupportedSystem system, GitHubOS expected)
{
    auto actual = systemToGHPlatform(system);
    assert(actual == expected, fmt("`systemToGHPlatform(%s)` should return `%s`, but returned `%s`", system, expected, actual));
}

@("systemToGHPlatform")
unittest
{
    assertGHPlatform(SupportedSystem.x86_64_linux, GitHubOS.selfHosted);
    assertGHPlatform(SupportedSystem.x86_64_darwin, GitHubOS.macos14);
    assertGHPlatform(SupportedSystem.aarch64_darwin, GitHubOS.macos14);
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

Package[] nixEvalJobs(string flakeAttrPrefix, string cachixUrl, bool doCheck = true)
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

        Package pkg = json.packageFromNixEvalJobsJson(
            flakeAttrPrefix, cachixUrl);

        if (doCheck)pkg = pkg.checkPackage();

        result ~= pkg;

        struct Output {
            bool isCached;
            GitHubOS os;
            @MaxWidth(50) string attr;
            @MaxWidth(80) string output;
        }

        Output output = {
            isCached: pkg.isCached,
            os: pkg.os,
            attr: pkg.attrPath,
            output: pkg.output
        };
        output.writeRecordAsTable(stderr.lockingTextWriter);
        return errorsReported;
    })(false);

    const stderrLogs = pipes.stderr.byLine
        .filter!(line => !uselessWarnings.any!(w => line.canFind(w)))
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

Package[] nixEvalForAllSystems()
{
    const cachixUrl = "https://" ~ params.cachixCache ~ ".cachix.org";
    const systems = getSupportedSystems();

    infof("Evaluating flake for: %s", systems);

    return systems.map!(system =>
            flakeAttr(params.flakePre, system, params.flakePost)
                .nixEvalJobs(cachixUrl)
        )
        .reduce!((a, b) => a ~ b)
        .array
        .sort!((a, b) => a.name < b.name)
        .array;
}

static const MAX_WORKERS = 8;

int getNixEvalWorkerCount()
{
    return params.maxWorkers == 0 ? (threadsPerCPU() < MAX_WORKERS ? threadsPerCPU() : MAX_WORKERS)
        : params.maxWorkers;
}

@("getNixEvalWorkerCount")
unittest
{
    auto actual = getNixEvalWorkerCount();
    assert(actual == (threadsPerCPU() < MAX_WORKERS ? threadsPerCPU() : MAX_WORKERS),
        "getNixEvalWorkerCount() should return the number of threads per CPU if it is less than MAX_WORKERS, otherwise it should return MAX_WORKERS, but returned %s".fmt(actual));
}

string[] meminfo;

int getMemoryStat(string statName, string excludeName = "EXCLUDE")
{
    return meminfo
        .find!(a => a.indexOf(statName) != -1 && a.indexOf(excludeName) == -1)
        .front
        .split[1].to!int;
}

int getAvailableMemoryMB()
{
    meminfo = "/proc/meminfo".readText
        .splitLines;

    int free = getMemoryStat("MemFree");
    int cached = getMemoryStat("Cached", "SwapCached");
    int buffers = getMemoryStat("Buffers");
    int shmem = getMemoryStat("Shmem:");
    int maxMemoryMB = params.maxMemory == 0 ? ((free + cached + buffers + shmem) / 1024)
        : params.maxMemory;
    return maxMemoryMB;
}

@("getAvailableMemoryMB")
unittest
{
    // Test when params.maxMemory is 0
    params.maxMemory = 0;
    auto actual = getAvailableMemoryMB();
    assert(actual > 0, "getAvailableMemoryMB() should return a value greater than 0, but returned %s".fmt(actual));

    // Test when params.maxMemory is not 0
    params.maxMemory = 1024;
    actual = getAvailableMemoryMB();
    assert(actual == 1024, "getAvailableMemoryMB() should return 1024, but returned %s".fmt(actual));
}

void saveCachixDeploySpec(Package[] packages)
{
    auto agents = packages.filter!(pkg => pkg.isCached == false)
        .map!(pkg => JSONValue([
                    "package": pkg.name,
                    "out": pkg.output
                ]))
        .array;
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
    string testPackageName = testPackageArray[1].name;
    string deploySpecName = deploySpec[0]["package"].str;
    string testPackageOutput = testPackageArray[1].output;
    string deploySpecOutput = deploySpec[0]["out"].str;
    assert(testPackageName == deploySpecName,
        "The name of the package should be %s, but was %s".fmt(testPackageName, deploySpecName));
    assert(testPackageOutput == deploySpecOutput,
        "The output of the package should be %s, but was %s".fmt(testPackageOutput, deploySpecOutput));
}

void saveGHCIMatrix(Package[] packages)
{
    auto matrix = createMatrix(packages);
    writeMatrix(matrix);
}

JSONValue createMatrix(Package[] packages)
{
    return JSONValue([
        "include": JSONValue(packages.map!(pkg => pkg.toJSON()).array)
    ]);
}

void writeMatrix(JSONValue matrix)
{
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
    foreach (i, pkg; testPackageArray)
    {
        string pkgName = pkg.name;
        string matrixName = matrix["include"][i]["name"].str;
        assert(pkgName == matrixName,
            "The name of the package should be %s, but was %s".fmt(pkgName, matrixName));
    }
}

void saveGHCIComment(SummaryTableEntry[] tableSummaryJSON)
{
    string comment = createComment(tableSummaryJSON);
    writeComment(comment);
}

string createComment(SummaryTableEntry[] tableSummaryJSON)
{
    string comment = "Thanks for your Pull Request!";
    comment ~= "\n\nBelow you will find a summary of the cachix status of each package, for each supported platform.";
    comment ~= "\n\n| package | `x86_64-linux` | `x86_64-darwin` | `aarch64-darwin` |";
    comment ~= "\n| ------- | -------------- | --------------- | ---------------- |";
    comment ~= tableSummaryJSON.map!(
        pkg => "\n| " ~ pkg.name ~ " | " ~ pkg.x86_64.linux ~ " | " ~ pkg.x86_64.darwin ~ " | " ~ pkg.aarch64.darwin ~ " |")
        .join("");
    return comment;
}

void writeComment(string comment)
{
    import std.path : buildNormalizedPath, absolutePath;

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
        assert(comment.indexOf(pkg.name) != -1,
            "The comment should contain the package name %s, the comment is:\n%s".fmt(pkg.name, comment));
        assert(comment.indexOf(pkg.x86_64.linux) != -1,
            "The comment should contain the x86_64 linux status %s, the comment is:\n%s".fmt(pkg.x86_64.linux, comment));
        assert(comment.indexOf(pkg.x86_64.darwin) != -1,
            "The comment should contain the x86_64 darwin status %s, the comment is:\n%s".fmt(pkg.x86_64.darwin, comment));
        assert(comment.indexOf(pkg.aarch64.darwin) != -1,
            "The comment should contain the aarch64 darwin status %s, the comment is:\n%s".fmt(pkg.aarch64.darwin, comment));
    }
}

string getStatus(JSONValue pkg, string key, bool isInitial)
{
    if (key in pkg)
    {
        if (pkg[key]["isCached"].boolean)
        {
            return "[" ~ Status.cached ~ "](" ~ pkg[key]["cacheUrl"].str ~ ")";
        }
        else if (isInitial)
        {
            return Status.building;
        }
        else
        {
            return Status.buildFailed;
        }
    }
    else
    {
        return Status.notSupported;
    }
}

SummaryTableEntry[] convertNixEvalToTableSummary(
    const Package[] packages,
    bool isInitial
)
{
    return packages
        .chunkBy!((a, b) => a.name == b.name)
        .map!(group => createSummaryTableEntry(group.array, isInitial))
        .array
        .sort!((a, b) => a.name < b.name)
        .release;
}

SummaryTableEntry createSummaryTableEntry(const(Package)[] group, bool isInitial)
{
    JSONValue pkg;
    string name = group.front.name;
    pkg["name"] = JSONValue(name);
    foreach (item; group)
        pkg[item.system.to!string] = item.toJSON();
    SummaryTableEntry entry = {
        name, {
            getStatus(pkg, "x86_64_linux", isInitial),
            getStatus(pkg, "x86_64_darwin", isInitial)
        }, {
            getStatus(pkg, "aarch64_darwin", isInitial)
        }
    };
    return entry;
}

void assertNixTable(SummaryTableEntry[] tableSummary, immutable(Package[]) testPackageArray, int index,
    string expectedLinuxStatus = "[" ~ Status.cached ~ "](https://testPackage.com)", string expectedDarwinStatus = Status.notSupported, string expectedAarch64Status = Status.notSupported)
{
    string actualName = tableSummary[index].name;
    string expectedName = testPackageArray[index].name;
    assert(actualName == expectedName, fmt("Expected name to be %s, but got %s", expectedName, actualName));

    string actualLinuxStatus = tableSummary[index].x86_64.linux;
    assert(actualLinuxStatus == expectedLinuxStatus, fmt("Expected Linux status to be %s, but got %s", expectedLinuxStatus, actualLinuxStatus));

    string actualDarwinStatus = tableSummary[index].x86_64.darwin;
    assert(actualDarwinStatus == expectedDarwinStatus, fmt("Expected Darwin status to be %s, but got %s", expectedDarwinStatus, actualDarwinStatus));

    string actualAarch64Status = tableSummary[index].aarch64.darwin;
    assert(actualAarch64Status == expectedAarch64Status, fmt("Expected Aarch64 Darwin status to be %s, but got %s", expectedAarch64Status, actualAarch64Status));
}

@("convertNixEvalToTableSummary/getStatus")
unittest
{
    auto tableSummary = convertNixEvalToTableSummary(
        testPackageArray,
        isInitial: false
    );
    assertNixTable(tableSummary, testPackageArray, 0);
    assertNixTable(tableSummary, testPackageArray, 1, Status.notSupported, Status.notSupported, Status.buildFailed);

    tableSummary = convertNixEvalToTableSummary(
        testPackageArray,
        isInitial: true
    );
    assertNixTable(tableSummary, testPackageArray, 0);
    assertNixTable(tableSummary, testPackageArray, 1, Status.notSupported, Status.notSupported, Status.building);
}

void printTableForCacheStatus(Package[] packages)
{
    if (params.precalcMatrix == "")
    {
        saveGHCIMatrix(packages);
    }
    saveCachixDeploySpec(packages);
    saveGHCIComment(convertNixEvalToTableSummary(packages, params.isInitial));
}

Package checkPackage(Package pkg)
{
    import std.algorithm : canFind;
    import std.string : lineSplitter;
    import std.net.curl : HTTP, httpGet = get, HTTPStatusException, CurlException;

    auto http = HTTP();
    http.addRequestHeader("Authorization", "Bearer " ~ params.cachixAuthToken);

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
    catch (CurlException e)
    {
        // Handle network errors
        pkg.isCached = false;
    }

    return pkg;
}

@("checkPackage")
unittest
{
    const nixosCacheEndpoint = "https://cache.nixos.org/";
    const storePathHash = "mdb034kf7sq6g03ric56jxr4a7043l41";
    const storePath = "/nix/store/" ~ storePathHash ~ "-hello-2.12.1";

    Package testPackage = {
        output: storePath,
        cacheUrl: nixosCacheEndpoint ~ storePathHash ~ ".narinfo",
    };

    assert(checkPackage(testPackage).isCached, "Package %s should be cached".fmt(testPackage.cacheUrl));

    testPackage.cacheUrl = nixosCacheEndpoint ~ "nonexistent.narinfo";

    assert(!checkPackage(testPackage).isCached, "Package %s should not be cached".fmt(testPackage.cacheUrl));
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
            cacheUrl: pkg["cacheUrl"].str,
            isCached: pkg["isCached"].boolean,
            os: getGHOS(pkg["os"].str),
            system: getSystem(pkg["system"].str),
            output: pkg["output"].str
        };
        return result;
    }).array;

}

@("getPrecalcMatrix")
unittest
{
    string precalcMatrixStr = "{\"include\": [{\"name\": \"test\", \"allowedToFail\": false, \"attrPath\": \"test\", \"cacheUrl\": \"url\", \"isCached\": true, \"os\": \"linux\", \"system\": \"x86_64-linux\", \"output\": \"output\"}]}";
    params.precalcMatrix = precalcMatrixStr;
    auto packages = getPrecalcMatrix();
    Package testPackage = {
        name: "test",
        allowedToFail: false,
        attrPath: "test",
        cacheUrl: "url",
        isCached: true,
        os: GitHubOS.selfHosted,
        system: SupportedSystem.x86_64_linux,
        output: "output"
    };
    assert(packages.length == 1);
    assert(packages[0].name == testPackage.name, "Expected %s, got %s".fmt(testPackage.name, packages[0].name));
    assert(!packages[0].allowedToFail, "Expected %s, got %s".fmt(testPackage.allowedToFail, packages[0].allowedToFail));
    assert(packages[0].attrPath == testPackage.attrPath, "Expected %s, got %s".fmt(testPackage.attrPath, packages[0].attrPath));
    assert(packages[0].cacheUrl == testPackage.cacheUrl, "Expected %s, got %s".fmt(testPackage.cacheUrl, packages[0].cacheUrl));
    assert(packages[0].isCached);
    assert(packages[0].os == testPackage.os, "Expected %s, got %s".fmt(testPackage.os, packages[0].os));
    assert(packages[0].system == testPackage.system, "Expected %s, got %s".fmt(testPackage.system, packages[0].system));
    assert(packages[0].output == testPackage.output, "Expected %s, got %s".fmt(testPackage.output, packages[0].output));
}
