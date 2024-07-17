module mcl.utils.process;
import mcl.utils.test;
import std.process : ProcessPipes;
import std.string : split, strip;
import core.sys.posix.unistd : geteuid;
import std.json : JSONValue, parseJSON;

bool isRoot() => geteuid() == 0;

T execute(T = string)(string args, bool printCommand = true, bool returnErr = false) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
{
    return execute!T(args.split(" "), printCommand, returnErr);
}
T execute(T = string)(string[] args, bool printCommand = true, bool returnErr = false) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
{
    import std.exception : enforce;
    import std.format : format;
    import std.process : pipeShell, wait, Redirect;
    import std.logger : logf, LogLevel;
    import std.array : join;
    import std.conv : to;

    if (printCommand)
    {
        LogLevel.info.logf("$ %-(%s %)", args);
    }
    auto res = pipeShell(args.join(" "), Redirect.all);
    static if (is(T == ProcessPipes))
    {
        return res;
    }
    else
    {
        string stdout = res.stdout.byLine().join("\n").to!string;
        string stderr = res.stderr.byLine().join("\n").to!string;
        string output = stdout;

        int status = wait(res.pid);
        // enforce(status == 0, "Command `%s` failed with status %s, stderr: \n%s".format(args, status, stderr));
        if (returnErr)
        {
            output = stderr;
        }

        static if (is(T == string)) {
            return output.strip;
        }
        else
        {
            return parseJSON(output.strip);
        }
    }
}

@("execute")
unittest
{
    import std.exception : assertThrown;

    assert(execute(["echo", "hello"]) == "hello");
    assert(execute(["true"]) == "");
    // assertThrown(execute(["false"]), "Command `false` failed with status 1");
}

void spawnProcessInline(string[] args)
{
    import std.logger : tracef;
    import std.exception : enforce;
    import std.process : spawnProcess, wait;

    const bold = "\033[1m";
    const normal = "\033[0m";


    tracef("$ %s%-(%s %)%s", bold, args, normal);

    auto pid = spawnProcess(args);
    enforce(wait(pid) == 0, "Process failed.");
}
