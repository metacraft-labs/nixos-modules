module mcl.commands;

import std.meta : ApplyLeft, staticMap;

private enum commandModulesToExport =
[
    "mcl.commands.deploy_spec" : ["deploy_spec"],
    "mcl.commands.ci_matrix" : ["ci_matrix", "print_table", "merge_ci_matrices"],
    "mcl.commands.shard_matrix" : ["shard_matrix"],
    "mcl.commands.ci" : ["ci"],
    "mcl.commands.host_info" : ["host_info"],
    "mcl.commands.machine" : ["machine"],
    "mcl.commands.config" : ["config"],
    "mcl.commands.hosts" : ["hosts"],
];

template ImportAll(alias aa)
{
    import std.meta : AliasSeq;
    alias A = AliasSeq!();
    static foreach (moduleName, symbols; aa)
        static foreach (symbolName; symbols)
            A = AliasSeq!(A, __traits(getMember, imported!moduleName, symbolName));
    alias ImportAll = A;
}

alias SubCommandFunctions = ImportAll!commandModulesToExport;
