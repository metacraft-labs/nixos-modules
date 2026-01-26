module mcl.commands.invoices.command;

import argparse : Command, Default, Description, matchCmd, NamedArgument, Placeholder, Required, SubCommand;

import mcl.commands.invoices.match : MatchArgs, doMatch;
import mcl.commands.invoices.list : ListArgs, listProducts;
import mcl.commands.invoices.coda : importAllInvoiceData;

// =============================================================================
// Top-Level Invoices Command
// =============================================================================

@(Command("invoices", "invoice")
    .Description("Invoice management commands"))
struct InvoicesArgs
{
    SubCommand!(
        MatchArgs,
        ListArgs,
        ImportToCodaArgs,
        Default!UnknownSubcommandArgs
    ) cmd;
}

// =============================================================================
// Import to Coda Subcommand
// =============================================================================

@(Command("import-to-coda")
    .Description("Import invoice data to Coda document"))
struct ImportToCodaArgs
{
    @(NamedArgument(["invoices"])
        .Placeholder("DIR")
        .Required()
        .Description("Directory containing individual invoice CSV files"))
    string invoicesDir;

    @(NamedArgument(["doc-id"])
        .Placeholder("ID")
        .Description("Coda document ID (default: SIcXMyTJrL)"))
    string docId = "SIcXMyTJrL";
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

/// Main invoices command dispatcher
int invoices(InvoicesArgs args)
{
    return args.cmd.matchCmd!(
        (MatchArgs a) => doMatch(a),
        (ListArgs a) => listProducts(a),
        (ImportToCodaArgs a) => importToCoda(a),
        (UnknownSubcommandArgs _) => showHelp()
    );
}

/// Import invoice data to Coda
int importToCoda(ImportToCodaArgs args)
{
    import std.file : exists;
    import std.stdio : stderr;

    if (!exists(args.invoicesDir))
    {
        stderr.writeln("Error: invoices directory not found: ", args.invoicesDir);
        return 1;
    }

    importAllInvoiceData(args.docId, args.invoicesDir);
    return 0;
}

/// Show help when no subcommand is provided
int showHelp()
{
    import std.stdio : writeln;
    writeln("Usage: mcl invoices <subcommand> [options]");
    writeln();
    writeln("Subcommands:");
    writeln("  match           Match hardware parts to purchase invoices");
    writeln("  list            List products by category from invoices");
    writeln("  import-to-coda  Import invoice data to Coda document");
    writeln();
    writeln("Use 'mcl invoices <subcommand> --help' for more information.");
    return 0;
}
