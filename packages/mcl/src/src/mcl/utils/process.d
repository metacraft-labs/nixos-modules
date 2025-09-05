module mcl.utils.process;

import mcl.utils.test;

import mcl.utils.tui : bold;

import std.process : ProcessPipes, Redirect;
import std.string : split, strip;
import core.sys.posix.unistd : geteuid;
import std.json : JSONValue, parseJSON;

bool isRoot() => geteuid() == 0;

T execute(T = string)(string args, bool printCommand = true, bool returnErr = false, Redirect redirect = Redirect.all) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
{
    return execute!T(args.strip.split(" "), printCommand, returnErr, redirect);
}
T execute(T = string)(string[] args, bool printCommand = true, bool returnErr = false, Redirect redirect = Redirect.all) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
{
    import std.exception : enforce;
    import std.format : format;
    import std.process : pipeShell, wait, escapeShellCommand;
    import std.logger : tracef, errorf, infof;
    import std.array : join;
    import std.algorithm : map, canFind;
    import std.conv : to;

    auto cmd = args.map!(x => x.canFind("*") ? x : x.escapeShellCommand()).join(" ");

    if (printCommand)
    {
        infof("\n$ `%s`", cmd.bold);
    }
    auto res = pipeShell(cmd, redirect);
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

        if (status != 0)
        {
            errorf("Command failed:
            ---
            $ `%s`
            stdout: `%s`
            stderr: `%s`
            ---", cmd.bold, stdout.bold, stderr.bold);
        }
        else
        {
            tracef("
            ---
            $ `%s`
            stdout: `%s`
            stderr: `%s`
            ---", cmd.bold, stdout.bold, stderr.bold);
        }


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

auto spawnProcessInline(bool captureStdout = true)(string[] args)
{
    import std.array : join;
    import std.exception : enforce;
    import std.logger : tracef;
    import std.process : spawnProcess, wait, execute, Config;

    auto cmd = args.join(" ");
    tracef("$ %s", cmd.bold);

    int rc = -1;
    scope (exit) enforce(rc == 0, "Command `" ~ cmd ~ "` failed.");

    static if (captureStdout)
    {
        auto res = execute(args, config: Config.stderrPassThrough);
        rc = res.status;
        return res.output.strip();
    }
    else
    {
        auto pid = spawnProcess(args);
        rc = wait(pid);
        return;
    }
}

@("spawnProcessInline")
unittest
{
    import std.exception : assertThrown, collectExceptionMsg;

    assert(spawnProcessInline(["echo", "hello"]) == "hello");
    assert(spawnProcessInline(["true"]) == "");
    assertThrown(spawnProcessInline(["false"]), "Command `false` failed with status 1");

    assert(
        collectExceptionMsg(
            spawnProcessInline(["false"])
        ) == "Command `false` failed."
    );
}
