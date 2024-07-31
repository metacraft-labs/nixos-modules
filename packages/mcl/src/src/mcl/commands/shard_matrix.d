module mcl.commands.shard_matrix;

import std.algorithm : map;
import std.array : array;
import std.conv : to, parse;
import std.file : append, write;
import std.logger : errorf, infof;
import std.path : buildPath;
import std.range : iota;
import std.regex : matchFirst, regex;
import std.stdio : writeln;
import std.string : strip;
import std.regex : matchFirst, regex;
import std.format : format;
import std.algorithm : each;
import std.parallelism : parallel;

import mcl.utils.env : parseEnv, optional;
import mcl.utils.json : toJSON;
import mcl.utils.nix : nix;
import mcl.utils.path : createResultDirs, resultDir, rootDir;

export void shard_matrix()
{
    const params = parseEnv!Params;
    auto matrix = generateShardMatrix();
    saveShardMatrix(matrix, params);

}

struct Params
{
    @optional() string githubOutput;

    void setup()
    {
    }
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

    if (flakeRef.isValidPath)
    {
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
        errorf("No shards found, exiting");
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

        auto flakeRef = rootDir.buildPath(
            "packages/mcl/src/src/mcl/utils/test/nix/shard-matrix-ok");
    }

    auto shards = generateShardMatrix(flakeRef);
    assert(shards.include.length == 11);
    foreach(i, shard; shards.include.parallel)
        assertShard(shard, i.to!int);
}

void assertShard(Shard shard, int index) {
    string expectedPrefix = index == -1 ? "" : "legacyPackages";
    string expectedPostfix = index == -1 ? "" : ("shards." ~ index.to!string);
    assert(shard.prefix == expectedPrefix, "Expected shard %s to have prefix '%s', but got %s".format(index, expectedPrefix, shard.prefix));
    assert(shard.postfix == expectedPostfix, "Expected shard %s to have postfix '%s', but got %s".format(index, expectedPostfix, shard.postfix));
    assert(shard.digit == index, "Expected shard %s to have digit %s, but got %s".format(index, index, shard.digit));
}


@("generateShardMatrix.fail")
unittest
{
    import mcl.utils.path : rootDir;

    auto flakeRef = rootDir.buildPath(
        "packages/mcl/src/src/mcl/utils/test/nix/shard-matrix-no-shards");

    auto shards = generateShardMatrix(flakeRef);
    assert(shards.include.length == 1, "generateShardMatrix should return 1 shard, but got %s".format(shards.include.length));
    assertShard(shards.include[0], -1);
}

ShardMatrix splitToShards(int shardCount)
{
    ShardMatrix shards;
    shards.include = shardCount
        .iota
        .map!(i => Shard("legacyPackages", "shards." ~ i.to!string, i))
        .array;

    return shards;
}

@("splitToShards")
unittest
{
    auto shards = splitToShards(3);
    assert(shards.include.length == 3, "Expectes splitToShards(3) to return 3 shards, but got %s".format(shards.include.length));
    foreach(i, shard; shards.include.parallel)
        assertShard(shard, i.to!int);

}

void saveShardMatrix(ShardMatrix matrix, Params params)
{
    const matrixJson = matrix.toJSON();
    const matrixString = matrixJson.toString();
    infof("Shard matrix: %s", matrixJson.toPrettyString);
    const envLine = "gen_matrix=" ~ matrixString;
    if (params.githubOutput != "")
        params.githubOutput.append(envLine);
    else
    {
        createResultDirs();
        resultDir.buildPath("gh-output.env").append(envLine);
    }
    rootDir.buildPath("shardMatrix.json").write(matrixString);

}
