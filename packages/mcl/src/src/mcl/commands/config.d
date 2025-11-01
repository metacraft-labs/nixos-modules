module mcl.commands.config;

import std.algorithm : canFind;
import std.array : array;
import std.process : ProcessPipes, Redirect, wait, environment;
import std.range : drop, front;
import std.stdio : writeln;
import std.string : indexOf;
import std.sumtype : SumType, match;

import argparse;

import mcl.utils.env : optional, parseEnv;
import mcl.utils.fetch : fetchJson;
import mcl.utils.log : errorAndExit;
import mcl.utils.nix : nix, queryStorePath;
import mcl.utils.process : execute;
import mcl.utils.string : camelCaseToCapitalCase;

@(Command("config").Description("Manage NixOS machine configurations"))
export struct config_args
{
    @SubCommands SumType!(
        sys_args,
        home_args,
        start_vm_args,
        Default!unknown_command_args
    ) cmd;
}

@(Command("sys").Description("Manage system configurations"))
struct sys_args
{
    @SubCommands SumType!(
        sys_apply_args,
        sys_edit_args,
        Default!unknown_command_args
    ) cmd;
}

@(Command("apply").Description("Apply system configuration"))
struct sys_apply_args
{
    @(PositionalArgument(0).Placeholder("machine-name").Description("Name of the machine"))
    string machineName;
}

@(Command("edit").Description("Edit system configuration"))
struct sys_edit_args
{
    @(PositionalArgument(0).Placeholder("machine-name").Description("Name of the machine"))
    string machineName;
}

@(Command("home").Description("Manage home configurations"))
struct home_args
{
    @SubCommands SumType!(
        home_apply_args,
        home_edit_args,
        Default!unknown_command_args
    ) cmd;
}

@(Command("apply").Description("Apply user configuration"))
struct home_apply_args
{
    @(PositionalArgument(0).Placeholder("desktop/server").Description("Type of home configuration"))
    string type;
}

@(Command("edit").Description("Edit user configuration"))
struct home_edit_args
{
    @(PositionalArgument(0).Placeholder("desktop/server").Description("Type of home configuration"))
    string type;
}

@(Command("start-vm").Description("Start a VM"))
struct start_vm_args
{
    @(PositionalArgument(0).Optional().Placeholder("vm-name").Description("Name of the VM"))
    string vmName = "";
}

@(Command(" ").Description(" "))
struct unknown_command_args
{
}

int unknown_command(unknown_command_args unused)
{
    errorAndExit("Unknown command. Use --help for a list of available commands.");
    return 1;
}

export int config(config_args args)
{
    if (!checkRepo())
    {
        errorAndExit(
            "This command must be run from a repository containing a NixOS machine configuration");
    }

    return args.cmd.match!(
        (sys_args a) => sys(a),
        (home_args a) => home(a),
        (start_vm_args a) => startVM(a.vmName),
        (unknown_command_args a) => unknown_command(a)
    );
}

bool checkRepo()
{
    const string[] validRepos = ["nixos-machine-config", "infra-lido"];
    string remoteOriginUrl = execute([
        "git", "config", "--get", "remote.origin.url"
    ], false);

    foreach (string repo; validRepos)
    {
        if (remoteOriginUrl.indexOf(repo) != -1)
        {
            return true;
        }
    }
    return false;
}

int executeCommand(string command)
{
    auto exec = execute!ProcessPipes(command, true, false, Redirect.stderrToStdout);
    return wait(exec.pid);
}

int edit(string type, string path)
{
    string editor = environment.get("EDITOR", "vim");
    string user = environment.get("USER", "root");
    writeln("Editing " ~ path ~ " configuration from: ", path);
    final switch (type)
    {
    case "system":
        return executeCommand(editor ~ " machines/*/" ~ path ~ "/*.nix");
    case "user":
        return executeCommand(editor ~ " users/" ~ user ~ "/gitconfig " ~ "users/" ~ user ~ "/*.nix " ~ "users/" ~ user ~ "/home-" ~ path ~ "/*.nix");
    }
}

int apply(string type, string value)
{
    writeln("Applying ", type, " configuration from: ", value);
    return executeCommand("just switch-" ~ type ~ " " ~ value);
}

int sys(sys_args args)
{
    return args.cmd.match!(
        (sys_apply_args a) => apply("system", a.machineName),
        (sys_edit_args a) => edit("system", a.machineName),
        (unknown_command_args a) => unknown_command(a)
    );
}

int home(home_args args)
{

    return args.cmd.match!(
        (home_apply_args a) {
        writeln("Applying home configuration from: ", a.type);
        return executeCommand("just switch-home " ~ a.type);
    },
        (home_edit_args a) => "user".edit(a.type),
        (unknown_command_args a) => unknown_command(a)
    );
}

int startVM(string vmName)
{
    writeln("Starting VM: ", vmName);
    return executeCommand("just start-vm " ~ vmName);
}
