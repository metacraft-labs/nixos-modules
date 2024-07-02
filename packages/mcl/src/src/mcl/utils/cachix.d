module mcl.utils.cachix;
import mcl.utils.test;

import std.format : fmt = format;

string getCachixDeploymentApiUrl(string workspace, string machine, uint deploymentId)
in (workspace && machine && deploymentId) =>
    "https://app.cachix.org/api/v1/deploy/deployment/%s/%s/%s"
    .fmt(workspace, machine, deploymentId);

@("getCachixDeploymentApiUrl")
unittest
{
    assert(getCachixDeploymentApiUrl("my-workspace", "my-machine", 123) ==
            "https://app.cachix.org/api/v1/deploy/deployment/my-workspace/my-machine/123");

}

string cachixNixStoreUrl(string cachixCache) =>
    "https://%s.cachix.org".fmt(cachixCache);

@("cachixNixStoreUrl")
unittest
{
    assert(cachixNixStoreUrl("my-cache") == "https://my-cache.cachix.org");
}
