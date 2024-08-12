module mcl.commands.ci;

import std.file : readText;
import std.json : parseJSON, JSONValue;
import std.stdio : writeln, write;
import std.algorithm : map, each;
import std.array : array, join;
import std.conv : to;
import std.process : ProcessPipes;

import mcl.utils.env : optional, parseEnv;
import mcl.commands.ci_matrix : nixEvalJobs, SupportedSystem, Params, Package;
import mcl.commands.shard_matrix : generateShardMatrix, Shard;
import mcl.utils.path : rootDir, createResultDirs;
import mcl.utils.process : execute;
import mcl.utils.nix : nix;
import mcl.utils.json : toJSON;

Params params;

export void ci()
{
    params = parseEnv!Params;

    auto shardMatrix = generateShardMatrix();
    shardMatrix.include.each!(handleShard);
}

static immutable(SupportedSystem) platform()
{
    version (AArch64)
        static immutable string arch = "aarch64";
    else version (X86_64)
        static immutable string arch = "x86_64";

    version (linux)
        static immutable string os = "linux";
    else version (OSX)
        static immutable string os = "darwin";

    return (arch ~ "_" ~ os).to!(SupportedSystem);
}

void handleShard(Shard shard)
{
    writeln("Shard ", shard.prefix ~ " ", shard.postfix ~ " ", shard.digit);
    params.flakePre = shard.prefix;
    params.flakePost = shard.postfix;

    if (params.flakePre == "")
        params.flakePre = "checks";
    if (params.flakePost != "")
        params.flakePost = "." ~ params.flakePost;
    string cachixUrl = "https://" ~ params.cachixCache ~ ".cachix.org";

    auto matrix = nixEvalJobs(params, platform, cachixUrl, false);
    matrix.each!(handlePackage);
}

void handlePackage(Package pkg)
{
    if (pkg.isCached)
        writeln("Package ", pkg.name, " is cached");
    else
    {
        writeln("Package ", pkg.name, " is not cached; building...");
        ProcessPipes res = execute!ProcessPipes([
            "nix", "build", "--json", ".#" ~ pkg.attrPath
        ]);

        foreach (line; res.stderr.byLine)
        {
            "\r".write;
            line.write;
        }
        "".writeln;
        auto json = parseJSON(res.stdout.byLine.join("\n").to!string);
        auto path = json.array[0]["outputs"]["out"].str;
        execute(["cachix", "push", params.cachixCache, path], false, true).writeln;
    }
}
