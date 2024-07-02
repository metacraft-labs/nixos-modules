module mcl.commands.deploy_spec;

import std.stdio : writeln;
import mcl.utils.env : parseEnv;
import mcl.utils.process : execute;
import mcl.utils.path : rootDir;

export void deploy_spec()
{
    const params = parseEnv!Params;

    writeln(execute([
            "cachix", "deploy", "activate", rootDir ~ "cachix-deploy-spec.json",
            "--async"
        ]));

}

struct Params
{
    string cachixAuthToken;
    string cachixCache;

    void setup()
    {
    }
}
