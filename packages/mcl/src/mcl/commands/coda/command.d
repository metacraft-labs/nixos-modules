module mcl.commands.coda.command;

import std.process : environment;
import std.stdio : writeln;

import argparse : Command, Default, Description, EnvFallback, matchCmd, NamedArgument, Placeholder, SubCommand;

import mcl.commands.coda.repl : runRepl;

// =============================================================================
// Top-Level Coda Command
// =============================================================================

@(Command("coda")
    .Description("Coda document exploration commands"))
struct CodaArgs
{
    @(NamedArgument(["doc-id", "d"])
        .Placeholder("ID")
        .Description("Coda document ID (or set CODA_DOC_ID env var)"))
    string docId;

    @(NamedArgument(["coda-api-token"])
        .Placeholder("TOKEN")
        .Description("Coda API token (or set CODA_API_TOKEN env var)"))
    string apiToken;

    SubCommand!(
        ReplArgs,
        Default!UnknownSubcommandArgs
    ) cmd;
}

// =============================================================================
// REPL Subcommand
// =============================================================================

@(Command("repl")
    .Description("Interactive REPL for exploring Coda documents"))
struct ReplArgs
{
    @(NamedArgument(["no-color"])
        .Description("Disable colored output"))
    bool noColor = false;
}

// =============================================================================
// Unknown Subcommand Handler
// =============================================================================

@(Command("")
    .Description(""))
struct UnknownSubcommandArgs
{
}

// =============================================================================
// Command Handler
// =============================================================================

/// Main coda command dispatcher
int coda(CodaArgs args)
{
    // Resolve doc ID and API token from args or environment
    auto docId = args.docId.length > 0 ? args.docId : environment.get("CODA_DOC_ID", "");
    auto apiToken = args.apiToken.length > 0 ? args.apiToken : environment.get("CODA_API_TOKEN", "");

    return args.cmd.matchCmd!(
        (ReplArgs a) => runRepl(docId, apiToken, a.noColor),
        (UnknownSubcommandArgs _) => showHelp()
    );
}

/// Show help when no subcommand is provided
int showHelp()
{
    writeln("Usage: mcl coda <subcommand> [options]");
    writeln();
    writeln("Subcommands:");
    writeln("  repl    Interactive REPL for exploring Coda documents");
    writeln();
    writeln("Options:");
    writeln("  --doc-id, -d        Coda document ID (or set CODA_DOC_ID)");
    writeln("  --coda-api-token    Coda API token (or set CODA_API_TOKEN)");
    writeln();
    writeln("Example:");
    writeln("  mcl coda repl --doc-id ABC123");
    writeln("  CODA_DOC_ID=ABC123 mcl coda repl");
    return 0;
}
