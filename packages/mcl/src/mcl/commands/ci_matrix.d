module mcl.commands.ci_matrix;

import std.stdio : writeln, stderr, stdout;
import std.traits : EnumMembers;
import std.string : indexOf, splitLines, strip;
import std.algorithm : map, filter, reduce, chunkBy, find, any, sort, startsWith, each, canFind, fold;
import std.file : write, readText, dirEntries, SpanMode, append;
import std.range : array, enumerate, empty, front, indexed, join, chain, split;
import std.exception : ifThrown;
import std.conv : to;
import std.json : JSONValue, parseJSON, JSONOptions, JSONType;
import std.regex : matchFirst;
import core.cpuid : threadsPerCPU;
import std.path : buildPath;
import std.process : pipeProcess, wait, Redirect, kill;
import std.exception : enforce;
import std.format : fmt = format;
import std.logger : tracef, infof, errorf, warningf;

import argparse : Command, Description, NamedArgument, Placeholder, EnvFallback;

import mcl.utils.string : enumToString, StringRepresentation, MaxWidth, writeRecordAsTable;
import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.path : rootDir, resultDir, gcRootsDir, createResultDirs;
import mcl.utils.process : execute;
import mcl.utils.nix : nix;

import mcl.commands.ci: CiArgs;
import mcl.commands.deploy_spec: DeploySpecArgs;

version (OSX)
{
    import core.sys.darwin.mach.kern_return : KERN_SUCCESS;
    import core.sys.darwin.mach.port : mach_port_t;

    private alias vm_size_t = ulong;
    private alias natural_t = uint;
    private alias integer_t = int;
    private alias mach_msg_type_number_t = natural_t;

    private struct vm_statistics64_data_t
    {
        natural_t free_count;
        natural_t active_count;
        natural_t inactive_count;
        natural_t wire_count;
        ulong zero_fill_count;
        ulong reactivations;
        ulong pageins;
        ulong pageouts;
        ulong faults;
        ulong cow_faults;
        ulong lookups;
        ulong hits;
        ulong purges;
        natural_t purgeable_count;
        natural_t speculative_count;
        ulong decompressions;
        ulong compressions;
        ulong swapins;
        ulong swapouts;
        natural_t compressor_page_count;
        natural_t throttled_count;
        natural_t external_page_count;
        natural_t internal_page_count;
        ulong total_uncompressed_pages_in_compressor;
    }

    private enum HOST_VM_INFO64 = 4;
    private enum HOST_VM_INFO64_COUNT = cast(mach_msg_type_number_t)(
        vm_statistics64_data_t.sizeof / integer_t.sizeof);

    private extern (C) mach_port_t mach_host_self() nothrow @nogc;
    private extern (C) int host_statistics64(mach_port_t host, int flavor,
        void* host_info, mach_msg_type_number_t* count) nothrow @nogc;
    private extern (C) int host_page_size(mach_port_t host, vm_size_t* page_size) nothrow @nogc;
}

enum GitHubOS
{
    @StringRepresentation("ubuntu-latest") ubuntuLatest,
    @StringRepresentation("self-hosted") selfHosted,

    @StringRepresentation("macos-14") macos14,
}

enum SupportedSystem
{
    @StringRepresentation("x86_64-linux") x86_64_linux,

    @StringRepresentation("aarch64-linux") aarch64_linux,

    @StringRepresentation("x86_64-darwin") x86_64_darwin,

    @StringRepresentation("aarch64-darwin") aarch64_darwin,
}

version (linux)
{
    version (X86_64)
        enum currentSystem = SupportedSystem.x86_64_linux;
    else version (AArch64)
        enum currentSystem = SupportedSystem.aarch64_linux;
    else
        static assert (0, "Unsupported architecture");
}
else version (OSX)
{
    version (X86_64)
        enum currentSystem = SupportedSystem.x86_64_darwin;
    else version (AArch64)
        enum currentSystem = SupportedSystem.aarch64_darwin;
    else
        static assert (0, "Unsupported architecture");
}
else
    static assert (0, "Unsupported OS");

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
    string[] cachedAt = [];
    GitHubOS os;
    SupportedSystem system;
    string derivation;
    string output;

    string getNarInfoUrl(string binaryCacheHttpEndpoint) const
    {
        import mcl.utils.string : appendUrlPath;

        const storePathDigest = this.output.matchFirst("^/nix/store/(?P<hash>[^-]+)-")["hash"];

        return binaryCacheHttpEndpoint.appendUrlPath(storePathDigest) ~ ".narinfo";
    }
}

version (unittest)
{
    static immutable Package[] testPackageArray = [
        Package("testPackage", false, "testPackagePath", ["https://testPackage.com"], GitHubOS.ubuntuLatest, SupportedSystem.x86_64_linux, "testPackageOutput"),
        Package("testPackage2", true, "testPackagePath2", [], GitHubOS.macos14, SupportedSystem.aarch64_darwin, "testPackageOutput2")
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
    import std.conv : to;

    import argparse : Command, Description, NamedArgument, Required, Placeholder, EnvFallback;

    import mcl.utils.cachix : cachixNixStoreUrl;

    @(NamedArgument(["flake-attribute-path"])
        .Placeholder("flake.attr.path")
        .EnvFallback("FLAKE_ATTR_PATH")
    )
    string flakeAttrPath = "checks";

    @(NamedArgument(["max-workers"])
        .Placeholder("count")
    )
    int maxWorkers;

    @(NamedArgument(["max-memory"])
        .Placeholder("mb")
    )
    int maxMemory;

    @(NamedArgument(["is-initial"])
        .Description("Is this the initial run of the CI?")
        .EnvFallback("IS_INITIAL")
    )
    bool isInitial = true;

    @(NamedArgument(["cachix-cache"])
        .Placeholder("cache-name")
        .EnvFallback("CACHIX_CACHE")
        .Required()
    )
    string cachixCache;

    @(NamedArgument(["extra-cachix-caches"])
        .Placeholder("cache-name")
        .EnvFallback("EXTRA_CACHIX_CACHES")
    )
    string[] extraCachixCaches;

    @(NamedArgument(["extra-caches-urls"])
        .Placeholder("cache-url")
        .EnvFallback("EXTRA_CACHE_URLS")
    )
    string[] extraCacheUrls = ["https://cache.nixos.org"];

    string[] binaryCacheUrls() const
    {
        import std.algorithm.iteration : map;
        import std.range : array, chain;
        return (this.cachixCache ~ this.extraCachixCaches)
            .map!cachixNixStoreUrl
            .chain(this.extraCacheUrls)
            .array
            .to!(string[]);
    }

    @(NamedArgument(["cachix-auth-token"])
        .Placeholder("token")
        .EnvFallback("CACHIX_AUTH_TOKEN")
        .Required()
    )
    string cachixAuthToken;

    @(NamedArgument(["precalc-matrix"])
        .Placeholder("matrix")
        .EnvFallback("PRECALC_MATRIX")
    )
    string precalcMatrix = "";

    @(NamedArgument(["github-output"])
        .Placeholder("output")
        .Description("Output to GitHub Actions")
        .EnvFallback("GITHUB_OUTPUT")
    )
    string githubOutput;
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
}

export int ci_matrix(CiMatrixArgs args)
{
    auto packages = args.flakeAttrPath.startsWith("mcl.shard-matrix.result.shards")
        ? nixEvalJobs(args.flakeAttrPath, args)
        : nixEvalForAllSystems(args);

    printTableForCacheStatus(packages, args);

    return 0;
}

export int print_table(PrintTableArgs args)
{
    getPrecalcMatrix(args)
        .checkCacheStatus(args)
        .printTableForCacheStatus(args);

    return 0;
}

string flakeAttr(string prefix, SupportedSystem system, string[] attrs...)
{
    return [prefix, system.enumToString].chain(attrs).join(".");
}

Package[] checkCacheStatus(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    import std.array : appender;
    import std.parallelism : parallel;

    immutable string[string] cachixAuthHeaders = [
        "Authorization": "Bearer " ~ args.cachixAuthToken
    ];

    foreach (pkg; packages.parallel) {
        pkg.cachedAt ~= args.binaryCacheUrls.filter!(url => isPackageCached(pkg, url, cachixAuthHeaders)).array;

        struct Output { string isCached, name, storePath; }
        auto stringWriter = appender!string;
        writeRecordAsTable(
            Output(!pkg.cachedAt.empty ? "✅" : "❌", pkg.name, pkg.output),
            stringWriter,
        );
        tracef("%s", stringWriter.data);
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
    string flakeAttrPath,
)
{
    return Package(
        name: json["attr"].str,
        allowedToFail: false,
        attrPath: flakeAttrPath ~ "." ~ json["attr"].str,
        // WARN: The `isCached` property coming from `nix-eval-jobs` is
        //       insufficient as it just says if the package is cached
        //       "somewhere" (including in the local store)
        cachedAt: [],
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

        assert(
            testPackage.getNarInfoUrl("https://binary-cache.internal") ==
            "https://binary-cache.internal/30qrziyj0vbg6n43bbh08ql0xbnsy76d.narinfo"
        );
    }
}
Package[] nixEvalJobs(T)(string flakeAttrPath, auto ref T args)
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
        "--flake", rootDir ~ "#" ~ flakeAttrPath
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

    immutable string[string] cachixAuthHeaders = [
        "Authorization": "Bearer " ~ args.cachixAuthToken
    ];

    const errorsReported = pipes.stdout.byLine.fold!((errorsReported, line) {
        auto json = parseJSON(line);

        if (auto err = "error" in json)
        {
            logError((*err).str);
            return true;
        }

        Package pkg = json.packageFromNixEvalJobsJson(flakeAttrPath);

        checkCacheStatus([pkg], args);

        result ~= pkg;

        struct Output {
            bool isCached;
            GitHubOS os;
            @MaxWidth(50) string attr;
            @MaxWidth(80) string output;
        }

        Output(
            isCached: !pkg.cachedAt.empty,
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

    const json = nix.eval!JSONValue(flakeRef ~ `#mcl.shard-matrix.systemsToBuild`)
        .ifThrown(nix.eval!JSONValue(flakeRef ~ `#legacyPackages`, [
            "--apply",
            `builtins.attrNames`
        ]))
        .ifThrown(JSONValue([ currentSystem.enumToString ]));

    return json.array.map!(system => getSystem(system.str)).array;
}

Package[] nixEvalForAllSystems(T)(auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    const systems = getSupportedSystems();

    infof("Evaluating flake for: %s", systems);

    return systems.map!(system =>
            flakeAttr(args.flakeAttrPath, system)
                .nixEvalJobs(args)
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
    if (args.maxMemory != 0)
        return args.maxMemory;

    version (linux)
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
        return (free + cached + buffers - shmem) / 1024;
    }
    else version (OSX)
    {
        vm_statistics64_data_t vmStats;
        mach_msg_type_number_t count = HOST_VM_INFO64_COUNT;
        vm_size_t pageSize;

        auto host = mach_host_self();

        if (host_page_size(host, &pageSize) != KERN_SUCCESS)
            throw new Exception("Failed to get page size");

        if (host_statistics64(host, HOST_VM_INFO64, &vmStats, &count) != KERN_SUCCESS)
            throw new Exception("Failed to get VM statistics");

        // Available memory: free + inactive + speculative (pages that can be reclaimed)
        ulong availablePages = vmStats.free_count + vmStats.inactive_count + vmStats.purgeable_count + vmStats.speculative_count;
        ulong availableBytes = availablePages * pageSize;
        return cast(int)(availableBytes / (1024 * 1024));
    }
    else
    {
        static assert(false, "getAvailableMemoryMB not implemented for this platform");
    }
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
    // TODO: check if we really need to filter out the cached packages
    auto agents = packages
        .filter!(pkg => pkg.cachedAt.empty)
        .map!(pkg => JSONValue([
            "package": pkg.name,
            "out": pkg.output,
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
    assert(testPackageArray[1].name == deploySpec[0]["package"].str);
    assert(testPackageArray[1].output == deploySpec[0]["out"].str);
}

void saveGHCIMatrix(T)(Package[] packages, auto ref T args)
    if (is(T == CiMatrixArgs) || is(T == PrintTableArgs) || is(T == CiArgs) || is(T == DeploySpecArgs))
{
    auto matrix = JSONValue([
        "include": JSONValue(packages.map!toJSON.array)
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
        if (auto cachedAt = pkg[key]["cachedAt"].array)
            return fmt!"✅ Cached at %-(%s%||%)"(
                cachedAt
                    .enumerate()
                    .map!(t => "[<%s>](%s)".fmt(t.index, t.value.str))
            );

        if (isInitial)
            return "⏳ building...";

        return "❌ build failed";
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
                pkg[item.system.enumToString] = item.toJSON();
            }
            SummaryTableEntry entry = {
                name, {
                    getStatus(pkg, "x86_64-linux", isInitial),
                    getStatus(pkg, "x86_64-darwin", isInitial)
                }, {
                    getStatus(pkg, "aarch64-darwin", isInitial)
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
    assert(tableSummary[0].x86_64.linux == "✅ Cached at [<0>](https://testPackage.com)");
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
    assert(tableSummary[0].x86_64.linux == "✅ Cached at [<0>](https://testPackage.com)");
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
    createResultDirs();

    if (args.precalcMatrix == "")
    {
        saveGHCIMatrix(packages, args);
    }
    saveCachixDeploySpec(packages);
    saveGHCIComment(convertNixEvalToTableSummary(packages, args.isInitial));

    const buildMatrixLine = "build_matrix=" ~ JSONValue([
        "include": JSONValue(packages.map!toJSON.array)
    ]).toString(JSONOptions.doNotEscapeSlashes) ~ "\n";

    if (args.githubOutput != "")
    {
        args.githubOutput.append(buildMatrixLine);
    }
    else
    {
        createResultDirs();
        resultDir.buildPath("gh-output.env").append(buildMatrixLine);
    }
}

bool isPackageCached(in Package pkg, string binaryCacheHttpEndpoint, in string[string] httpHeaders = null)
{
    import std.algorithm : canFind;
    import std.string : lineSplitter;
    import std.net.curl : HTTP, httpGet = get, HTTPStatusException;

    auto http = HTTP();
    foreach (name, value; httpHeaders)
        http.addRequestHeader(name, value);

    try
    {
        return pkg.getNarInfoUrl(binaryCacheHttpEndpoint)
            .httpGet(http)
            .lineSplitter
            .canFind("StorePath: " ~ pkg.output);
    }
    catch (HTTPStatusException e)
    {
        if (e.status == 404)
            return false;
        else
            throw e;
    }
}

@("isPackageCached")
unittest
{
    const nixosCacheEndpoint = "https://cache.nixos.org/";
    const storePathHash = "mdb034kf7sq6g03ric56jxr4a7043l41";
    const storePath = "/nix/store/" ~ storePathHash ~ "-hello-2.12.1";

    auto testPackage = Package(
        output: storePath,
    );

    assert(testPackage.isPackageCached(
        binaryCacheHttpEndpoint: nixosCacheEndpoint,
        httpHeaders: string[string].init,
    ));

    testPackage.output ~= "non-existant";
    assert(!testPackage.isPackageCached(
        binaryCacheHttpEndpoint: nixosCacheEndpoint,
        httpHeaders: string[string].init,
    ));
}

Package[] getPrecalcMatrix(PrintTableArgs args)
{
    auto precalcMatrixStr = args.precalcMatrix == "" ? `{"include": []}` : args.precalcMatrix;
    return parseJSON(precalcMatrixStr)["include"].array.map!(fromJSON!Package).array;
}

@(Command("merge-ci-matrices", "merge_ci_matrices")
    .Description("Merge downloaded matrix-pre.json artifacts and emit GitHub outputs"))
struct MergeMatricesArgs
{
    @(NamedArgument(["github-output"])
        .Placeholder("output")
        .Description("Output to GitHub Actions")
        .EnvFallback("GITHUB_OUTPUT")
    )
    string githubOutput;
}

export int merge_ci_matrices(MergeMatricesArgs args)
{
    import std.algorithm : sort;
    import std.file : isFile;

    auto matrixFiles = dirEntries(".", "matrix-pre.json", SpanMode.depth)
        .filter!(entry => entry.isFile)
        .array
        .sort!((a, b) => a.name < b.name);

    if (matrixFiles.length == 0)
    {
        stderr.writeln("No matrix-pre.json artifacts found");
        return 1;
    }

    JSONValue[] filteredInclude;
    JSONValue[] fullInclude;

    foreach (entry; matrixFiles)
    {
        infof("Found matrix file: %s", entry.name);
        auto json = entry.name.readText.parseJSON;

        if (json.type != JSONType.object || !("include" in json) || json["include"].type != JSONType.array)
        {
            warningf("Skipping file with unexpected shape: %s", entry.name);
            continue;
        }

        foreach (pkg; json["include"].array)
        {
            fullInclude ~= pkg;
            if (pkg.type == JSONType.object && ("isCached" in pkg) && pkg["isCached"].type == JSONType.false_)
            {
                filteredInclude ~= pkg;
            }
        }
    }

    auto matrix = JSONValue([
        "include": JSONValue(filteredInclude)
    ]);

    auto fullMatrix = JSONValue([
        "include": JSONValue(fullInclude)
    ]);

    const matrixStr = matrix.toString(JSONOptions.doNotEscapeSlashes);
    const fullMatrixStr = fullMatrix.toString(JSONOptions.doNotEscapeSlashes);

    auto outputPath = args.githubOutput;
    if (outputPath == "")
    {
        createResultDirs();
        outputPath = resultDir.buildPath("gh-output.env");
    }

    outputPath.append("build_matrix=" ~ matrixStr ~ "\n");
    outputPath.append("full_matrix=" ~ fullMatrixStr ~ "\n");

    writeln("---");
    writeln("Matrix:");
    writeln(matrixStr);
    writeln("---\n");

    writeln("---");
    writeln("Full Matrix:");
    writeln(fullMatrixStr);
    writeln("---");

    return 0;
}
