module mcl.commands.shard_matrix;

import std.file: append;
import std.conv: to, parse;
import std.stdio: writeln;
import std.string: strip;
import std.regex: matchFirst, regex;

import mcl.utils.nix: nix;
import mcl.utils.path: createResultDirs, resultDir;
import mcl.utils.env: parseEnv, optional;
import mcl.utils.json: toJSON;

export void shard_matrix() {
    const params = parseEnv!Params;
    auto matrix = generateShardMatrix();
    saveShardMatrix(matrix,params);

}

struct Params {
    @optional() string githubOutput;

    void setup() {
    }
}

struct Shard {
    string prefix;
    string postfix;
    int digit;
}

struct ShardMatrix {
    Shard[] include;
}

ShardMatrix generateShardMatrix() {
    try {
        const shardCount = nix.eval(".#legacyPackages.x86_64-linux.checks.shardCount", ["--quiet"]).matchFirst(regex(`\d+`))[0].to!int;
        return splitToShards(shardCount);
    }
    catch (Exception e) {
        version (unittest) {}
        else {
            writeln("Error: ", e.msg);
            writeln("No shards found, exiting");
        }
        return ShardMatrix([Shard( "", "", -1)]);
    }

}

@("generateShardMatrix")
unittest {
    auto shards = generateShardMatrix();
    //this repo doesn't include shards, so we should get the error message
    assert(shards.include.length == 1);
    assert(shards.include[0].prefix == "");
    assert(shards.include[0].postfix == "");
    assert(shards.include[0].digit == -1);

}

ShardMatrix splitToShards(int shardCount) {
    ShardMatrix shards;
    const numShards = shardCount - 1;
    for (int i = 0; i <= numShards; i++) {
        Shard shard = { "legacyPackages", "checks.shards." ~ i.to!string, i };
        shards.include ~= shard;
    }
    return shards;
}

@("splitToShards")
unittest {
    auto shards = splitToShards(3);
    assert(shards.include.length == 3);
    assert(shards.include[0].prefix == "legacyPackages");
    assert(shards.include[0].postfix == "checks.shards.0");
    assert(shards.include[0].digit == 0);
    assert(shards.include[1].prefix == "legacyPackages");
    assert(shards.include[1].postfix == "checks.shards.1");
    assert(shards.include[1].digit == 1);
    assert(shards.include[2].prefix == "legacyPackages");
    assert(shards.include[2].postfix == "checks.shards.2");
    assert(shards.include[2].digit == 2);

}

void saveShardMatrix(ShardMatrix matrix, Params params) {
    const matrixJson = "gen_matrix=" ~ matrix.toJSON().toString();
    writeln(matrixJson);
    if (params.githubOutput != "") {
        params.githubOutput.append(matrixJson);
    }
    else {
        createResultDirs();
        (resultDir() ~ "gh-output.env").append(matrixJson);
    }

}
