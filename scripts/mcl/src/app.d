import std;

import cmds = mcl.commands;

alias supportedCommands = AliasSeq!(
    cmds.get_fstab
);

int main(string[] args)
{
    if (args.length < 2)
    {
        writeln("Error: no command selected.\n");
        usage();
        return 1;
    }

    switch (args[1])
    {
        default:
            writeln("Error: no command selected. Usage:");
            return 1;

    	static foreach (cmd; supportedCommands)
            case __traits(identifier, cmd):
                cmd();
    }

    return 0;
}

void usage()
{
    writeln("Usage:");
	static foreach (cmd; supportedCommands)
        writefln("    mcl %s", __traits(identifier, cmd));

}
