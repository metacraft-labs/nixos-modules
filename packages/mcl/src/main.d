import std.stdio : writefln, writeln, stderr;
import std.array : replace;
import std.getopt : getopt;
import std.logger : infof, errorf, LogLevel;

import mcl.utils.path : rootDir;
import mcl.utils.tui : bold;
import cmds = mcl.commands;

alias supportedCommands = imported!`std.traits`.AliasSeq!(
    cmds.get_fstab,
    cmds.deploy_spec,
    cmds.ci_matrix,
    cmds.print_table,
    cmds.shard_matrix,
    cmds.host_info,
    cmds.ci,
    cmds.machine_create,
    cmds.add_task,
);

int main(string[] args)
{
    if (args.length < 2)
        return wrongUsage("no command selected");

    string cmd = args[1];
    LogLevel logLevel = LogLevel.info;
    
    // sorry for that: it breaks my custom `--kind=arg` parsing
    // in add_task.d
    // probably there is a better method, but at least temporarily
    // commented out for our fork 
    // (alexander):
    //
    // args.getopt("log-level", &logLevel);

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
                command(args);
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
    static foreach (cmd; supportedCommands) {
        writefln("    mcl %s", __traits(identifier, cmd));
        static if (__traits(identifier, cmd) == "add_task") {
            cmds.writeAddTaskHelp();
        }
    }
    return 1;
}
