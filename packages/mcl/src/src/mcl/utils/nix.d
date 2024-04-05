module mcl.utils.nix;
import mcl.utils.test;

import std.algorithm: filter, endsWith;
import std.array: array;
import std.conv: to;
import std.exception: enforce;
import std.format: fmt = format;
import std.string: lineSplitter, strip;
import std.json: parseJSON, JSONValue;

import mcl.utils.process : execute;

string queryStorePath(string storePath, string[] referenceSuffixes, string storeUrl)
{
    string lastMatch = storePath;

    foreach (suffix; referenceSuffixes)
        lastMatch = findMatchingNixReferences(lastMatch, suffix, storeUrl);

    return lastMatch;
}

string findMatchingNixReferences(string nixStorePath, string suffix, string storeUrl) {
    auto matches = nixQueryReferences(nixStorePath, storeUrl)
        .filter!(path => path.endsWith(suffix))
        .array;

    enforce(matches.length > 0,
        "No store paths with suffix: '%s'".fmt(suffix));
    enforce(matches.length == 1,
        "Multiple store paths with suffix: '%s'".fmt(suffix));

    return matches[0];
}

string[] nixQueryReferences(string nixStorePath, string storeUrl) {
    return [
        "nix-store", "--store", storeUrl, "--query", "--references", nixStorePath
    ]
        .execute
        .lineSplitter
        .array
        .to!(string[]);
}

string nixCommand(T)(T cmd, string[] args) if (is (T == string ) || is(T == string[])) {
    auto command = "nix" ~ (cmd ~ args);
    return command.execute().strip();
}

T nixCommand(T,Y)(Y cmd, string[] args = []) if (is(T == JSONValue)){
    return parseJSON(nixCommand(cmd ~ ["--json"], args));
}

template NixCommand(string name) {
    import mcl.utils.string: kebabCaseToCamelCase;
    const char[] NixCommand = `string ` ~ ("nix-" ~ name).kebabCaseToCamelCase ~ `(string path, string[] extraArgs = []) {
        return nixCommand("` ~ name ~ `", extraArgs ~ path);
    }` ~
    `T ` ~ ("nix-" ~ name).kebabCaseToCamelCase ~ `(T)(string path, string[] extraArgs = []) if (is(T == JSONValue)){
        return nixCommand!JSONValue("` ~ name ~ `", extraArgs ~ path);
    }`;
}

static foreach (command;   ["build" ,"copy" ,"derivation" ,"doctor" ,"eval" ,"fmt" ,"help" ,"key" ,"nar" ,"print-dev-env" ,"realisation" ,"repl" ,
                            "search" ,"show-config" ,"upgrade-nix" ,"bundle" ,"daemon" ,"develop" ,"edit" ,"flake" ,"hash" ,"help-stores" ,"log" ,
                            "path-info" ,"profile" ,"registry" ,"run" ,"shell" ,"store" ,"why-depends"]) {
    mixin(NixCommand!(command));
}

@("nix.run")
unittest
{
    import std.stdio: writeln;
    import std.range: front;

    import std.path: absolutePath, dirName;
    auto p = __FILE__.absolutePath.dirName;

    string output = nix().run(p ~ "/test/test.nix", ["--file"]);
    assert(output == "Hello World");
}
@("nix.build!JSONValue")
unittest
{
    import std.stdio: writeln;
    import std.range: front;

    import std.path: absolutePath, dirName;
    auto p = __FILE__.absolutePath.dirName;

    JSONValue output = nix().build!JSONValue(p ~ "/test/test.nix", ["--file"]).array.front;
    assert(execute([output["outputs"]["out"].str ~ "/bin/helloWorld"]).strip == "Hello World");
}

@("nix.eval!JSONValue")
unittest
{
    auto result = nixEval!JSONValue(".#mcl.meta");
    result["position"] = JSONValue("N/A");
    assert(result == JSONValue([
        "available": JSONValue(true),
        "broken": JSONValue(false),
        "insecure": JSONValue(false),
        "mainProgram": JSONValue("mcl"),
        "name": JSONValue("mcl"),
        "outputsToInstall": JSONValue(["out"]),
        "position": JSONValue("N/A"),
        "unfree": JSONValue(false),
        "unsupported": JSONValue(false)
        ]));
}
