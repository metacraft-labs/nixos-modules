module mcl.commands.deploy_spec;

import std.algorithm : filter;
import std.logger : infof, warningf;
import std.file : exists;
import std.path : buildPath;

import mcl.utils.process : spawnProcessInline;
import mcl.utils.path : resultDir;
import mcl.utils.cachix : cachixNixStoreUrl, DeploySpec, createMachineDeploySpec;
import mcl.utils.tui : bold;
import mcl.utils.json : tryDeserializeFromJsonFile, writeJsonFile;

import mcl.commands.ci_matrix : flakeAttr, params, nixEvalJobs, SupportedSystem;

export void deploy_spec(string[] args)
{
    const deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json");

    DeploySpec spec;

    if (!exists(deploySpecFile))
    {
        auto nixosConfigs = flakeAttr("legacyPackages", SupportedSystem.x86_64_linux, "serverMachines")
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

        spec = nixosConfigs.createMachineDeploySpec();
        writeJsonFile(spec, deploySpecFile);
    }
    else
    {
        warningf("Reusing existing deploy spec at:\n'%s'", deploySpecFile.bold);
        spec = deploySpecFile.tryDeserializeFromJsonFile!DeploySpec;
    }

    infof("\n---\n%s\n---", spec);
    infof("%s machines will be deployed.", spec.agents.length);

    if (!spec.agents.length)
        return;

    spawnProcessInline([
        "cachix", "deploy", "activate", deploySpecFile, "--async"
    ]);
}
