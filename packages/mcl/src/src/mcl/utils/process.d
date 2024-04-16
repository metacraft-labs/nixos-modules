module mcl.utils.process;
import mcl.utils.test;

string execute(string[] args)
{
    import std.exception : enforce;
    import std.format : format;
    import std.process : pipeProcess, wait, Redirect;
    import std.logger : log, LogLevel;
    import std.array : join;
    import std.conv : to;

    LogLevel.info.log("$ %-(%s %)", args);

    auto res = pipeProcess(args, Redirect.all);
    string output = res.stdout.byLine().join("\n").to!string;
    string err = res.stderr.byLine().join("\n").to!string;

    int status = wait(res.pid);
    enforce(status == 0, "Command `%s` failed with status %s, stderr: \n%s".format(args, status, err));
    return output;
}

@("execute")
unittest
{
    import std.exception : assertThrown;

    assert(execute(["echo", "hello"]) == "hello");
    assert(execute(["true"]) == "");
    assertThrown(execute(["false"]), "Command `false` failed with status 1");
}
