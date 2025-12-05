module mcl.commands.ci;

import std.file : readText;
import std.json : parseJSON,JSONValue;
import std.stdio : writefln, writeln, write;
import std.algorithm : map, filter;
import std.array : array, join;
import std.conv : to;
import std.process : ProcessPipes;

import argparse : Command, Description;

import mcl.commands.ci_matrix: nixEvalJobs, SupportedSystem, flakeAttr, CiMatrixBaseArgs;
import mcl.commands.shard_matrix: generateShardMatrix;
import mcl.utils.path : rootDir, createResultDirs;
import mcl.utils.process : execute, spawnProcessInline;
import mcl.utils.nix : nix;
import mcl.utils.json : toJSON;


@(Command("ci").Description("Run CI"))
struct CiArgs {
    mixin CiMatrixBaseArgs!();
}

export int ci(CiArgs args)
{
    auto shardMatrix = generateShardMatrix();
    foreach (shard; shardMatrix.include)
    {
        args.flakePre = shard.prefix;
        args.flakePost = shard.postfix;

        if (args.flakePre == "")
        {
            args.flakePre = "checks";
        }
        string cachixUrl = "https://" ~ args.cachixCache ~ ".cachix.org";
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

        auto matrix = flakeAttr(args.flakePre, arch, os, args.flakePost)
            .nixEvalJobs(cachixUrl, args, true);

        auto pkgsToBuild = matrix
            .filter!(pkg => !pkg.isCached)
            .map!(pkg => ".#" ~ pkg.attrPath)
            .array;

        if (!pkgsToBuild.length) continue;

        writefln!"Building %s packages:\n%-(* %s%|\n%)"(pkgsToBuild.length, pkgsToBuild);
        ProcessPipes res = execute!ProcessPipes(["nix", "build", "--json"] ~ pkgsToBuild);

        auto json = parseJSON(res.stdout.byLine.join("\n").to!string);
        try {
            auto paths = json.array.map!(el => el["outputs"]["out"].str).array;
            spawnProcessInline(["cachix", "push", args.cachixCache] ~ paths);
        } catch (Throwable e) {
            writeln("Unexpected JSON structure: ", json.toPrettyString);
        }
    }
    return 0;
}
