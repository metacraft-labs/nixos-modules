module mcl.commands.get_fstab;

import std.stdio: writeln;
import std.conv: to;
import std.json: JSONValue;
import std.format: fmt = format;
import std.exception: enforce;

import mcl.utils.cachix: cachixNixStoreUrl, getCachixDeploymentApiUrl;
import mcl.utils.env: optional, parseEnv;
import mcl.utils.fetch: fetchJson;
import mcl.utils.nix: queryStorePath, nixBuild;
import mcl.utils.string: camelCaseToCapitalCase;
import mcl.utils.process: execute;

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

struct Params {
    string cachixAuthToken;
    string cachixCache;
    @optional() string cachixStoreUrl;
    @optional() string cachixDeployWorkspace;
    string machineName;
    uint deploymentId;

    void setup() {

        cachixStoreUrl = cachixNixStoreUrl(cachixCache);
        if (!cachixDeployWorkspace) cachixDeployWorkspace = cachixCache;
    }
}

string getCachixDeploymentStorePath(Params p)
{
    const url = getCachixDeploymentApiUrl(p.cachixDeployWorkspace, p.machineName, p.deploymentId);
    const response = fetchJson(url, p.cachixAuthToken);
    return response["storePath"].get!string;
}
