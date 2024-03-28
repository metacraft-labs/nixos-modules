#!/usr/bin/env -S dmd -run
module nix_eval_jobs;
import std.stdio: writeln,stderr,stdout;
import std.traits;
import std.meta;
import std.string;
import std.algorithm;
import std.file: write, readText, mkdirRecurse, append;
import std.range;
import std.conv;
import std.json;
import std.process;
import std.regex;
import core.cpuid;

JSONValue toJSON(T)(in T value)
{
    static if (is(T == enum))
    {
        return JSONValue(value.enumToString);
    }
    else static if (is(T == bool) || is(T == string) || isNumeric!T)
        return JSONValue(value);
    else static if (is(T == U[], U))
    {
        JSONValue[] result;
        foreach (elem; value)
            result ~= elem.toJSON;
        return JSONValue(result);
    }
    else static if (is(T == struct))
    {
        JSONValue[string] result;
        static foreach (idx, field; value.tupleof)
            result[__traits(identifier, field)] = value.tupleof[idx].toJSON;
        return JSONValue(result);
    }
    else
        static assert(false, "Unsupported type: `", T, "`");
}

string enumToString(T)(in T value) if (is (T == enum))
{
    switch (value)
    {
        static foreach(enumMember; EnumMembers!T)
        {
            case enumMember:
            {
                static if (!hasUDA!(enumMember, StringRepresentation))
                {
                    static assert(0, "Unsupported enum member: `", enumMember, "`");
                }
                return getUDAs!(enumMember, StringRepresentation)[0].repr;
            }
        }
        default:
            assert(0, "Not supported case: " ~ value.to!string);
    }
}

struct StringRepresentation { string repr; }

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

GitHubOS get_gh_os(string os) {
    switch (os) {
        case "ubuntu-latest":
            return GitHubOS.ubuntuLatest;
        case "macos-14":
            return GitHubOS.macos14;
        default:
            return GitHubOS.ubuntuLatest;
    }
}
SupportedSystem get_system(string system) {
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
    string cache_url;
    bool isCached;
    GitHubOS os;
    SupportedSystem system;
    string output;
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

string root_dir() {
    return execute(["git", "rev-parse", "--show-toplevel"]).output.strip ~ "/";
}
string result_dir() {
    return root_dir() ~ ".result/";
}
string gc_roots_dir() {
    return result_dir() ~ "gc-roots/";
}

void create_result_dirs() {
    mkdirRecurse(gc_roots_dir());
}

int exit_code = 0;

int main(string[] args) {
    Package[] packages = [];
    create_result_dirs();
    if (args[1] == "print-table") {
        curl_check([]);
    }
    else if (args.length < 3) {
        packages = nix_eval_for_all_systems("","");
        curl_check(packages);
    }
    else {
        packages = nix_eval_for_all_systems(args[1], args[2]);
        curl_check(packages);
    }
    return exit_code;
}

GitHubOS system_to_gh_platform(SupportedSystem os) {
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

Package[] nix_eval_jobs(string flake_pre,SupportedSystem system, string flake_post, string cachix_url) {
    string flake_attr = flake_pre ~ "." ~ system.enumToString() ~ flake_post;
    Package[] result = [];

    int max_memory_mb = get_available_memory_mb();
    int max_workers = get_nix_eval_worker_count();
    auto pipes = pipeProcess(["nix-eval-jobs", "--quiet", "--option","warn-dirty","false", "--check-cache-status", "--gc-roots-dir",gc_roots_dir, "--workers",max_workers.to!string, "--max-memory-size",max_memory_mb.to!string, "--flake",root_dir~"#"~flake_attr], Redirect.stdout | Redirect.stderr);
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
                attrPath: flake_pre ~ "." ~ json["system"].str ~ flake_post ~ "." ~ json["attr"].str,
                isCached: json["isCached"].boolean,
                system: get_system(json["system"].str),
                os: system_to_gh_platform(get_system(json["system"].str)),
                output: json["outputs"]["out"].str,
                cache_url: cachix_url ~ "/" ~ json["outputs"]["out"].str.matchFirst("^/nix/store/(?P<hash>[^-]+)-")["hash"] ~ ".narinfo"
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

Package[] nix_eval_for_all_systems(string flake_pre, string flake_post) {
    if (flake_pre == "") {
        flake_pre = "checks";
    }
    if (flake_post != "") {
        flake_post = "." ~ flake_post;
    }
    string cachix_url = "https://" ~ environment.get("CACHIX_CACHE").to!string ~ ".cachix.org";
    SupportedSystem[] systems = [EnumMembers!SupportedSystem];

    return systems.map!(system => nix_eval_jobs(flake_pre, system, flake_post, cachix_url)).reduce!((a,b) => a ~ b).array.sort!((a, b) => a.name < b.name).array;;
}

int get_nix_eval_worker_count() {
    return environment.get("MAX_WORKERS", (threadsPerCPU() < 8 ? threadsPerCPU() : 8).to!string).to!int;
}

int get_available_memory_mb() {

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
    int max_memory_mb = environment.get("MAX_MEMORY", ((free + cached + buffers + shmem) / 1024).to!string).to!int;
    return max_memory_mb;
}

void save_cachix_deploy_spec(Package[] packages) {
    auto agents = packages.map!(pkg => JSONValue(["package": pkg.name, "out": pkg.output])).array;
    auto result_path = result_dir() ~ "/cachix-deploy-spec.json";
    result_path.write(JSONValue(agents).toString(JSONOptions.doNotEscapeSlashes));
}

void save_gh_ci_matrix(Package[] packages) {
    auto packages_to_build = packages.filter!(pkg => !pkg.isCached).array;
    auto matrix = JSONValue(["include": JSONValue(packages_to_build.map!(pkg => pkg.toJSON()).array)]);
    string res_path = root_dir() ~ (environment.get("IS_INITIAL", "true") == "true" ? "matrix-pre.json" : "matrix-post.json");
    res_path.write(JSONValue(matrix).toString(JSONOptions.doNotEscapeSlashes));
}

void save_gc_ci_comment(SummaryTableEntry[] table_summary_json) {
    string comment = "Thanks for your Pull Request!";
    comment ~= "\n\nBelow you will find a summary of the cachix status of each package, for each supported platform.";
    comment ~= "\n\n| package | `x86_64-linux` | `x86_64-darwin` | `aarch64-darwin` |";
    comment ~= "\n| ------- | -------------- | --------------- | ---------------- |";
    comment ~= table_summary_json.map!(pkg => "\n| " ~ pkg.name ~ " | " ~ pkg.x86_64.linux ~ " | " ~ pkg.x86_64.darwin ~ " | " ~ pkg.aarch64.darwin ~ " |").join("");
    (root_dir() ~ "comment.md").write(comment);
}

string getStatus(JSONValue pkg, string key, bool is_initial) {
    if (key in pkg) {
        if (pkg[key]["isCached"].boolean) {
            return "[✅ cached](" ~ pkg[key]["cache_url"].str ~ ")";
        } else if (is_initial) {
            return "⏳ building...";
        } else {
            return "❌ build failed";
        }
    } else {
        return "🚫 not supported";
    }
}

SummaryTableEntry[] convert_nix_eval_to_table_summary_json(Package[] packages) {
    bool is_initial = environment.get("IS_INITIAL", "true") == "true";

    SummaryTableEntry[] table_summary = packages
        .chunkBy!((a, b) => a.name == b.name)
        .map!((group) {
            JSONValue pkg;
            string name = group.array.front.name;
            pkg["name"] = JSONValue(name);
            foreach (item; group) {
                pkg[item.system.to!string] = item.toJSON();
            }
            SummaryTableEntry entry = {
            name, {getStatus(pkg, "x86_64_linux", is_initial), getStatus(pkg, "x86_64_darwin", is_initial)}, {getStatus(pkg, "aarch64_darwin", is_initial)}
        };
        return entry;
        }).array.sort!((a, b) => a.name < b.name).release;
    return table_summary;
}

void printTableForCacheStatus(Package[] packages) {
    if (environment.get("PRECALC_MATRIX", "") == "") {
        save_gh_ci_matrix(packages);
    }
    save_cachix_deploy_spec(packages);
    save_gc_ci_comment(convert_nix_eval_to_table_summary_json(packages));
}

void curl_check(Package[] packages) {
    string precalc_matrix_env = environment.get("PRECALC_MATRIX", "{\"include\": []}");

    Package[] precalc_matrix = parseJSON(precalc_matrix_env)["include"].array.map!((pkg) {
        Package result = {
            name: pkg["name"].str,
            allowedToFail: pkg["allowedToFail"].boolean,
            attrPath: pkg["attrPath"].str,
            cache_url: pkg["cache_url"].str,
            isCached: pkg["isCached"].boolean,
            os: get_gh_os(pkg["os"].str),
            system: get_system(pkg["system"].str),
            output: pkg["output"].str
        };
        return result;
    }).array;

    if (precalc_matrix.length != 0) {
        auto checkedPackages = precalc_matrix.map!((pkg) {
            bool isCached = pkg.isCached;
            string cache_url = pkg.cache_url;
            if (!isCached) {
                string curl_output = execute(["curl", "--silent", "-H", "Authorization: Bearer " ~ environment.get("CACHIX_AUTH_TOKEN", ""), "-I", cache_url]).output;
                bool isAvailable = curl_output
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
    else {
        printTableForCacheStatus(packages);
    }
}

