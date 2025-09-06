import std.stdio : writefln, writeln, stderr;
import std.array : array, replace;
import std.getopt : getopt;
import std.logger : infof, errorf, LogLevel;

import mcl.utils.path : rootDir;
import mcl.utils.tui : bold, wrapTextInBox;

import cmds = mcl.commands;

alias supportedCommands = imported!`std.traits`.AliasSeq!(
    cmds.get_fstab,
    cmds.deploy_spec,
    cmds.ci_matrix,
    cmds.print_table,
    cmds.shard_matrix,
    cmds.host_info,
    cmds.ci,
    cmds.machine,
    cmds.config,
);

int main(string[] args)
{
    import std.file : readText;
    import mcl.utils.text : stripAnsi;

    args[1]
        .readText()
        .stripAnsi()
        .writeln();


    if (1) return 0;

    if (args.length < 2)
        return wrongUsage("no command selected");

    string cmd = args[1];
    LogLevel logLevel = LogLevel.info;
    args.getopt("log-level", &logLevel);

    setLogLevel(logLevel);

    infof("Git root: '%s'", rootDir.bold);

    try switch (cmd)
    {
        default:
            return wrongUsage("unknown command: `" ~ cmd ~ "`");

        static foreach (command; supportedCommands)
            case __traits(identifier, command):
            {

                infof("Running %s task", cmd.bold);
                command(args[2..$]);
                infof("Execution Succesfull");
                return 0;
            }
    }
    catch (Exception e)
    {
        errorf("Task %s failed. Error:\n%s", cmd.bold, e);
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
