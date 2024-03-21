module mcl.commands.get_fstab;

import std;
import std.conv : to;
import std.json : JSONValue;
import std.format : fmt = format;
import std.exception : enforce;

import mcl.utils.strings : camelCaseToCapitalCase;
import mcl.utils.processes : execute;

export void get_fstab() {
    const params = parseEnv!Params;
    const machineStorePath = getCachixDeploymentStorePath(params);
    const fstabStorePath = queryStorePath(
        machineStorePath,
        ["-etc", "-etc-fstab"],
        params.cachixStoreUrl
    );
    nixBuild(fstabStorePath);
    writeln(fstabStorePath);
}

struct Optional {}
auto optional() => Optional();

enum isOptional(alias field) = hasUDA!(field, Optional);

struct Params {
    string cachixAuthToken;
    string cachixCache;
    @optional() string cachixStoreUrl;
    @optional() string cachixDeployWorkspace;
    string machineName;
    uint deploymentId;

    void setup() {

        static foreach (idx, field; this.tupleof)
        {{
            string envVarName = __traits(identifier, field).camelCaseToCapitalCase;
            enforce(field || isOptional!field,
                "'%s' env var is not set".fmt(envVarName));
        }}

        cachixStoreUrl = cachixNixStoreUrl(cachixCache);
        if (!cachixDeployWorkspace) cachixDeployWorkspace = cachixCache;
    }
}


string getCachixDeploymentApiUrl(Params p) =>
    getCachixDeploymentApiUrl(p.cachixDeployWorkspace, p.machineName, p.deploymentId);

string getCachixDeploymentApiUrl(string workspace, string machine, uint deploymentId)
in (workspace && machine && deploymentId) =>
    "https://app.cachix.org/api/v1/deploy/deployment/%s/%s/%s"
    .fmt(workspace, machine, deploymentId);

string cachixNixStoreUrl(string cachixCache) =>
    "https://%s.cachix.org".fmt(cachixCache);

JSONValue fetchJson(string url, string authToken) {
    import std.json : parseJSON;
    import std.net.curl : HTTP, get;
    auto client = HTTP();
    client.addRequestHeader("Authorization", "Bearer " ~ authToken);
    stderr.writefln("GET %s", url);
    auto response = get(url, client);
    return parseJSON(response);
}

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

void nixBuild(string storePath) {
    ["nix", "build", storePath].execute();
}

T parseEnv(T)() {
    import std.process : environment;
    import std.traits : Fields;

    T result;

    static foreach (idx, field; result.tupleof)
    {{
        string envVarName = field.stringof.camelCaseToCapitalCase;
        if (auto envVar = environment.get(envVarName))
            result.tupleof[idx] = envVar.to!(typeof(field));
        else
            debug stderr.writefln("%s not found", envVarName);
    }}

    result.setup();

    return result;
}

string getCachixDeploymentStorePath(Params p)
{
    const url = getCachixDeploymentApiUrl(p);
    const response = fetchJson(url, p.cachixAuthToken);
    return response["storePath"].get!string;
}
