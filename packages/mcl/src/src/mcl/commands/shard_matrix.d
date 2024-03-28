module mcl.commands.shard_matrix;

import std.file: append;
import std.conv: to, parse;
import std.stdio: writeln;
import std.string: strip;
import std.regex: matchFirst, regex;

import mcl.utils.nix: nixEval;
import mcl.utils.path: createResultDirs, resultDir;
import mcl.utils.env: parseEnv, optional;
import mcl.utils.json: toJSON;

export void shard_matrix() {
    const params = parseEnv!Params;
    auto matrix = generateShardMatrix(params);
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

ShardMatrix generateShardMatrix(Params params) {

    ShardMatrix shards;

    try {
        const shardCount = nixEval(".#legacyPackages.x86_64-linux.checks.shardCount", ["--quiet"]).matchFirst(regex(`\d+`))[0].to!int;
        const numShards = shardCount - 1;
        for (int i = 0; i <= numShards; i++) {
            Shard shard = { "legacyPackages", "checks.shards." ~ i.to!string, i };
            shards.include ~= shard;
        }

    }
    catch (Exception e) {
        writeln("Error: ", e.msg);
        writeln("No shards found, exiting");
            Shard shard =  { "", "", -1 };
            shards.include ~= shard;
    }

    return shards;
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
