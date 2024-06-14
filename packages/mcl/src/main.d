import std.stdio : writefln, writeln, stderr;
import std.array : replace;

import cmds = mcl.commands;

alias supportedCommands = imported!`std.traits`.AliasSeq!(
    cmds.get_fstab,
    cmds.deploy_spec,
    cmds.ci_matrix,
    cmds.print_table,
    cmds.shard_matrix,
    cmds.host_info,
    cmds.ci,
    cmds.machine_create
);

int main(string[] args)
{
    if (args.length < 2)
        return wrongUsage("no command selected");

    try
        switch (args[1])
    {
    default:
        return wrongUsage("unknown command: `" ~ args[1] ~ "`");

        static foreach (cmd; supportedCommands)
    case __traits(identifier, cmd):
            {

                stderr.writeln("Running ", __traits(identifier, cmd));
                cmd();
                stderr.writeln("Execution Succesfull");
                return 0;

            }
    }
    catch (Exception e)
    {
        writefln("Error: %s", e);
        return 1;
    }

}

int wrongUsage(string error)
{
    writefln("Error: %s.", error);
    writeln("Usage:\n");
    static foreach (cmd; supportedCommands)
        writefln("    mcl %s", __traits(identifier, cmd));

    return 1;
}
