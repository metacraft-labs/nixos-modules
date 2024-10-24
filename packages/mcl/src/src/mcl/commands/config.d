module mcl.commands.config;

import std.stdio : writeln;
import std.conv : to;
import std.json : JSONValue;
import std.format : fmt = format;
import std.exception : enforce;
import std.range : front;

import mcl.utils.env : optional, parseEnv;
import mcl.utils.fetch : fetchJson;
import mcl.utils.nix : queryStorePath, nix;
import mcl.utils.string : camelCaseToCapitalCase;
import mcl.utils.process : execute;

export void config(string[] args)
{
    const params = parseEnv!Params;
    switch (args.front) {
        case "sys":
            sys(params, args);
            break;
        case "home":
            home(params, args);
            break;
        case "start-vm":
            startVM(params, args);
            break;
        default:
            assert(false, "Unknown config subcommand" ~ args.front);
    }
}

void sys(Params params, string[] args)
{
}

void home(Params params, string[] args)
{
}

void startVM(Params params, string[] args)
{
    if (args.length < 2 || args.length > 2)
        assert(false, "Usage: mcl config start-vm <vm-name>");
    else {
        string vmName = args[1];
        writeln("Starting VM: ", vmName);
        execute(["just", "start-vm", vmName]);
    };
}

struct Params
{

    void setup()
    {

    }
}
