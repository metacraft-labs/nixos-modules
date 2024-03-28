module mcl.utils.nix;

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

string nixBuild(string storePath, string[] extraArgs = []) {
    return nixCommand("build", extraArgs ~ storePath);
}

string nixRun(string flakePath, string[] extraArgs = []) {
    return nixCommand("run", extraArgs ~ flakePath);
}

string nixEval(string flakePath, string[] extraArgs = []) {
    return nixCommand("eval", extraArgs ~ flakePath);
}

JSONValue nixEvalJson(string flakePath, string[] extraArgs = []) {
    return parseJSON(nixCommand(["eval", "--json"], extraArgs));
}

//TODO: Add unittest to test nixEval as a JSONValue
