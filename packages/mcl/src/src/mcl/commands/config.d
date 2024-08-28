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
        case "home":
        case "start-vm":
        default:
            assert(false, "Unknown config subcommand" ~ args.front);
    }
}

struct Params
{

    void setup()
    {

    }
}
