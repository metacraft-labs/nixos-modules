module mcl.commands.deploy_spec;

import std.logger : warningf;
import std.file : exists;
import std.path : buildPath;

import mcl.utils.process : spawnProcessInline;
import mcl.utils.path : resultDir;
import mcl.utils.env : parseEnv;

import mcl.commands.ci_matrix : flakeAttr, Params, nixEvalJobs, SupportedSystem;

shared string deploySpecFile;

shared static this()
{
    deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json");
}

export void deploy_spec()
{
    if (!deploySpecFile.exists)
    {
        warningf("'%s' file not found - building...", deploySpecFile);
        createMachineDeploySpec();
    }

    spawnProcessInline([
        "cachix", "deploy", "activate", deploySpecFile
    ]);
}

void createMachineDeploySpec()
{
    import std.algorithm : map;
    import std.array : assocArray;
    import std.json : JSONValue;
    import std.typecons : tuple;
    import std.file : writeFile = write;

    auto params = parseEnv!Params;

    string cachixUrl = "https://" ~ params.cachixCache ~ ".cachix.org";

    auto packages = flakeAttr("legacyPackages", SupportedSystem.x86_64_linux, "bareMetalMachines")
        .nixEvalJobs(cachixUrl);

    auto result = [
        "agents": packages
            .map!(pkg => tuple(pkg.name, pkg.output))
            .assocArray
    ].JSONValue;

    writeFile(deploySpecFile, result.toString());
}
