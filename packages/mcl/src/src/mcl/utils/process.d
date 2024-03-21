module mcl.utils.process;

string execute(string[] args) {
    import std.exception : enforce;
    import std.format : format;
    import std.process : execute;
    import std.stdio : stderr;
    stderr.writefln("$ %-(%s %)", args);
    const res = execute(args);
    enforce(res.status == 0, "Command `%s` failed with status %s".format(args, res.status));
    return res.output;
}

unittest
{
    import std.exception : assertThrown;
    assert(execute(["echo", "hello"]) == "hello\n");
    assert(execute(["true"]) == "");
    assertThrown(execute(["false"]), "Command `false` failed with status 1");
}
