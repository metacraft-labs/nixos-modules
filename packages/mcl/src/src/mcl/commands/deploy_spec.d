module mcl.commands.deploy_spec;

import std.logger : warningf;
import std.file : exists;
import std.path : buildPath;

import mcl.utils.process : spawnProcessInline;
import mcl.utils.path : resultDir;

import mcl.commands.ci_matrix : ci_matrix;

export void deploy_spec()
{
    auto deploySpecFile = resultDir.buildPath("cachix-deploy-spec.json");

    if (!deploySpecFile.exists)
    {
        warningf("'%s' file not found - building...", deploySpecFile);
        ci_matrix();
    }

    spawnProcessInline([
        "cachix", "deploy", "activate", deploySpecFile
    ]);
}
