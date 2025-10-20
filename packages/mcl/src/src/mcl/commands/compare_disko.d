module mcl.commands.compare_disko;

import mcl.utils.env : optional, parseEnv;
import mcl.utils.nix : nix;
import mcl.utils.path : getTopLevel;
import mcl.utils.process : execute;
import mcl.utils.log : errorAndExit;

import std.json : JSONValue;
import std.file : write;
import std.logger : infof;
import std.algorithm : uniq;
import std.array;
import std.meta : Filter;

struct Params
{
    @optional() string baseBranch;

    void setup(){
        if (baseBranch == null){
            baseBranch = "main";
        }
    }
}

enum ChangeStatus{
    Unchanged,
    Changed,
    Removed,
    New
}

struct MachineChanges{
    string machine;
    ChangeStatus _config;
    ChangeStatus _create;
}

enum string[] diskoOptions = [ __traits(allMembers, MachineChanges)[1 .. $] ];

string statusToSymbol(ChangeStatus s) {
    final switch(s){
        case ChangeStatus.Unchanged:
            return "🟩";
            break;
        case ChangeStatus.Changed:
            return "⚡";
            break;
        case ChangeStatus.Removed:
            return "🗑";
            break;
        case ChangeStatus.New:
            return "🧩";
            break;
    }
}

export void compare_disko(string[] args){
    const params = parseEnv!Params;

    JSONValue configurations = nix.flake!JSONValue("", [], "show");

    auto machinesNew = appender!(string[])();
    foreach (string k, JSONValue v; configurations["nixosConfigurations"]){
        if (k[$-3 .. $] != "-vm"            &&
            k != "gitlab-runner-container"  &&
            k != "minimal-container"        )
        {
            machinesNew ~= k;
        }
    }

    auto attr = constructCommandAttr("./.", machinesNew[]);
    auto machineOptionsRootNew = nix.eval!JSONValue("", ["--impure", "--expr", attr]);


    string gitRoot = getTopLevel();
    string worktreeBaseBranch = gitRoot~"-"~params.baseBranch;

    if (execute("git rev-parse --abbrev-ref HEAD") == params.baseBranch){
        errorAndExit("Trying to compare branch "~params.baseBranch~" with itself. Quitting.");
    }

    execute(["git", "worktree" , "add", worktreeBaseBranch, params.baseBranch]);

    configurations = nix.flake!JSONValue(worktreeBaseBranch, [], "show");

    auto machinesOld = appender!(string[])();
    foreach (string k, JSONValue v; configurations["nixosConfigurations"]){
        if (k[$-3 .. $] != "-vm"            &&
            k != "gitlab-runner-container"  &&
            k != "minimal-container"        )
        {
            machinesOld ~= k;
        }
    }

    attr = constructCommandAttr(worktreeBaseBranch, machinesOld[]);
    auto machineOptionsRootOld = nix.eval!JSONValue("", ["--impure", "--expr", attr]);

    auto machineChanges = appender!(MachineChanges[])();

    string[] machines = uniq(machinesOld[] ~ machinesNew[]).array;

    foreach (string m; machines){
        MachineChanges mc;
        mc.machine = m;
        if (m in machineOptionsRootOld && !(m in machineOptionsRootNew)){
            static foreach (setting; diskoOptions){
                __traits(getMember, mc, setting) = ChangeStatus.Removed;
            }
        }
        else if (m in machineOptionsRootNew && !(m in machineOptionsRootOld)){
            static foreach (setting; diskoOptions){
                __traits(getMember, mc, setting) = ChangeStatus.New;
            }
        }
        else{
            static foreach (setting; diskoOptions){
                if (machineOptionsRootOld[m][setting] == machineOptionsRootNew[m][setting]){
                    __traits(getMember, mc, setting) = ChangeStatus.Unchanged;
                }
                else{
                    __traits(getMember, mc, setting) = ChangeStatus.Changed;
                }
            }
        }
        machineChanges ~= mc;
    }

    create_comment(machineChanges[]);

    execute(["git", "worktree" , "remove", worktreeBaseBranch, "--force"]);
}

void create_comment(MachineChanges[] machineChanges){
    auto data = appender!string;
    data ~= "Thanks for your Pull Request!";
    if (machineChanges.length == 0){
        data ~="\n\n✅  There have been no changes to disko configs";
    }
    else{
        data ~= "\n\nBellow you will find a summary of machines and whether their disko attributes have differences.";
        data ~= "\n\n**Legend:**";
        data ~= "\n🟩 = No changes";
        data ~= "\n⚡ = Something is different";
        data ~= "\n🗑 = Has been removed";
        data ~= "\n🧩 = Has been added";

        data ~= "\n\n";
        foreach (string field; __traits(allMembers, MachineChanges)){
            data~="| " ~ field ~ " ";
        }
        data ~= "|\n";
        foreach (string field; __traits(allMembers, MachineChanges)){
            data~="| --- ";
        }
        data ~= "|\n";

        foreach(mc; machineChanges){
            foreach (string field; __traits(allMembers, MachineChanges)){
                static if (is(typeof(__traits(getMember, mc, field)) == string)){
                    data~="| " ~ __traits(getMember, mc, field) ~ " ";
                }
                else {
                    data~="| " ~ statusToSymbol(__traits(getMember, mc, field)) ~ " ";
                }
            }
            data ~= "|\n";
        }
    }
    write("comment.md", data[]);
}


string constructCommandAttr(string flakePath, string[] machines){
    auto ret = appender!string;
    ret ~= "let flake = (builtins.getFlake (builtins.toString " ~ flakePath ~ ")); in { ";
    foreach (m; machines){
        ret ~= m ~ " = { ";
        foreach (option; diskoOptions){
            ret ~= option ~ " = flake.nixosConfigurations." ~ m ~ ".config.disko.devices." ~ option ~ "; ";
        }
        ret ~= "}; ";
    }
    ret ~= "}";
    return ret[];
}
