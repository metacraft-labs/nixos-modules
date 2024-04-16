module mcl.utils.nix;
import mcl.utils.test;

import std.algorithm : filter, endsWith;
import std.array : array;
import std.conv : to;
import std.exception : enforce;
import std.format : fmt = format;
import std.string : lineSplitter, strip;
import std.json : parseJSON, JSONValue;

import mcl.utils.process : execute;

string queryStorePath(string storePath, string[] referenceSuffixes, string storeUrl)
{
    string lastMatch = storePath;

    foreach (suffix; referenceSuffixes)
        lastMatch = findMatchingNixReferences(lastMatch, suffix, storeUrl);

    return lastMatch;
}

string findMatchingNixReferences(string nixStorePath, string suffix, string storeUrl)
{
    auto matches = nixQueryReferences(nixStorePath, storeUrl)
        .filter!(path => path.endsWith(suffix))
        .array;

    enforce(matches.length > 0,
        "No store paths with suffix: '%s'".fmt(suffix));
    enforce(matches.length == 1,
        "Multiple store paths with suffix: '%s'".fmt(suffix));

    return matches[0];
}

string[] nixQueryReferences(string nixStorePath, string storeUrl)
{
    return [
        "nix-store", "--store", storeUrl, "--query", "--references", nixStorePath
    ]
        .execute
        .lineSplitter
        .array
        .to!(string[]);
}

auto nix() => NixCommand();

struct NixCommand
{
    static immutable supportedCommands = [
        "build", "copy", "derivation", "doctor", "eval", "fmt", "help", "key",
        "nar", "print-dev-env", "realisation", "repl",
        "search", "show-config", "upgrade-nix", "bundle", "daemon", "develop",
        "edit", "flake", "hash", "help-stores", "log",
        "path-info", "profile", "registry", "run", "shell", "store", "why-depends"
    ];

    template opDispatch(string commandName)
    {
        T opDispatch(T = string)(string path, string[] args = [])
        {
            import std.algorithm : canFind;

            static assert(
                is(T == string) || is(T == JSONValue),
                "NixCommand only supports string or JSONValue template args, not `" ~ T.stringof ~ "`."
            );

            static assert(
                supportedCommands.canFind(commandName),
                "`" ~ commandName ~ "` is not a valid Nix command."
            );

            enum isJSON = is(T == JSONValue);

            version (unittest)
            {
                auto command = [
                    "nix", "--experimental-features", "nix-command flakes",
                    commandName,
                    (isJSON ? "--json" : "")
                ] ~ args ~ path;
            }
            else
            {
                if (isJSON)
                {
                    args ~= "--json";
                }
                auto command = ["nix", commandName] ~ args ~ path;
            }

            auto output = command.execute().strip();

            static if (isJSON)
                return parseJSON(output);
            else
                return output;
        }
    }
}

@("nix.run")
unittest
{
    import std.stdio : writeln;
    import std.range : front;

    import std.path : absolutePath, dirName;

    auto p = __FILE__.absolutePath.dirName;

    string output = nix().run(p ~ "/test/test.nix", [ "--file"]);
    assert(output == "Hello World");
}

@("nix.build!JSONValue")
unittest
{
    import std.stdio : writeln;
    import std.range : front;

    import std.path : absolutePath, dirName;

    auto p = __FILE__.absolutePath.dirName;

    JSONValue output = nix().build!JSONValue(p ~ "/test/test.nix", ["--file"]).array.front;
    assert(execute([output["outputs"]["out"].str ~ "/bin/helloWorld"]).strip == "Hello World");
}

@("nix.eval!JSONValue")
unittest
{
    import std.file : readText;
    import std.path : absolutePath, dirName;
    import std.json : parseJSON;

    auto p = __FILE__.absolutePath.dirName;

    auto result = nix().eval!JSONValue(p ~ "/test/eval.nix", ["--file"]);
    assert(result == ((p ~ "/test/eval.json").readText.parseJSON));
}
