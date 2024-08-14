module mcl.commands.deploy_spec;

import std.algorithm : filter;
import std.logger : infof, warningf;
import std.file : exists, readText;
import std.path : buildPath;
import std.file : writeFile = write;
import std.json : parseJSON, JSONOptions;

import mcl.utils.process : spawnProcessInline;
import mcl.utils.path : resultDir;
import mcl.utils.env : parseEnv;
import mcl.utils.cachix : cachixNixStoreUrl, DeploySpec, createMachineDeploySpec;
import mcl.utils.tui : bold;
import mcl.utils.json : toJSON, fromJSON;

import mcl.commands.ci_matrix : flakeAttr, Params, nixEvalJobs, SupportedSystem;

export void deploy_spec()
{
    const deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json");

    auto params = parseEnv!Params;

    if (!exists(deploySpecFile))
    {
        auto nixosConfigs = flakeAttr("legacyPackages", SupportedSystem.x86_64_linux, "bareMetalMachines")
            .nixEvalJobs(params.cachixCache.cachixNixStoreUrl);

        auto configsMissingFromCachix = nixosConfigs.filter!(c => !c.isCached);

        foreach (config; configsMissingFromCachix.save())
        {
            warningf(
                "Nixos configuration '%s' is not in cachix.\nExpected Cachix URL: %s\n",
                config.name.bold,
                config.cacheUrl.bold
            );
        }

        if (!configsMissingFromCachix.empty)
            throw new Exception("Some Nixos configurations are not in cachix. Please cache them first.");

        auto spec = nixosConfigs.createMachineDeploySpec().toJSON;

        infof("Deploy spec: %s", spec.toPrettyString(JSONOptions.doNotEscapeSlashes));

        writeFile(deploySpecFile, spec.toString());
    }
    else
    {
        warningf(
            "Reusing existing deploy spec at '%s':\n---\n%s\n---",
            deploySpecFile.bold,
            deploySpecFile.readText().parseJSON.fromJSON!DeploySpec
        );
    }

    spawnProcessInline([
        "cachix", "deploy", "activate", deploySpecFile, "--async"
    ]);
}
