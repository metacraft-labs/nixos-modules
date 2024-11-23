module mcl.commands.config;

import std.stdio : writeln, write;
import std.conv : to;
import std.json : JSONValue;
import std.format : fmt = format;
import std.exception : enforce;
import std.range : front;
import std.string : indexOf, strip;
import std.logger: errorf;
import core.stdc.stdlib: exit;
import std.algorithm : each;
import std.array : array;
import std.process : Redirect, ProcessPipes, wait;

import mcl.utils.env : optional, parseEnv;
import mcl.utils.fetch : fetchJson;
import mcl.utils.nix : queryStorePath, nix;
import mcl.utils.string : camelCaseToCapitalCase;
import mcl.utils.process : execute;

export void config(string[] args)
{
    if (args.length == 0)
    {

        errorf("Usage: mcl config <subcommand> [args]");
        exit(1);
    }
    if (!checkRepo())
    {
        errorf("This command must be run from a repository containing a NixOS machine configuration");
        exit(1);
    }
    switch (args.front) {
        case "sys":
            sys(args[1..$]);
            break;
        case "home":
            home(args[1..$]);
            break;
        case "start-vm":
            startVM(args[1..$]);
            break;
        default:
            errorf("Unknown config subcommand" ~ args.front ~ ". Supported subcommands: sys, home, start-vm");
    }
}

bool checkRepo()
{
    string remoteOriginUrl = execute(["git", "config", "--get", "remote.origin.url"], false);
    return remoteOriginUrl.indexOf("nixos-machine-config") != -1 || remoteOriginUrl.indexOf("infra-lido") != -1;
}

void sys(string[] args)
{
    if ((args.length < 1 || args.length > 2) && args.front != "apply")
    {
        errorf("Usage: mcl config sys apply or mcl config sys apply <machine-name>");
        exit(1);
    }
    else {
        string machineName = args.length > 1 ? args[1] : "";
        writeln("Applying system configuration from: ", machineName);
        auto exec = execute!ProcessPipes( "just switch-system " ~ machineName, true, false, Redirect.stderrToStdout);
        wait(exec.pid);
    };
}

void home(string[] args)
{
    if ((args.length != 2) && args.front != "apply")
    {
        errorf("Usage: mcl config home apply <desktop/server>");
        exit(1);
    }
    else {
        auto type = args[1];
        writeln("Applying home configuration from: ", type);
        auto exec = execute!ProcessPipes( ["just", "switch-home", type], true, false, Redirect.stderrToStdout);
        wait(exec.pid);
    }
}

void startVM(string[] args)
{
    if (args.length < 1 || args.length > 1)
    {
        errorf("Usage: mcl config start-vm <vm-name>");
        exit(1);
    }
    else {
        string vmName = args.front;
        writeln("Starting VM: ", vmName);
        execute(["just", "start-vm", vmName]);
    };
}
