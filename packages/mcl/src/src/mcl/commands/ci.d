module mcl.commands.ci;

import std.file : readText;
import std.json : parseJSON,JSONValue;
import std.stdio : writeln,write;
import std.algorithm : map;
import std.array : array, join;
import std.conv : to;
import std.process : ProcessPipes;

import argparse;

import mcl.utils.env : optional, parseEnv;
import mcl.commands.ci_matrix: nixEvalJobs, SupportedSystem, Params, flakeAttr;
import mcl.commands.shard_matrix: generateShardMatrix;
import mcl.utils.path : rootDir, createResultDirs;
import mcl.utils.process : execute;
import mcl.utils.nix : nix;
import mcl.utils.json : toJSON;

Params params;

@(Command("ci").Description("Run CI"))
struct CiArgs
{
}

export int ci(CiArgs args)
{
    params = parseEnv!Params;

    auto shardMatrix = generateShardMatrix();
    foreach (shard; shardMatrix.include)
    {
        params.flakePre = shard.prefix;
        params.flakePost = shard.postfix;

        if (params.flakePre == "")
        {
            params.flakePre = "checks";
        }
        string cachixUrl = "https://" ~ params.cachixCache ~ ".cachix.org";
        version (AArch64) {
            string arch = "aarch64";
        }
        version (X86_64) {
            string arch = "x86_64";
        }

        version (linux) {
            string os = "linux";
        }
        version (OSX) {
            string os = "darwin";
        }

        auto matrix = flakeAttr(params.flakePre, arch, os, params.flakePost)
            .nixEvalJobs(cachixUrl, false);

        foreach (pkg; matrix)
        {
            if (pkg.isCached) continue;

            writeln("Package ", pkg.name, " is not cached; building...");
            ProcessPipes res = execute!ProcessPipes(["nix", "build", "--json", ".#" ~ pkg.attrPath]);

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
    return 0;
}
