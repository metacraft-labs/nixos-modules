module mcl.commands.compare_disko;

import mcl.utils.env : optional, parseEnv;
import mcl.utils.nix : nix;
import mcl.utils.path : getTopLevel;
import mcl.utils.process : execute;

import std.typecons : Tuple, tuple;
import std.file : mkdirRecurse, exists, rmdirRecurse;
import std.format : fmt = format;
import std.stdio;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.file : write;
import std.logger : tracef, errorf, infof;
import std.process : environment;
import mcl.utils.log : errorAndExit;

struct Params
{
    @optional() string baseBranch;

    void setup(){
        if (baseBranch == null){
            baseBranch = "main";
        }
    }
}

struct MachineChanges{
    string machine;
    bool _config;
    bool _create;
}

// TODO: handle case where a machine is missing from one branch
export void compare_disko(string[] args){
    nix.eval!JSONValue("", [], "");
    const params = parseEnv!Params;
    JSONValue configurations = nix.flake!JSONValue("", [], "show");
    string[] machines;
    foreach (string k, JSONValue v; configurations["nixosConfigurations"]){
        if (k[$-3 .. $] != "-vm"            &&
            k != "gitlab-runner-container"  &&
            k != "minimal-container"        )
        {
            machines ~= k;
        }
    }

    string gitRoot = getTopLevel();
    string worktreeBaseBranch = gitRoot~"-"~params.baseBranch;

    if (execute("git rev-parse --abbrev-ref HEAD") == params.baseBranch){
        errorAndExit("Trying to compare branch "~params.baseBranch~" with itself. Quitting.");
    }

    execute(["git", "worktree" , "add", worktreeBaseBranch, params.baseBranch]);
    string freshTestsDir = gitRoot~"/disko-tests";
    string staleTestsDir = worktreeBaseBranch~"/disko-tests";
    mkdirRecurse(staleTestsDir);
    mkdirRecurse(freshTestsDir);

    Tuple!(string , string )[] machineDiffs;
    MachineChanges[] machineChanges;

    foreach (string m; machines){
        MachineChanges mc;
        mc.machine = m;
        foreach (setting; __traits(allMembers, MachineChanges)){
            static if (is(typeof(__traits(getMember, mc, setting)) == bool)){
                string new_setting =
                    nix.eval(gitRoot~"#nixosConfigurations."~m~".config.disko.devices."~setting, [
                    "--option", "warn-dirty", "false",
                    "--accept-flake-config"]);
                tracef("CREATING %s_%s_new FILE", m, setting);
                write(freshTestsDir~"/"~m~"_"~setting~"_new", new_setting);
                string old_setting =
                    nix.eval(worktreeBaseBranch~"#nixosConfigurations."~m~".config.disko.devices."~setting, [
                    "--option", "warn-dirty", "false",
                    "--accept-flake-config"]);
                tracef("CREATING %s_%s_old FILE", m, setting);
                write(staleTestsDir~"/"~m~"_"~setting~"_old", old_setting);


                string diff = execute([
                    "git", "--no-pager", "diff", "--no-index",
                    staleTestsDir~"/"~m~"_"~setting~"_old",
                    freshTestsDir~"/"~m~"_"~setting~"_new"]);

                if (diff == ""){
                    infof("✔ NO DIFFERENCE IN %s", m);
                    __traits(getMember, mc, setting) = true;
                }
                else{
                    infof("✖ DIFFERENCE IN %s", m);
                    __traits(getMember, mc, setting) = false;
                }
            }
        }
        machineChanges ~= mc;
    }
    infof("------------------------------------------------------");
    if(machineDiffs.length == 0){
        infof("✔✔✔ NO CONFIGS WITH DIFFS");
    }
    else{
        infof("✖✖✖ LIST OF CONFIGS WITH DIFFS");
        foreach(mc; machineChanges){
            infof(mc.machine);
        }
    }
    create_comment(machineChanges);

    // Cleanup
    execute(["git", "worktree" , "remove", worktreeBaseBranch, "--force"]);
    rmdirRecurse(freshTestsDir);
}

void create_comment(MachineChanges[] machineChanges){
    string data = "Thanks for your Pull Request!";
    if (machineChanges.length == 0){
        data ~="\n\n✅  There have been no changes to disko configs";
    }
    else{
        // TODO: Change the generation of the table to have as many collumns as fields in MachineChanges at compile time
        data ~= "\n\nBellow you will find a summary of machines and whether their disko attributes have differences.";

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
                static if (is(typeof(__traits(getMember, mc, field)) == bool)){
                    data~="| " ~ (__traits(getMember, mc, field) ? "🟩" : "⚠️") ~ " ";
                }
                else static if (is(typeof(__traits(getMember, mc, field)) == string)){
                    data~="| " ~ __traits(getMember, mc, field) ~ " ";
                }
                else{
                    assert(0);
                }
            }
            data ~= "|\n";
        }
    }
    write("comment.md", data);
}
