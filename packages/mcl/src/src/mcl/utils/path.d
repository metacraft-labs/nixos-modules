module mcl.utils.path;
import mcl.utils.test;

import std.process: execute;
import std.string: strip;
import std.file: mkdirRecurse, rmdir,exists;

string getTopLevel() {
    version (unittest)
    {
        return "/tmp/";
    }
    else {
        return  execute(["git", "rev-parse", "--show-toplevel"]).output.strip ~ "/";
    }
}

string _rootDir = "";
string rootDir() {
    return _rootDir == "" ? _rootDir = getTopLevel() : _rootDir;
}

@("rootDir")
unittest {
    assert(rootDir() == getTopLevel());
}

string _resultDir = "";
string resultDir() {
    return _resultDir == "" ? _resultDir = rootDir() ~ ".result/" : _resultDir;
}

@("resultDir")
unittest {
    assert(resultDir() == rootDir() ~ ".result/");
}

string _gcRootsDir = "";
string gcRootsDir() {
    return _gcRootsDir == "" ? _gcRootsDir = resultDir() ~ "gc-roots/" : _gcRootsDir;
}

@("gcRootsDir")
unittest {
    assert(gcRootsDir() == resultDir() ~ "gc-roots/");
}

void createResultDirs() {
    mkdirRecurse(gcRootsDir);
}

@("createResultDirs")
unittest {
    createResultDirs();
    assert(gcRootsDir.exists);

    // rmdir(gcRootsDir());
    // rmdir(resultDir());
    // assert(!gcRootsDir.exists);
}
