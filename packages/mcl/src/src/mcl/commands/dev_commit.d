module mcl.commands.dev_commit;

import std.algorithm : any, cache, canFind, filter, find, map, sort, startsWith, uniq;
import std.array : appender, array, assocArray, front, join, replace, split;
import std.conv : to;
import std.file : dirEntries, exists, readText, SpanMode;
import std.json : JSONOptions, parseJSON;
import std.parallelism : parallel, taskPool;
import std.path : globMatch, stripExtension;
import std.process : ProcessPipes, wait;
import std.regex : ctRegex, match, Regex, regex, replaceAll, replaceFirst;
import std.stdio : writeln;
import std.string : indexOf, startsWith, strip;
import std.typecons : tuple;
import mcl.utils.env : parseEnv, optional;
import mcl.utils.process : execute;
import mcl.utils.path : rootDir;
import mcl.utils.log : prompt;
import mcl.utils.json : fromJSON;

string[] modifiedFiles = [];
static const enum CommitType
{
    feat,
    fix,
    refactor,
    ci,
    docs,
    style,
    config,
    build,
    chore,
    perf,
    test
}

struct Config
{
    struct Exclude
    {
        string[] startsWith = [];
        string[] contains = [".gitkeep"];
        string[] equals = [
            "src", "packages", "pkg", "pkgs", "apps", "libs", "modules",
            "services", ".git"
        ];
    }

    struct Scope
    {
        string[string] replaceAll = [
            "(src|packages|pkg|pkgs|apps|libs|modules|services)/": "",
            "mcl/mcl/": "mcl/",
            "mcl/commands/": "mcl/",
            "(docs.*/)?(pages/)?docs/": "docs/"
        ];
        string[string] replaceFirst = [
            "^docs/": "",
            "^nix/": "",
            "/(default|main|index|start|app|init|__init__|entry|package)$": ""
        ];
    }

    struct Type
    {
        CommitType[string] equals = [
            ".gitignore": CommitType.config,
        ];
        CommitType[string] contains;
        CommitType[string] startsWith = [
            "docs": CommitType.docs,
            ".github/": CommitType.ci,
            ".gitlab/": CommitType.ci,

        ];
    }

    Exclude exclude;
    Scope _scope;
    Type type;
}

static Config config;

void initGitDiff()
{
    auto status = execute("git diff --name-only --cached", false).split("\n")
        .map!(a => a.strip)
        .cache
        .filter!((a) {
            if (config.exclude.equals.canFind(a))
                return false;
            else if (config.exclude.contains.any!(c => a.indexOf(c) != -1))
                return false;
            else if (config.exclude.startsWith.any!(c => a.startsWith(c)))
                return false;
            else
                return true;
        })
        .array;
    if (status.length)
    {
        modifiedFiles = status
            .map!(a => stripExtension(a.strip)).array;
        writeln("Modified files (staged): ");
        writeln(status.map!(f => "> " ~ f).array.join("\n"));
        writeln("\n");
    }
}

CommitType guessType()
{
    if (modifiedFiles.length)
    {
        foreach (string file; modifiedFiles)
        {
            auto contains = config.type.contains.keys.find!(k => file.indexOf(k) != -1);
            auto startsWith = config.type.startsWith.keys.find!(k => file.startsWith(k));

            if (config.type.equals.keys.canFind(file))
            {
                return config.type.equals[file];
            }
            else if (contains.length)
            {
                return config.type.contains[contains.front];
            }
            else if (startsWith.length)
            {
                return config.type.startsWith[startsWith.front];
            }
        }
    }
    return CommitType.feat;
}

string[] guessScope()
{

    Regex!char[string] replaceAllRegexes = config._scope.replaceAll.keys.map!(
        key => tuple(key, regex(key, "g"))).assocArray;
    Regex!char[string] replaceFirstRegexes = config._scope.replaceFirst.keys.map!(
        key => tuple(key, regex(key, "g"))).assocArray;

    auto files = modifiedFiles
        .map!((a) {
            foreach (i, value; config._scope.replaceAll)
            {
                a = a.replaceAll(replaceAllRegexes[i], value);
            }
            foreach (i, value; config._scope.replaceFirst)
            {
                a = a.replaceFirst(replaceFirstRegexes[i], value);
            }
            return a;
        }
        )
        .array
        .sort
        .uniq
        .array;
    return files;
}

static immutable auto botRegex = ctRegex!(`(\[bot\]|dependabot|actions-bot)`);

string[] getAuthors()
{
    auto authors = execute("git log --format='%aN' | sort -u", false).split("\n");
    return authors
        .filter!(a => !match(a, botRegex))
        .map!(a => a.strip)
        .array ~ [""];
}

struct CommitParams
{
    CommitType type;
    string _scope;
    string shortDescription;
    string description;
    bool isBreaking;
    string breaking;
    bool isIssue;
    int issue;
    string[] coAuthors;
}

string createCommitMessage(CommitParams params)
{
    auto strBuilder = appender!string;
    strBuilder.put(params.type.to!string);
    strBuilder.put("(");
    strBuilder.put(params._scope);
    strBuilder.put("): ");
    strBuilder.put(params.shortDescription);
    if (params.description.length)
    {
        strBuilder.put("\n\n");
        strBuilder.put(params.description);
    }
    if (params.isBreaking)
    {
        strBuilder.put("\n\nBREAKING CHANGE:");
        strBuilder.put(params.breaking);

    }
    if (params.isIssue)
    {
        strBuilder.put("\n\nCloses #");
        strBuilder.put(params.issue.to!string);
    }
    if (params.coAuthors.length)
    {
        strBuilder.put("\n\nCo-authored-by: ");
        strBuilder.put(params.coAuthors.join(", "));
    }
    return strBuilder.toString();
}

CommitParams promptCommitParams(bool automatic)
{
    CommitParams commitParams;
    commitParams.type = automatic ? guessType
        : prompt!CommitType("Commit type (suggestion: " ~ guessType.to!string ~ ")");
    auto scopeSuggestion = guessScope;
    commitParams._scope = automatic ? scopeSuggestion.front
        : prompt!string(
            "Scope (suggestion: " ~ scopeSuggestion.join(", ") ~ ")");
    commitParams.shortDescription = automatic ? "" : prompt!string("Short Description");
    commitParams.description = automatic ? "" : prompt!string("Description");
    commitParams.isBreaking = automatic ? false : prompt!bool("Breaking change");
    commitParams.breaking = commitParams.isBreaking ? prompt!string("Breaking change description")
        : "";
    commitParams.isIssue = automatic ? false : prompt!bool(
        "Does this commit relate to an existing issue");
    if (commitParams.isIssue)
    {
        commitParams.issue = prompt!int("Issue number");
    }
    commitParams.coAuthors = automatic ? [] : prompt!string(
        "Co-authors (comma separated)", getAuthors).split(",").map!(a => a.strip)
        .cache
        .filter!(a => a != "")
        .array;
    return commitParams;
}

export void dev_commit()
{
    Params params = parseEnv!Params;

    string mclFile = rootDir ~ "/.mcl.json";
    if (mclFile.exists)
        config = parseJSON(readText(mclFile), JSONOptions.none).fromJSON!Config;

    initGitDiff();

    CommitParams commitParams = promptCommitParams(params.automatic);

    writeln();
    string commitMessage = createCommitMessage(commitParams);
    writeln(commitMessage);
    writeln();

    bool commit = prompt!bool("Commit?");
    if (commit)
    {
        auto pipes = execute!ProcessPipes("git commit -F -", false);
        pipes.stdin.writeln(commitMessage);
        pipes.stdin.flush();
        pipes.stdin.close();
        writeln(pipes.stdout.byLineCopy.array.join("\n"));
        writeln(pipes.stderr.byLineCopy.array.join("\n"));
        wait(pipes.pid);
    }
}

struct Params
{
    @optional() bool automatic = false;
    void setup()
    {
    }
}
