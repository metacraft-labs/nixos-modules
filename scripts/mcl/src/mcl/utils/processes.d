module mcl.utils.processes;

string execute(string[] args) {
    import std.process : execute;
    import std.stdio : stderr;
    import std.exception : enforce;
    stderr.writefln("$ %-(%s %)", args);
    const res = execute(args);
    enforce(res.status == 0);
    return res.output;
}
