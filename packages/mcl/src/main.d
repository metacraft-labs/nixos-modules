module mcl.main;

import std.stdio : writefln, writeln, stderr;
import std.array : replace;
import std.getopt : getopt;
import std.logger : infof, errorf, LogLevel;
import std.sumtype : SumType, match;
import std.string : stripRight, stripLeft;
import std.algorithm : endsWith;
import std.format : format;
import mcl.utils.path : rootDir;
import mcl.utils.tui : bold;

import mcl.commands;

import argparse;


@(Command(" ").Description(" "))
struct unknown_command_args {}
int unknown_command(unknown_command_args unused)
{
    stderr.writeln("Unknown command. Use --help for a list of available commands.");
    return 1;
}

template genSubCommandArgs()
{
    const char[] genSubCommandArgs =
        "@SubCommands\n"~
        "SumType!("~
            "get_fstab_args,"~
            "deploy_spec_args,"~
            "host_info_args,"~
            "Default!unknown_command_args"~
        ") cmd;";
}

template genSubCommandMatch()
{
    const char[] generateMatchString = () {
        alias CmdTypes = typeof(MCLArgs.cmd).Types;
        string match = "int result = args.cmd.match!(";

        static foreach (CmdType; CmdTypes)
        {{
            string name = CmdType.stringof.replace("Default!(", "").stripRight(")");
            match ~= format("\n\t(%s a) => %s(a)", name, name.replace("_args", "")) ~ ", ";
        }}
        match = match.stripRight(", ");
        match ~= "\n);";

        return match;
    }();
}

struct MCLArgs
{
    @NamedArgument(["log-level"])
    LogLevel logLevel = cast(LogLevel)-1;
    mixin(genSubCommandArgs!());
}

mixin CLI!MCLArgs.main!((args)
{
    static assert(is(typeof(args) == MCLArgs));

    LogLevel logLevel = LogLevel.info;
    if (args.logLevel != cast(LogLevel)-1)
        logLevel = args.logLevel;
    setLogLevel(logLevel);

    mixin genSubCommandMatch;

                return 0;
});

void setLogLevel(LogLevel l)
{
    import std.logger : globalLogLevel, sharedLog;
    globalLogLevel = l;
    (cast()sharedLog()).logLevel = l;
}
