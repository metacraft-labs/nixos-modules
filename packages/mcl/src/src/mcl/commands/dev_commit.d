module mcl.commands.dev_commit;

import std.stdio : writeln;
import mcl.utils.env : parseEnv;
import mcl.utils.process : execute;
import mcl.utils.path : rootDir;
import mcl.utils.log : prompt;
import std.array : split, array, replace;
import std.algorithm : map, startsWith, sort, uniq;
import std.path : stripExtension;
import std.regex : regex, replaceAll, replaceFirst;
import std.conv : to;


string[] modifiedFiles = [];

enum CommitType
{
    feat,
    fix,
    refactor,
    ci,
    docs,
    style,
    config
}

void initGitStatus()
{
    auto status = execute("git status --porcelain", false).split("\n");
    if (status.length)
    {
        modifiedFiles = status.map!(a => stripExtension(a.split(" ")[$-1])).array;
    }
}

string guessType()
{
    if (modifiedFiles.length)
    {
        foreach (string file; modifiedFiles)
        {
            if (file.startsWith("docs/"))
            {
                return "docs";
            }
            else if (file.startsWith(".github/"))
            {
                return "ci";
            }
            else if (file.startsWith(".gitlab/"))
            {
                return "ci";
            }
        }
    }
    return "feat";
}

string guessScope()
{
    auto files = modifiedFiles.map!(a => a
        .replaceAll(regex(r"(src|packages|pkg|apps|libs)/","g"), "")
        .replaceAll(regex(r"mcl/mcl/", "g"), "mcl/")
        .replaceAll(regex(r"mcl/commands/", "g"), "mcl/")
        .replaceFirst(regex(r"/(default|main|index|start|app|init|__init__|entry)$","g"), "")
    ).array.sort.uniq;
    writeln(files);
    return files.to!string;
}

export void dev_commit()
{
    initGitStatus();

    const params = parseEnv!Params;
    CommitType type = prompt!CommitType("Commit type (suggestion: " ~ guessType ~ "): ");
    string scope_ = prompt!string("Scope (suggestion: "~ guessScope ~"): ");

}

struct Params
{
    void setup()
    {
    }
}
