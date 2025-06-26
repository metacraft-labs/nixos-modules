module mcl.commands.shard_matrix;


import std.algorithm : map;
import std.array : array;
import std.conv : to, parse;
import std.file : append, write;
import std.format : fmt = format;
import std.logger : warningf, infof;
import std.path : buildPath;
import std.range : iota;
import std.regex : matchFirst, regex;
import std.stdio : writeln;
import std.string : strip;

import argparse;

import mcl.utils.env : parseEnv, optional;
import mcl.utils.json : toJSON;
import mcl.utils.nix : nix;
import mcl.utils.path : createResultDirs, resultDir, rootDir;

@(Command("shard-matrix", "shard_matrix").Description("Generate a shard matrix for a flake"))
struct shard_matrix_args
{
    @(NamedArgument(["github-output"]).Placeholder("output").Description("Output to GitHub Actions"))
    string githubOutput;
}

export int shard_matrix(shard_matrix_args args)
{
    auto matrix = generateShardMatrix();
    saveShardMatrix(matrix, args);
    return 0;

}

struct Shard
{
    string prefix;
    string postfix;
    int digit;
}

struct ShardMatrix
{
    Shard[] include;
}

ShardMatrix generateShardMatrix(string flakeRef = ".")
{
    import std.path : isValidPath, absolutePath, buildNormalizedPath;

    if (flakeRef.isValidPath) {
        flakeRef = flakeRef.absolutePath.buildNormalizedPath;
    }

    const shardCountOutput = nix.eval("", [
        "--impure",
        "--expr",
        `(builtins.getFlake "` ~ flakeRef ~ `").outputs.legacyPackages.x86_64-linux.mcl.matrix.shardCount or 0`
    ]);

    infof("shardCount: '%s'", shardCountOutput);

    const shardCount = shardCountOutput
        .strip()
        .to!uint;

    if (shardCount == 0)
    {
        warningf("No shards found, exiting");
        return ShardMatrix([Shard("", "", -1)]);
    }

    return splitToShards(shardCount);
}

@("generateShardMatrix.ok")
unittest
{
    version (none)
    {
        // See: https://github.com/metacraft-labs/nixos-modules/blob/b70f5bf556a0afc25d45ff5abd9d4eeae58d2647/flake.nix
        auto flakeRef = "github:metacraft-labs/nixos-modules?rev=b70f5bf556a0afc25d45ff5abd9d4eeae58d2647";
    }
    else
    {
        import mcl.utils.path : rootDir;
        auto flakeRef = rootDir.buildPath("packages/mcl/src/src/mcl/utils/test/nix/shard-matrix-ok");
    }

    auto shards = generateShardMatrix(flakeRef);
    assert(shards.include.length == 11);
    assert(shards.include[0].prefix == "legacyPackages");
    assert(shards.include[0].postfix == "mcl.matrix.shards.0");
    assert(shards.include[0].digit == 0);
}

@("generateShardMatrix.fail")
unittest
{
    import mcl.utils.path : rootDir;
    auto flakeRef = rootDir.buildPath("packages/mcl/src/src/mcl/utils/test/nix/shard-matrix-no-shards");

    auto shards = generateShardMatrix(flakeRef);
    assert(shards.include.length == 1);
    assert(shards.include[0].prefix == "");
    assert(shards.include[0].postfix == "");
    assert(shards.include[0].digit == -1);
}

ShardMatrix splitToShards(int shardCount)
{
    ShardMatrix shards;
    shards.include = shardCount
        .iota
        .map!(i => Shard("legacyPackages", "mcl.matrix.shards.%s".fmt(i), i))
        .array;

    return shards;
}

@("splitToShards")
unittest
{
    auto shards = splitToShards(3);
    assert(shards.include.length == 3);
    assert(shards.include[0].prefix == "legacyPackages");
    assert(shards.include[0].postfix == "mcl.matrix.shards.0");
    assert(shards.include[0].digit == 0);
    assert(shards.include[1].prefix == "legacyPackages");
    assert(shards.include[1].postfix == "mcl.matrix.shards.1");
    assert(shards.include[1].digit == 1);
    assert(shards.include[2].prefix == "legacyPackages");
    assert(shards.include[2].postfix == "mcl.matrix.shards.2");
    assert(shards.include[2].digit == 2);

}

void saveShardMatrix(ShardMatrix matrix, shard_matrix_args args)
{
    const matrixJson = matrix.toJSON();
    const matrixString = matrixJson.toString();
    infof("Shard matrix: %s", matrixJson.toPrettyString);
    const envLine = "gen_matrix=" ~ matrixString;
    if (args.githubOutput != "")
    {
        args.githubOutput.append(envLine);
    }
    else
    {
        createResultDirs();
        resultDir.buildPath("gh-output.env").append(envLine);
    }
    rootDir.buildPath("shardMatrix.json").write(matrixString);

}
