import std.stdio : writefln, writeln;

import cmds = mcl.commands;

alias supportedCommands = imported!`std.traits`.AliasSeq!(
    cmds.get_fstab
);

int main(string[] args)
{
    if (args.length < 2)
        return wrongUsage("no command selected");

    try switch (args[1])
    {
        default:
            return wrongUsage("unknown command: `" ~ args[1] ~ "`");

    	static foreach (cmd; supportedCommands)
            case __traits(identifier, cmd):
                cmd();
    }
    catch (Exception e)
    {
        writefln("Error: %s", e.msg);
        return 1;
    }

    return 0;
}

int wrongUsage(string error)
{
    writefln("Error: %s.", error);
    writeln("Usage:\n");
	static foreach (cmd; supportedCommands)
        writefln("    mcl %s", __traits(identifier, cmd));

   return 1;
}
