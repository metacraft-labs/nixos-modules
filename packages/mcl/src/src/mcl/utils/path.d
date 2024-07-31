module mcl.utils.path;

import std.process : execute;
import std.string : strip;
import std.file : mkdirRecurse, rmdir, exists;
import std.format : format;
import std.path : buildNormalizedPath, absolutePath;

immutable string rootDir, resultDir, gcRootsDir;

shared static this()
{
    rootDir = getTopLevel();
    resultDir = rootDir.buildNormalizedPath(".result");
    gcRootsDir = resultDir.buildNormalizedPath("gc-roots");
}

string getTopLevel()
{
    import std.process : environment;
    import mcl.utils.user_info : isNixbld;

    if (isNixbld)
        return environment["NIX_BUILD_TOP"];

    auto res = execute(["git", "rev-parse", "--show-toplevel"]);
    if (res.status != 0)
        return ".".absolutePath.buildNormalizedPath;

    return res.output.strip;
}

@("rootDir")
unittest
{
    assert(rootDir == getTopLevel, "Expected rootDir to return %s, got %s".format(getTopLevel(), rootDir));
}

@("resultDir")
unittest
{
    auto expected = rootDir.buildNormalizedPath(".result");
    assert(resultDir == expected, "Expected resultDir to return %s, got %s".format(expected, resultDir));
}

@("gcRootsDir")
unittest
{
    auto expected = resultDir.buildNormalizedPath("gc-roots/");
    assert(gcRootsDir == expected, "Expected gcRootsDir to return %s, got %s".format(expected, gcRootsDir));
}

void createResultDirs() => mkdirRecurse(gcRootsDir);

@("createResultDirs")
unittest
{
    createResultDirs();
    assert(gcRootsDir.exists, "Expected gcRootsDir to exist, but it doesn't");

    // rmdir(gcRootsDir());
    // rmdir(resultDir());
    // assert(!gcRootsDir.exists, "Expected gcRootsDir to not exist, but it does");
}
