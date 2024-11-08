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
import mcl.utils.json : toJSON, fromJSON, tryDeserializeFromJsonFile;

import mcl.commands.ci_matrix : flakeAttr, params, Params, nixEvalJobs, SupportedSystem;

export void deploy_spec()
{
    const deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json");

    if (!exists(deploySpecFile))
    {
        Params params = parseEnv!Params;

        auto nixosConfigs = flakeAttr("legacyPackages", SupportedSystem.x86_64_linux, "bareMetalMachines")
            .nixEvalJobs(params.nixCaches);

        auto configsMissingFromCachix = nixosConfigs.filter!(c => !c.isCached);

        foreach (config; configsMissingFromCachix.save())
        {
            warningf("Nixos configuration '%s' is not in cachix.\n", config.name.bold);
        }

        if (!configsMissingFromCachix.empty)
            throw new Exception("Some Nixos configurations are not in cachix. Please cache them first.");

        auto spec = nixosConfigs.createMachineDeploySpec().toJSON;

        infof("Deploy spec: %s", spec.toPrettyString(JSONOptions.doNotEscapeSlashes));

        writeFile(deploySpecFile, spec.toString());
    }
    else
    {
        warningf("Reusing existing deploy spec at:\n'%s'", deploySpecFile.bold);

        warningf("\n---\n%s\n---", deploySpecFile.tryDeserializeFromJsonFile!DeploySpec);
    }

    spawnProcessInline([
        "cachix", "deploy", "activate", deploySpecFile, "--async"
    ]);
}
