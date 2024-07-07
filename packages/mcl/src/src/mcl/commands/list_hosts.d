module mcl.commands.list_hosts;

import mcl.utils.ssh : scan_hosts;

export void list_hosts()
{
    import std.stdio : writeln;
    // auto hosts = scan_hosts([192,168,1], 1, 255, "user");
    writeln(hosts);
}

