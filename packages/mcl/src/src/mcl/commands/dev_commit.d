module mcl.commands.dev_commit;

import std.stdio : writeln;
import mcl.utils.env : parseEnv;
import mcl.utils.process : execute;
import mcl.utils.path : rootDir;
import mcl.utils.log : prompt;
import std.array : split, array, replace, join;
import std.algorithm : map, startsWith, sort, uniq, filter;
import std.path : stripExtension;
import std.regex : regex, replaceAll, replaceFirst;
import std.conv : to;
import std.string : startsWith, strip;


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
        modifiedFiles = status
        .filter!(a => !a.strip.startsWith("D") && !a.strip.startsWith("??")).array
        .map!(a => stripExtension(a.strip[2..$])).array;
    }
}

string guessType()
{
    if (modifiedFiles.length)
    {
        foreach (string file; modifiedFiles)
        {
            if (file.startsWith("docs"))
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
            else if (file == ".gitignore")
            {
                return "config";
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
        .replaceAll(regex(r"(docs.*/)?(pages/)?docs/", "g"), "docs/")
        .replaceFirst(regex(r"^docs/", "g"), "")
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
