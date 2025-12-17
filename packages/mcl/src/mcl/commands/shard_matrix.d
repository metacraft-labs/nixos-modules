module mcl.commands.shard_matrix;

import std.algorithm : map;
import std.array : array;
import std.conv : ConvException, to, parse;
import std.exception : ifThrown;
import std.file : append, write;
import std.format : fmt = format;
import std.logger : warningf, infof;
import std.path : buildPath;
import std.range : iota;
import std.regex : matchFirst, regex;
import std.string : strip;
import std.typecons : Nullable, nullable;

import argparse : Command, Description, NamedArgument, Placeholder, EnvFallback;

import mcl.utils.json : toJSON;
import mcl.utils.nix : nix;
import mcl.utils.path : createResultDirs, resultDir, rootDir;
import mcl.utils.string : enumToString;
import mcl.commands.ci_matrix : SupportedSystem, currentSystem;

@(Command("shard-matrix", "shard_matrix")
    .Description("Generate a shard matrix for a flake"))
struct ShardMatrixArgs
{
    @(NamedArgument(["github-output"])
        .Placeholder("output")
        .Description("Output to GitHub Actions")
        .EnvFallback("GITHUB_OUTPUT")
    )
    string githubOutput;
}

export int shard_matrix(ShardMatrixArgs args)
{
    auto matrix = generateShardMatrix();
    saveShardMatrix(matrix, args);
    return 0;
}

struct Shard
{
    string flakeAttrPath;
    string filename;
}

struct ShardMatrix
{
    Shard[] include;
}

ShardMatrix generateShardMatrix(string flakeRef = ".", Nullable!SupportedSystem system = Nullable!SupportedSystem.init)
{
    import std.path : isValidPath, absolutePath, buildNormalizedPath;

    if (flakeRef.isValidPath) {
        flakeRef = flakeRef.absolutePath.buildNormalizedPath;
    }

    const shardCountOutput = nix.eval(
        "%s#mcl.shard-matrix.result.%s".fmt(
            flakeRef,
            system.isNull
                ? "shardCount"
                : "shardCountPerSystem.%s".fmt(system.get.enumToString),
        )
    )
    .ifThrown("");

    infof("shardCount: '%s'", shardCountOutput);

    const shardCount = shardCountOutput
        .strip()
        .to!uint
        .ifThrown!ConvException(0);

    if (shardCount == 0)
    {
        warningf("No shards found, exiting");
        return ShardMatrix();
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
        auto flakeRef = rootDir.buildPath("packages/mcl/src/mcl/utils/test/nix/shard-matrix-ok");
    }

    {
        auto shards = generateShardMatrix(flakeRef);
        assert(shards.include.length == 21);
    }

    {
        auto shards = generateShardMatrix(flakeRef, nullable(SupportedSystem.x86_64_linux));
        assert(shards.include.length == 11);
        assert(shards.include[0] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shards.shard-00", filename: "matrix-pre-shard-00.json"));
    }

    {
        // `aarch64_linux` is not in `flake.mcl.shard-matrix.systemsToBuild`,
        // so no shards should be generated
        auto shards = generateShardMatrix(flakeRef, nullable(SupportedSystem.aarch64_linux));
        assert(shards.include == []);
    }
}

@("generateShardMatrix.fail")
unittest
{
    import mcl.utils.path : rootDir;
    auto flakeRef = rootDir.buildPath("packages/mcl/src/src/mcl/utils/test/nix/shard-matrix-no-shards");

    auto shards = generateShardMatrix(flakeRef);
    assert(shards.include == []);
}

ShardMatrix splitToShards(int shardCount, Nullable!SupportedSystem system = Nullable!SupportedSystem.init)
{
    import core.internal.string : numDigits;
    const padWidth = shardCount.numDigits;
    return shardCount
        .iota
        .map!(i => Shard(
            flakeAttrPath: "mcl.shard-matrix.result.%s.shard-%0*s".fmt(
                system.isNull
                    ? "shards"
                    : "shardsPerSystem.%s".fmt(system.get),
                padWidth,
                i,
            ),
            filename: "matrix-pre-shard-%0*s.json".fmt(padWidth, i)
        ))
        .array
        .ShardMatrix;
}

@("splitToShards")
unittest
{
    auto shards = splitToShards(3);
    assert(shards.include.length == 3);
    assert(shards.include[0] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shards.shard-0", filename: "matrix-pre-shard-0.json"));
    assert(shards.include[1] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shards.shard-1", filename: "matrix-pre-shard-1.json"));
    assert(shards.include[2] == Shard(flakeAttrPath: "mcl.shard-matrix.result.shards.shard-2", filename: "matrix-pre-shard-2.json"));
}

void saveShardMatrix(ShardMatrix matrix, ShardMatrixArgs args)
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
