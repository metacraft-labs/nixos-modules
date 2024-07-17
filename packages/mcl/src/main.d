import std.stdio : writefln, writeln, stderr;
import std.array : replace;
import std.getopt : getopt;
import std.logger : info, errorf, LogLevel;

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

    string command = args[1];
    LogLevel logLevel = LogLevel.info;
    args.getopt("log-level", &logLevel);

    setLogLevel(logLevel);

    try switch (args[1])
    {
        default:
            return wrongUsage("unknown command: `" ~ args[1] ~ "`");

        static foreach (cmd; supportedCommands)
        case __traits(identifier, cmd):
        {

            info("Running ", __traits(identifier, cmd));
            cmd();
            info("Execution Succesfull");
            return 0;

        }
    }
    catch (Exception e)
    {
        errorf("Error: %s", e);
        return 1;
    }
}

void setLogLevel(LogLevel l)
{
    import std.logger : globalLogLevel, sharedLog;
    globalLogLevel = l;
    (cast()sharedLog()).logLevel = l;
}

int wrongUsage(string error)
{
    writefln("Error: %s.", error);
    writeln("Usage:\n");
    static foreach (cmd; supportedCommands)
        writefln("    mcl %s", __traits(identifier, cmd));

    return 1;
}
