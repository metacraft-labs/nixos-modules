module mcl.utils.process;

import mcl.utils.test;

import mcl.utils.tui : bold;

import std.process : ProcessPipes, Redirect;
import std.string : split, strip;
import core.sys.posix.unistd : geteuid;
import std.json : JSONValue, parseJSON;

bool isRoot() => geteuid() == 0;

struct ProcessResult
{
    int exitCode;
    string stdout;
    string stderr;

    bool succeeded() const => exitCode == 0;
}

alias ProcessRunner = ProcessResult delegate(string[] args);
alias ProcessInputRunner = ProcessResult delegate(string[] args, string input);

T execute(T = string)(string args, bool printCommand = true, bool returnErr = false, Redirect redirect = Redirect.all) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
{
    return execute!T(args.strip.split(" "), printCommand, returnErr, redirect);
}
T execute(T = string)(string[] args, bool printCommand = true, bool returnErr = false, Redirect redirect = Redirect.all, bool throwOnError = false, bool logErrors = true) if (is(T == string) || is(T == ProcessPipes) || is(T == JSONValue))
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
        infof("\n$ `%s`", cmd.bold);
    else
        tracef("\n$ `%s`", cmd.bold);
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
            if (logErrors)
                errorf("Command failed:
                ---
                $ `%s`
                stdout: `%s`
                stderr: `%s`
                ---", cmd.bold, stdout.bold, stderr.bold);
            if (throwOnError)
                enforce(0, "Process failed.");
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

ProcessResult runProcessCapture(string[] args, bool echoOutput = false)
{
    import std.array : join;
    import std.algorithm : map, canFind;
    import std.conv : to;
    import std.process : pipeProcess, wait, escapeShellCommand;
    import std.logger : tracef;
    import std.stdio : stdout, stderr;

    const bold = "\033[1m";
    const normal = "\033[0m";
    auto cmd = args.map!(x => x.canFind("*") ? x : x.escapeShellCommand()).join(" ");

    tracef("$ %s%s%s", bold, cmd, normal);

    auto pipes = pipeProcess(args, Redirect.stdout | Redirect.stderr);
    string stdoutText = pipes.stdout.byLine().join("\n").to!string;
    string stderrText = pipes.stderr.byLine().join("\n").to!string;
    int status = wait(pipes.pid);

    if (echoOutput && stdoutText != "")
        stdout.writeln(stdoutText);
    if (echoOutput && stderrText != "")
        stderr.writeln(stderrText);

    return ProcessResult(status, stdoutText, stderrText);
}

ProcessResult runProcessInlineCapture(string[] args)
{
    return runProcessCapture(args, true);
}

ProcessResult runProcessWithInputCapture(string[] args, string input, bool echoOutput = false)
{
    import std.array : join;
    import std.algorithm : map, canFind;
    import std.conv : to;
    import std.process : pipeProcess, wait, escapeShellCommand;
    import std.logger : tracef;
    import std.stdio : stdout, stderr;
    import std.process : Redirect;

    const bold = "\033[1m";
    const normal = "\033[0m";
    auto cmd = args.map!(x => x.canFind("*") ? x : x.escapeShellCommand()).join(" ");

    tracef("$ %s%s%s", bold, cmd, normal);

    auto pipes = pipeProcess(args, Redirect.stdin | Redirect.stdout | Redirect.stderr);
    pipes.stdin.write(input);
    pipes.stdin.close();
    string stdoutText = pipes.stdout.byLine().join("\n").to!string;
    string stderrText = pipes.stderr.byLine().join("\n").to!string;
    int status = wait(pipes.pid);

    if (echoOutput && stdoutText != "")
        stdout.writeln(stdoutText);
    if (echoOutput && stderrText != "")
        stderr.writeln(stderrText);

    return ProcessResult(status, stdoutText, stderrText);
}

bool isInPath(string name)
{
    import std.algorithm : splitter;
    import std.file : exists, isFile;
    import std.path : buildPath;
    import std.process : environment;
    import std.string : toStringz;
    import core.sys.posix.unistd : access, X_OK;

    auto pathVar = environment.get("PATH", "");
    foreach (dir; pathVar.splitter(':'))
    {
        auto candidate = dir.buildPath(name);
        // isFile guards against a searchable directory of the same name;
        // access(X_OK) ensures the file is actually executable.
        if (candidate.exists && candidate.isFile
            && access(candidate.toStringz, X_OK) == 0)
            return true;
    }
    return false;
}

@("isInPath finds executables on PATH")
unittest
{
    // "ls" should always be available on NixOS / any Linux
    assert(isInPath("ls"));
    assert(!isInPath("nonexistent-binary-abc123"));
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
