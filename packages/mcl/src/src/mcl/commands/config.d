module mcl.commands.config;

import std.algorithm : canFind;
import std.array : array;
import std.process : ProcessPipes, Redirect, wait, environment;
import std.range : drop, front;
import std.stdio : writeln;
import std.string : indexOf;

import mcl.utils.env : optional, parseEnv;
import mcl.utils.fetch : fetchJson;
import mcl.utils.log : errorAndExit;
import mcl.utils.nix : nix, queryStorePath;
import mcl.utils.process : execute;
import mcl.utils.string : camelCaseToCapitalCase;

export void config(string[] args) {
    if (args.length == 0) {
        errorAndExit("Usage: mcl config <subcommand> [args]");
    }
    if (!checkRepo()) {
        errorAndExit("This command must be run from a repository containing a NixOS machine configuration");
    }

    string subcommand = args.front;

    switch (subcommand) {
        case "sys":
            sys(args.drop(1));
            break;
        case "home":
            home(args.drop(1));
            break;
        case "start-vm":
            startVM(args.drop(1));
            break;
        default:
            errorAndExit("Unknown config subcommand " ~ subcommand ~ ". Supported subcommands: sys, home, start-vm");
            break;
    }
}

bool checkRepo()
{
    const string[] validRepos = ["nixos-machine-config", "infra-lido"];
    string remoteOriginUrl = execute(["git", "config", "--get", "remote.origin.url"], false);

    foreach (string repo; validRepos) {
        if (remoteOriginUrl.indexOf(repo) != -1) {
            return true;
        }
    }
    return false;
}

void executeCommand(string command) {
    auto exec = execute!ProcessPipes(command, true, false, Redirect.stderrToStdout);
    wait(exec.pid);
}

void edit(string type, string path) {
    string editor = environment.get("EDITOR", "vim");
    string user = environment.get("USER", "root");
    writeln("Editing " ~ path ~ " configuration from: ", path);
    final switch (type) {
        case "system":
            executeCommand(editor ~ " machines/*/" ~ path ~ "/*.nix");
            break;
        case "user":
            executeCommand(editor~ " users/" ~ user ~ "/gitconfig " ~ "users/" ~ user ~ "/*.nix " ~ "users/" ~ user ~ "/home-"~path~"/*.nix");
            break;
    }
}

void sys(string[] args)
{
    if ((args.length < 1 || args.length > 2) && !["apply", "edit"].canFind(args.front))
    {
        errorAndExit("Usage: mcl config sys apply or mcl config sys apply <machine-name>\n"~
                    "       mcl config sys edit or mcl config sys edit <machine-name>");
    }

    string machineName = args.length > 1 ? args[1] : "";
    final switch (args.front) {
        case "apply":
            writeln("Applying system configuration from: ", machineName);
            executeCommand("just switch-system " ~ machineName);
            break;
        case "edit":
            edit("system", machineName);
            break;
    }
}

void home(string[] args)
{
    if ((args.length != 2) && args.front != "apply")
    {
        errorAndExit("Usage: mcl config home apply <desktop/server>\n"~
                    "       mcl config home edit  <desktop/server>");
    }

    auto type = args[1];
    final switch (args.front) {
        case "apply":
            writeln("Applying home configuration from: ", type);
            executeCommand("just switch-home " ~ type);
            break;
        case "edit":
            edit("user", type);
            break;
    }
}

void startVM(string[] args)
{
    if (args.length != 1)
    {
        errorAndExit("Usage: mcl config start-vm <vm-name>");
    }

    string vmName = args.front;
    writeln("Starting VM: ", vmName);
    executeCommand("just start-vm " ~ vmName);
}
