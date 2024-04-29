module mcl.utils.process;
import mcl.utils.test;
import std.process : ProcessPipes;
import core.sys.posix.unistd : geteuid;

bool isRoot() => geteuid() == 0;

T execute(T = string)(string[] args, bool printCommand = true, bool returnErr = false) if (is(T == string) || is(T == ProcessPipes))
{
    import std.exception : enforce;
    import std.format : format;
    import std.process : pipeProcess, wait, Redirect;
    import std.logger : log, LogLevel;
    import std.array : join;
    import std.conv : to;

    if (printCommand)
    {
        LogLevel.info.log("$ %-(%s %)", args);
    }
    auto res = pipeProcess(args, Redirect.all);
    static if (is(T == ProcessPipes))
    {
        return res;
    }
    else if (is(T == string))
    {
        string output = res.stdout.byLine().join("\n").to!string;
        string err = res.stderr.byLine().join("\n").to!string;

        int status = wait(res.pid);
        enforce(status == 0, "Command `%s` failed with status %s, stderr: \n%s".format(args, status, err));
        if (returnErr)
        {
            return err;
        }
        return output;
    }
}

@("execute")
unittest
{
    import std.exception : assertThrown;

    assert(execute(["echo", "hello"]) == "hello");
    assert(execute(["true"]) == "");
    assertThrown(execute(["false"]), "Command `false` failed with status 1");
}
