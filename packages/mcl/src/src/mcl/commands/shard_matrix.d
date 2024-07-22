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

ShardMatrix generateShardMatrix()
{
    try
    {
        const shardCount = nix.eval(".#legacyPackages.x86_64-linux.shardCount")
            .strip()
            .to!int;

        infof("shardCount: %s", shardCount);

        return splitToShards(shardCount);
    }
    catch (Exception e)
    {
        version (unittest)
        {
        }
        else
        {
            errorf("Error: %s", e.msg);
            errorf("No shards found, exiting");
        }
        return ShardMatrix([Shard("", "", -1)]);
    }

}

@("generateShardMatrix")
unittest
{
    auto shards = generateShardMatrix();
    //this repo doesn't include shards, so we should get the error message
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
        .map!(i => Shard("legacyPackages", "shards." ~ i.to!string, i))
        .array;

    return shards;
}

@("splitToShards")
unittest
{
    auto shards = splitToShards(3);
    assert(shards.include.length == 3);
    assert(shards.include[0].prefix == "legacyPackages");
    assert(shards.include[0].postfix == "shards.0");
    assert(shards.include[0].digit == 0);
    assert(shards.include[1].prefix == "legacyPackages");
    assert(shards.include[1].postfix == "shards.1");
    assert(shards.include[1].digit == 1);
    assert(shards.include[2].prefix == "legacyPackages");
    assert(shards.include[2].postfix == "shards.2");
    assert(shards.include[2].digit == 2);

}

void saveShardMatrix(ShardMatrix matrix, Params params)
{
    const matrixJson = matrix.toJSON();
    const matrixString = matrixJson.toString();
    infof("Shard matrix: %s", matrixJson.toPrettyString);
    const envLine = "gen_matrix=" ~ matrixString;
    if (params.githubOutput != "")
    {
        params.githubOutput.append(envLine);
    }
    else
    {
        createResultDirs();
        resultDir.buildPath("gh-output.env").append(envLine);
    }
    rootDir.buildPath("shardMatrix.json").write(matrixString);

}
