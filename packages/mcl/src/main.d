module mcl.main;

import std.stdio : writefln, writeln, stderr;
import std.array : replace;
import std.getopt : getopt;
import std.logger : infof, errorf, LogLevel;
import std.sumtype : SumType, match;
import std.string : stripRight, stripLeft;
import std.algorithm : endsWith;
import std.format : format;
import std.meta : staticMap;
import std.traits : Parameters;
import mcl.utils.path : rootDir;
import mcl.utils.tui : bold;

import mcl.commands : SubCommandFunctions;

import argparse : Command, Description, SubCommands, NamedArgument, Default, CLI;

@(Command(" ").Description(" "))
struct UnknownCommandArgs {}
int unknown_command(UnknownCommandArgs unused)
{
    stderr.writeln("Unknown command. Use --help for a list of available commands.");
    return 1;
}

struct MCLArgs
{
    @NamedArgument(["log-level"])
    LogLevel logLevel = cast(LogLevel)-1;

    @SubCommands
    SumType!(
        staticMap!(Parameters, SubCommandFunctions),
        Default!UnknownCommandArgs
    ) cmd;
}

alias SumTypeCase(alias func) = (Parameters!func args) => func(args);

mixin CLI!MCLArgs.main!((args)
{
    LogLevel logLevel = LogLevel.info;
    if (args.logLevel != cast(LogLevel)-1)
        logLevel = args.logLevel;
    setLogLevel(logLevel);

    int result = args.cmd.match!(
        staticMap!(SumTypeCase, unknown_command, SubCommandFunctions),
    );

    return 0;
});

void setLogLevel(LogLevel l)
{
    import std.logger : globalLogLevel, sharedLog;
    globalLogLevel = l;
    (cast()sharedLog()).logLevel = l;
}
