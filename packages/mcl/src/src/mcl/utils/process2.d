module mcl.utils.process2;

struct Unit {}

struct ProcessResult(T)
{
    import std.typecons : Nullable;

    int status;
    Nullable!T result;
    string output;

    bool opCast(U : bool)() const => status == 0;
}

bool executeStatusOnly(in string[] args)
{
    return cast(bool)execute!(Unit, true)(args);
}

@("executeStatusOnly")
unittest
{
    assert(executeStatusOnly(["true"]));
    assert(!executeStatusOnly(["false"]));
}

ProcessResult!T execute(T = string, bool allowedToFail = false)(in string[] args)
{
    import std.typecons : Nullable, nullable;
    import std.process : pipeShell, wait, Redirect;
    import std.logger : infof, tracef, errorf;
    import std.array : join;
    import std.conv : to;

    const cmd = args.join(" ");

    infof("$ %s", cmd);

    auto res = pipeShell(cmd, Redirect.all);

    string stdout = res.stdout.byLineCopy().join("\n");
    string stderr = res.stderr.byLineCopy().join("\n");

    int status = wait(res.pid);

    if (status != 0)
    {
        if (allowedToFail)
        {
            tracef("Command `%s` failed with status %s, stderr: \n%s", cmd, status, stderr);
            return ProcessResult!T(status, Nullable!T(), stderr);
        }
        else
        {
            errorf("Command `%s` failed with status %s, stderr: \n%s", args, status, stderr);
            assert(0, "Command failed");
        }
    }

    static if (is(T == Unit))
        return ProcessResult!T(status, nullable(Unit()), null);

    else
        return ProcessResult!T(status, nullable(stdout.to!T), null);
}

@("execute")
unittest
{
    import std.exception : assertThrown;

    assert(execute(["echo", "hello"]).result == "hello");
    assert(execute(["true"]).result == "");
    assert(execute!(Unit, true)(["false"]).status == 1);
    assertThrown!Error(execute(["false"]));
}
