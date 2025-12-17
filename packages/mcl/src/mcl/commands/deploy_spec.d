module mcl.commands.deploy_spec;

import std.algorithm : filter;
import std.logger : infof, warningf;
import std.file : exists;
import std.path : buildPath;
import std.range : empty;

import argparse : Command, Description;

import mcl.utils.process : spawnProcessInline;
import mcl.utils.path : resultDir;
import mcl.utils.cachix : DeploySpec, createMachineDeploySpec;
import mcl.utils.tui : bold;
import mcl.utils.json : tryDeserializeFromJsonFile, writeJsonFile;

import mcl.commands.ci_matrix : nixEvalJobs, SupportedSystem,CiMatrixBaseArgs;


@(Command("deploy-spec", "deploy_spec")
    .Description("Evaluate the Nixos machine configurations in bareMetalMachines and deploy them to cachix."))
struct DeploySpecArgs {
    mixin CiMatrixBaseArgs!();
}

export int deploy_spec(DeploySpecArgs args)
{
    const deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json");

    DeploySpec spec;

    if (!exists(deploySpecFile))
    {
        auto nixosConfigs = "legacyPackages.x86_64-linux.serverMachines"
            .nixEvalJobs(args);

        auto pkgsNotFoundInCache = nixosConfigs.filter!(c => c.cachedAt.empty);

        foreach (pkg; pkgsNotFoundInCache.save())
        {
            warningf(
                "Nixos configuration '%s' is not in cachix.\nExpected Cachix URL: %s\n",
                pkg.name.bold,
                pkg.getNarInfoUrl(args.binaryCacheUrls[0]).bold
            );
        }

        if (!pkgsNotFoundInCache.empty)
            throw new Exception("Some Nixos configurations are not in cachix. Please cache them first.");

        spec = nixosConfigs.createMachineDeploySpec();
        writeJsonFile(spec, deploySpecFile);
    }
    else
    {
        warningf("Reusing existing deploy spec at:\n'%s'", deploySpecFile.bold);
        spec = deploySpecFile.tryDeserializeFromJsonFile!DeploySpec();
    }

    infof("\n---\n%s\n---", spec);
    infof("%s machines will be deployed.", spec.agents.length);

    if (!spec.agents.length)
        return 0;

    spawnProcessInline([
        "cachix", "deploy", "activate", deploySpecFile, "--async"
    ]);

    return 0;
}
