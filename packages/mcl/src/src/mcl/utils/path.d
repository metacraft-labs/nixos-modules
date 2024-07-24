module mcl.utils.path;
import mcl.utils.test;

import std.process : execute;
import std.string : strip;
import std.file : mkdirRecurse, rmdir, exists;
import std.path : buildPath;

immutable string rootDir, resultDir, gcRootsDir;

shared static this()
{
    rootDir = getTopLevel();
    resultDir = rootDir.buildPath(".result");
    gcRootsDir = resultDir.buildPath("gc-roots");
}

string getTopLevel()
{
    import std.process : environment;
    import mcl.utils.user_info : isNixbld;

    if (isNixbld)
        return environment["NIX_BUILD_TOP"];

    return execute(["git", "rev-parse", "--show-toplevel"]).output.strip;
}

@("rootDir")
unittest
{
    assert(rootDir == getTopLevel());
}

@("resultDir")
unittest
{
    assert(resultDir == rootDir.buildPath(".result"));
}

@("gcRootsDir")
unittest
{
    assert(gcRootsDir == resultDir.buildPath("gc-roots"));
}

void createResultDirs()
{
    mkdirRecurse(gcRootsDir);
}

@("createResultDirs")
unittest
{
    createResultDirs();
    assert(gcRootsDir.exists);

    // rmdir(gcRootsDir());
    // rmdir(resultDir());
    // assert(!gcRootsDir.exists);
}
