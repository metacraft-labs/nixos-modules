module mcl.commands.ci;

import std.file : readText;
import std.json : parseJSON,JSONValue;
import std.stdio : writeln;

import mcl.utils.env : optional, parseEnv;
import mcl.commands.ci_matrix: ci_matrix;
import mcl.utils.path : rootDir;
import mcl.utils.process : execute;
import mcl.utils.nix : nix;

Params params;

export void ci()
{
    params = parseEnv!Params;
    ci_matrix();

    string resPath = rootDir() ~ (params.isInitial ? "matrix-pre.json" : "matrix-post.json");
    auto matrix = resPath.readText().parseJSON();
    foreach (pkg; matrix["include"].array)
    {
        if (pkg["isCached"].boolean)
        {
            writeln("Package ", pkg["name"].str, " is cached");
        }
        else
        {
            writeln("Package ", pkg["name"].str, " is not cached; building...");
            auto path = (nix.build!JSONValue(".#" ~ pkg["attrPath"].str)).array[0]["outputs"]["out"].str;
            execute(["cachix", "push", params.cachixCache, path], false, true).writeln;
        }
    }
}

struct Params
{
    @optional() string flakePre;
    @optional() string flakePost;
    @optional() string precalcMatrix;
    @optional() int maxWorkers;
    @optional() int maxMemory;
    @optional() bool isInitial;
    string cachixCache;
    string cachixAuthToken;

    void setup()
    {
    }
}
