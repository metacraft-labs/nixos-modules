module mcl.commands.ci_matrix;

import std.stdio: writeln, stderr, stdout;
import std.traits: EnumMembers;
import std.string: indexOf, splitLines;
import std.algorithm: map, filter, reduce, chunkBy, find, any, sort, startsWith;
import std.file: write, readText;
import std.range: array, front, join, split;
import std.conv: to;
import std.json: JSONValue, parseJSON, JSONOptions;
import std.regex: matchFirst;
import core.cpuid: threadsPerCPU;
import std.process: pipeProcess, wait, Redirect, kill;
import std.exception : enforce;
import std.format : fmt = format;

import mcl.utils.env: optional, MissingEnvVarsException, parseEnv;
import mcl.utils.string: enumToString, StringRepresentation;
import mcl.utils.json: toJSON;
import mcl.utils.path: rootDir, resultDir, gcRootsDir, createResultDirs;
import mcl.utils.process: execute;

enum GitHubOS {
    @StringRepresentation("ubuntu-latest")
    ubuntuLatest,

    @StringRepresentation("macos-14")
    macos14
}
enum SupportedSystem {
    @StringRepresentation("x86_64-linux")
    x86_64_linux,

    @StringRepresentation("x86_64-darwin")
    x86_64_darwin,

    @StringRepresentation("aarch64-darwin")
    aarch64_darwin
}

GitHubOS getGHOS(string os) {
    switch (os) {
        case "ubuntu-latest":
            return GitHubOS.ubuntuLatest;
        case "macos-14":
            return GitHubOS.macos14;
        default:
            return GitHubOS.ubuntuLatest;
    }
}
SupportedSystem getSystem(string system) {
    switch (system) {
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

struct Package {
    string name;
    bool allowedToFail = false;
    string attrPath;
    string cacheUrl;
    bool isCached;
    GitHubOS os;
    SupportedSystem system;
    string output;
}

struct Matrix {
    Package[] include;
}

struct SummaryTableEntry_x86_64 {
    string linux;
    string darwin;
}
struct SummaryTableEntry_aarch64 {
    string darwin;
}
struct SummaryTableEntry {
    string name;
    SummaryTableEntry_x86_64 x86_64;
    SummaryTableEntry_aarch64 aarch64;
}

int exit_code = 0;

Params params;

export void ci_matrix() {
    params = parseEnv!Params;

    createResultDirs();
    nixEvalForAllSystems().printTableForCacheStatus();
}
export void print_table() {
    params = parseEnv!Params;

    createResultDirs();
    curlCheck([]);
}
struct Params {
    @optional() string flakePre;
    @optional() string flakePost;
    @optional() string precalcMatrix;
    @optional() int maxWorkers;
    @optional() int maxMemory;
    @optional() bool isInitial;
    string cachixCache;
    string cachixAuthToken;

    void setup() {
    }
}

GitHubOS systemToGHPlatform(SupportedSystem os) {
    return os == SupportedSystem.x86_64_linux ? GitHubOS.ubuntuLatest : GitHubOS.macos14;
}

static immutable string[] uselessWarnings =
    ["allowed-users", "trusted-users", "bash-prompt-prefix"].map!(setting => "warning: unknown setting '"~ setting ~"'").array ~
    ["SQLite database",
    "trace: warning: The legacy table is outdated and should not be used. We recommend using the gpt type instead.",
    "Please note that certain features, such as the test framework, may not function properly with the legacy table type.",
    "If you encounter errors similar to:",
    "error: The option `disko.devices.disk.disk1.content.partitions",
    "this is likely due to the use of the legacy table type."];

Package[] nixEvalJobs(SupportedSystem system, string cachixUrl) {
    string flakeAttr = params.flakePre ~ "." ~ system.enumToString() ~ params.flakePost;
    Package[] result = [];

    int maxMemoryMB = getAvailableMemoryMB();
    int maxWorkers = getNixEvalWorkerCount();
    auto pipes = pipeProcess(["nix-eval-jobs", "--quiet", "--option","warn-dirty","false", "--check-cache-status", "--gc-roots-dir",gcRootsDir, "--workers",maxWorkers.to!string, "--max-memory-size",maxMemoryMB.to!string, "--flake",rootDir~"#"~flakeAttr], Redirect.stdout | Redirect.stderr);
    foreach (line; pipes.stdout.byLine) {
        if (line.indexOf("error:") != -1) {
            stderr.writeln(line);
            pipes.pid.kill();
            wait (pipes.pid);
            exit_code = 1;
        }
        else if (line.indexOf("{") != -1) {
            auto json = parseJSON(line);
            Package pkg = {
                name: json["attr"].str,
                allowedToFail: false,
                attrPath: params.flakePre ~ "." ~ json["system"].str ~ params.flakePost ~ "." ~ json["attr"].str,
                isCached: json["isCached"].boolean,
                system: getSystem(json["system"].str),
                os: systemToGHPlatform(getSystem(json["system"].str)),
                output: json["outputs"]["out"].str,
                cacheUrl: cachixUrl ~ "/" ~ json["outputs"]["out"].str.matchFirst("^/nix/store/(?P<hash>[^-]+)-")["hash"] ~ ".narinfo"
            };
            result ~= pkg;
            auto outJson = JSONValue(["attr": json["attr"], "isCached": json["isCached"], "out": json["outputs"]["out"]]);
            stderr.writeln("\033[94m" ~outJson.toString(JSONOptions.doNotEscapeSlashes)~"\033[0m");
        }
    }
    foreach (line; pipes.stderr.byLine) {
        if (uselessWarnings.map!((warning) => line.indexOf(warning) != -1).any) {
            continue;
        }
        else if (line.indexOf("error:") != -1) {
            stderr.writeln(line);
            pipes.pid.kill();
            wait (pipes.pid);
            exit_code = 1;
            return result;
        }
        else {
            stderr.writeln(line);
        }
    }

    wait (pipes.pid);
    return result;
}

Package[] nixEvalForAllSystems() {
    if (params.flakePre == "") {
        params.flakePre = "checks";
    }
    if (params.flakePost != "") {
        params.flakePost = "." ~ params.flakePost;
    }
    string cachixUrl = "https://" ~ params.cachixCache ~ ".cachix.org";
    SupportedSystem[] systems = [EnumMembers!SupportedSystem];

    return systems.map!(system => nixEvalJobs(system, cachixUrl)).reduce!((a,b) => a ~ b).array.sort!((a, b) => a.name < b.name).array;
}

int getNixEvalWorkerCount() {
    return params.maxWorkers == 0 ? (threadsPerCPU() < 8 ? threadsPerCPU() : 8) : params.maxWorkers;
}

int getAvailableMemoryMB() {

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
    int maxMemoryMB = params.maxMemory == 0 ? ((free + cached + buffers + shmem) / 1024) : params.maxMemory;
    return maxMemoryMB;
}

void saveCachixDeploySpec(Package[] packages) {
    auto agents = packages.map!(pkg => JSONValue(["package": pkg.name, "out": pkg.output])).array;
    auto resPath = resultDir() ~ "/cachix-deploy-spec.json";
    resPath.write(JSONValue(agents).toString(JSONOptions.doNotEscapeSlashes));
}

void saveGHCIMatrix(Package[] packages) {
    auto packagesToBuild = packages.filter!(pkg => !pkg.isCached).array;
    auto matrix = JSONValue(["include": JSONValue(packagesToBuild.map!(pkg => pkg.toJSON()).array)]);
    string resPath = rootDir() ~ (params.isInitial ? "matrix-pre.json" : "matrix-post.json");
    resPath.write(JSONValue(matrix).toString(JSONOptions.doNotEscapeSlashes));
}

void saveGHCIComment(SummaryTableEntry[] tableSummaryJSON) {
    string comment = "Thanks for your Pull Request!";
    comment ~= "\n\nBelow you will find a summary of the cachix status of each package, for each supported platform.";
    comment ~= "\n\n| package | `x86_64-linux` | `x86_64-darwin` | `aarch64-darwin` |";
    comment ~= "\n| ------- | -------------- | --------------- | ---------------- |";
    comment ~= tableSummaryJSON.map!(pkg => "\n| " ~ pkg.name ~ " | " ~ pkg.x86_64.linux ~ " | " ~ pkg.x86_64.darwin ~ " | " ~ pkg.aarch64.darwin ~ " |").join("");
    (rootDir() ~ "comment.md").write(comment);
}

string getStatus(JSONValue pkg, string key) {
    if (key in pkg) {
        if (pkg[key]["isCached"].boolean) {
            return "[✅ cached](" ~ pkg[key]["cacheUrl"].str ~ ")";
        } else if (params.isInitial) {
            return "⏳ building...";
        } else {
            return "❌ build failed";
        }
    } else {
        return "🚫 not supported";
    }
}

SummaryTableEntry[] convertNixEvalToTableSummaryJSON(Package[] packages) {

    SummaryTableEntry[] tableSummary = packages
        .chunkBy!((a, b) => a.name == b.name)
        .map!((group) {
            JSONValue pkg;
            string name = group.array.front.name;
            pkg["name"] = JSONValue(name);
            foreach (item; group) {
                pkg[item.system.to!string] = item.toJSON();
            }
            SummaryTableEntry entry = {
            name, {getStatus(pkg, "x86_64_linux"), getStatus(pkg, "x86_64_darwin")}, {getStatus(pkg, "aarch64_darwin")}
        };
        return entry;
        }).array.sort!((a, b) => a.name < b.name).release;
    return tableSummary;
}

void printTableForCacheStatus(Package[] packages) {
    if (params.precalcMatrix == "") {
        saveGHCIMatrix(packages);
    }
    saveCachixDeploySpec(packages);
    saveGHCIComment(convertNixEvalToTableSummaryJSON(packages));
}

void curlCheck(Package[] packages) {
    string precalcMatrixStr = params.precalcMatrix == "" ? "{\"include\": []}" : params.precalcMatrix;
    enforce!MissingEnvVarsException(
    params.precalcMatrix != "",
        "missing environment variables: %s".fmt("precalcMatrix")
    );
    Package[] precalcMatrix = parseJSON(precalcMatrixStr)["include"].array.map!((pkg) {
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

    auto checkedPackages = precalcMatrix.map!((pkg) {
        bool isCached = pkg.isCached;
        string cacheUrl = pkg.cacheUrl;
        if (!isCached) {
            string curlOutput = execute(["curl", "--silent", "-H", "Authorization: Bearer " ~ params.cachixAuthToken, "-I", cacheUrl]);
            bool isAvailable = curlOutput
                .split("\n")
                .filter!(line => line.startsWith("HTTP"))
                .map!(line => line.split(" ")[1])
                .map!(code => code == "200")
                .any;
            pkg.isCached = isAvailable;
        }
        return pkg;
    }).array;
    printTableForCacheStatus(checkedPackages);
}

