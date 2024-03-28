module mcl.utils.path;

import std.process: execute;
import std.string: strip;
import std.file: mkdirRecurse;

string _rootDir = "";
string rootDir() {
    return _rootDir == "" ? _rootDir = execute(["git", "rev-parse", "--show-toplevel"]).output.strip ~ "/" : _rootDir;
}
string _resultDir = "";
string resultDir() {
    return _resultDir == "" ? _resultDir = rootDir() ~ ".result/" : _resultDir;
}
string _gcRootsDir = "";
string gcRootsDir() {
    return _gcRootsDir == "" ? _gcRootsDir = resultDir() ~ "gc-roots/" : _gcRootsDir;
}

void createResultDirs() {
    mkdirRecurse(gcRootsDir);
}
