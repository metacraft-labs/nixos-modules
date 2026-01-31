module mcl.commands.coda.repl;

import std.algorithm : filter;
import std.array : array;
import std.net.curl : HTTPStatusException;
import std.stdio : readln, stderr, stdin, stdout, write, writeln, writefln;
import std.string : strip, toLower;

import core.sys.posix.unistd : isatty, STDIN_FILENO;

import mcl.commands.coda.formatter;
import mcl.commands.coda.parser;
import mcl.commands.coda.readline : CompletionCallback, Readline;
import mcl.utils.coda.client : CodaApiClient;
import mcl.utils.coda.types : Column, Row, Table;

// =============================================================================
// REPL Entry Point
// =============================================================================

/// Run the interactive REPL
int runRepl(string docId, string apiToken, bool noColor)
{
    // Validate inputs
    if (apiToken.length == 0)
    {
        stderr.writeln("Error: CODA_API_TOKEN not set. Use --coda-api-token or set the environment variable.");
        return 1;
    }

    if (docId.length == 0)
    {
        stderr.writeln("Error: Document ID not specified. Use --doc-id or set CODA_DOC_ID.");
        return 1;
    }

    auto coda = CodaApiClient(apiToken);
    auto isInteractive = isatty(STDIN_FILENO) != 0;
    auto useColor = !noColor && isInteractive;

    // Preload table list
    Table[] tables;
    try
    {
        tables = coda.listTables(docId);
    }
    catch (HTTPStatusException e)
    {
        if (e.status == 401)
            stderr.writeln("Error: Authentication failed. Check your CODA_API_TOKEN.");
        else if (e.status == 404)
            stderr.writeln("Error: Document not found. Check your document ID.");
        else
            stderr.writefln("Error connecting to Coda (HTTP %d): %s", e.status, e.msg);
        return 1;
    }
    catch (Exception e)
    {
        stderr.writefln("Error connecting to Coda: %s", e.msg);
        return 1;
    }

    if (isInteractive)
    {
        writeln(colored("Coda REPL", Color.bold, useColor), " - Document: ", docId);
        writefln("Found %d tables. Type 'help' for commands, 'quit' to exit.", tables.length);
        writefln("Use arrow keys for history, Ctrl+D to exit.");
        writeln();
    }

    // Initialize readline for interactive mode
    Readline rl;
    rl.completionCallback = (buffer, cursor) => getCompletions(buffer, cursor, tables);
    auto prompt = useColor ? colored("coda> ", Color.green, true) : "coda> ";

    // REPL loop
    while (true)
    {
        string input;

        if (isInteractive)
        {
            auto line = rl.readLine(prompt);
            if (line is null)
                break;  // EOF
            input = line.strip;
        }
        else
        {
            // Pipe mode - use simple readln
            auto line = readln();
            if (line is null)
                break;  // EOF
            input = line.strip;
        }
        if (input.length == 0)
            continue;

        auto cmd = parseReplCommand(input);

        // Handle quit
        if (cmd.type == ReplCommand.Type.quit)
            break;

        try
        {
            executeCommand(coda, docId, cmd, tables, useColor);
        }
        catch (HTTPStatusException e)
        {
            if (e.status == 401)
                stderr.writeln("Error: Authentication failed.");
            else if (e.status == 404)
                stderr.writeln("Error: Resource not found.");
            else if (e.status == 429)
                stderr.writeln("Error: Rate limited. Please wait a moment and try again.");
            else
                stderr.writefln("API error (HTTP %d): %s", e.status, e.msg);
        }
        catch (Exception e)
        {
            stderr.writefln("Error: %s", e.msg);
        }
    }

    if (isInteractive)
        writeln("Goodbye!");

    return 0;
}

// =============================================================================
// Command Execution
// =============================================================================

/// Execute a parsed REPL command
void executeCommand(ref CodaApiClient coda, string docId,
    ReplCommand cmd, ref Table[] tables, bool useColor)
{
    final switch (cmd.type)
    {
        case ReplCommand.Type.help:
            showHelp(useColor);
            break;

        case ReplCommand.Type.tables:
            // Refresh table list
            tables = coda.listTables(docId);
            formatTableList(tables, useColor);
            break;

        case ReplCommand.Type.describe:
            describeTable(coda, docId, cmd.tableName, tables, useColor);
            break;

        case ReplCommand.Type.select:
            selectRows(coda, docId, cmd.tableName, cmd.whereColumn,
                cmd.whereValue, cmd.limit, tables, useColor);
            break;

        case ReplCommand.Type.show:
            showRow(coda, docId, cmd.tableName, cmd.rowId, tables, useColor);
            break;

        case ReplCommand.Type.count:
            countRows(coda, docId, cmd.tableName, tables, useColor);
            break;

        case ReplCommand.Type.quit:
            // Handled in main loop
            break;

        case ReplCommand.Type.unknown:
            stderr.writefln("Unknown command: %s", cmd.rawInput);
            stderr.writeln("Type 'help' for available commands.");
            break;
    }
}

// =============================================================================
// Command Handlers
// =============================================================================

/// Describe a table's schema
void describeTable(ref CodaApiClient coda, string docId, string tableName,
    Table[] tables, bool useColor)
{
    if (tableName.length == 0)
    {
        stderr.writeln("Usage: describe <table>");
        return;
    }

    auto tableId = resolveTableId(tableName, tables);
    if (tableId is null)
    {
        stderr.writefln("Table not found: %s", tableName);
        suggestTables(tableName, tables);
        return;
    }

    auto columns = coda.listColumns(docId, tableId);
    formatSchema(getTableName(tableId, tables), columns, useColor);
}

/// Select rows from a table with optional filtering
void selectRows(ref CodaApiClient coda, string docId, string tableName,
    string whereColumn, string whereValue, int limit,
    Table[] tables, bool useColor)
{
    if (tableName.length == 0)
    {
        stderr.writeln("Usage: select <table> [where <col>=<val>] [limit N]");
        return;
    }

    auto tableId = resolveTableId(tableName, tables);
    if (tableId is null)
    {
        stderr.writefln("Table not found: %s", tableName);
        suggestTables(tableName, tables);
        return;
    }

    auto columns = coda.listColumns(docId, tableId);
    auto rows = coda.listRows(docId, tableId);

    // Apply where filter if specified
    if (whereColumn.length > 0 && whereValue.length > 0)
    {
        // Find column ID by name
        string colId = null;
        foreach (ref c; columns)
        {
            if (c.name.toLower == whereColumn.toLower || c.id == whereColumn)
            {
                colId = c.id;
                break;
            }
        }

        if (colId is null)
        {
            stderr.writefln("Column not found: %s", whereColumn);
            return;
        }

        // Filter rows
        rows = rows.filter!(r => matchesFilter(r, colId, whereValue)).array;
    }

    writeln(colored("Table: ", Color.bold, useColor), getTableName(tableId, tables));
    writefln("Showing %d of %d rows", rows.length > limit ? limit : rows.length, rows.length);
    writeln();

    formatRows(rows, columns, useColor, limit);
}

/// Show detailed view of a single row
void showRow(ref CodaApiClient coda, string docId, string tableName,
    string rowId, Table[] tables, bool useColor)
{
    if (tableName.length == 0 || rowId.length == 0)
    {
        stderr.writeln("Usage: show <table> <row-id>");
        return;
    }

    auto tableId = resolveTableId(tableName, tables);
    if (tableId is null)
    {
        stderr.writefln("Table not found: %s", tableName);
        suggestTables(tableName, tables);
        return;
    }

    auto columns = coda.listColumns(docId, tableId);
    Row row;

    try
    {
        row = coda.getRow(docId, tableId, rowId);
    }
    catch (HTTPStatusException e)
    {
        if (e.status == 404)
        {
            stderr.writefln("Row not found: %s", rowId);
            return;
        }
        throw e;
    }

    formatRowDetail(row, columns, useColor);
}

/// Show row count for a table
void countRows(ref CodaApiClient coda, string docId, string tableName,
    Table[] tables, bool useColor)
{
    if (tableName.length == 0)
    {
        stderr.writeln("Usage: count <table>");
        return;
    }

    auto tableId = resolveTableId(tableName, tables);
    if (tableId is null)
    {
        stderr.writefln("Table not found: %s", tableName);
        suggestTables(tableName, tables);
        return;
    }

    // Get fresh table info for accurate count
    auto table = coda.getTable(docId, tableId);
    writeln(colored("Table: ", Color.bold, useColor), table.name);
    writeln(colored("Row count: ", Color.cyan, useColor), table.rowCount);
    writeln();
}

// =============================================================================
// Helpers
// =============================================================================

/// Check if a row matches a filter condition
bool matchesFilter(Row row, string columnId, string value)
{
    import std.sumtype : match;

    if (auto pVal = columnId in row.values)
    {
        return (*pVal).match!(
            (string s) => s.toLower == value.toLower,
            (int i) => i.to!string == value,
            (double d) => formatDouble(d) == value,
            _ => false,  // bool, arrays, JSONValue - no simple string match
        );
    }
    return false;
}

/// Suggest similar table names when not found
void suggestTables(string input, Table[] tables)
{
    import std.algorithm : filter, map, sort;

    auto inputLower = input.toLower;
    auto suggestions = tables
        .filter!(t => t.name.toLower.canFind(inputLower) ||
            inputLower.length >= 2 && t.name.toLower.startsWith(inputLower[0 .. 2]))
        .map!(t => t.name)
        .array;

    if (suggestions.length > 0 && suggestions.length <= 5)
    {
        stderr.writeln("Did you mean: ", suggestions.join(", "), "?");
    }
}

// =============================================================================
// Auto-Completion
// =============================================================================

/// Available REPL commands for completion
private immutable string[] replCommands = [
    "tables", "describe", "select", "show", "count", "help", "quit"
];

/// Get completions for current input
string[] getCompletions(string buffer, size_t cursor, Table[] tables)
{
    import std.algorithm : among, filter, map, startsWith;
    import std.array : array, split;
    import std.string : strip;

    auto input = buffer[0 .. cursor].strip;
    auto tokens = input.split();

    // Empty input - show all commands
    if (tokens.length == 0)
        return replCommands.dup;

    auto cmd = tokens[0].toLower;

    // Completing first word (command)
    if (tokens.length == 1 && !buffer[0 .. cursor].endsWith(" "))
    {
        return replCommands[]
            .filter!(c => c.startsWith(cmd))
            .map!(c => c.idup)
            .array;
    }

    // Commands that take a table name
    if (cmd.among("describe", "desc", "select", "sel", "s", "show", "get", "count"))
    {
        auto tableNames = tables.map!(t => t.name).array;

        // After command, show/complete table names
        if (tokens.length == 1 && buffer[0 .. cursor].endsWith(" "))
            return tableNames;

        if (tokens.length == 2 && !buffer[0 .. cursor].endsWith(" "))
        {
            auto partial = tokens[1].toLower;
            return tableNames
                .filter!(n => n.toLower.startsWith(partial))
                .array;
        }

        // After table name in select, complete keywords
        if (cmd.among("select", "sel", "s") && tokens.length >= 2)
        {
            if (buffer[0 .. cursor].endsWith(" "))
            {
                // Suggest "where" or "limit" keywords
                if (tokens.length == 2)
                    return ["where", "limit"];
                auto lastToken = tokens[$ - 1].toLower;
                if (lastToken == "where")
                    return [];  // Would need column names, skip for now
                if (lastToken.among("where", "limit"))
                    return [];
            }
            else
            {
                auto lastToken = tokens[$ - 1].toLower;
                if (lastToken.startsWith("w"))
                    return ["where"].filter!(k => k.startsWith(lastToken)).array;
                if (lastToken.startsWith("l"))
                    return ["limit"].filter!(k => k.startsWith(lastToken)).array;
            }
        }
    }

    return [];
}

/// Check if string ends with a character
private bool endsWith(string s, string suffix)
{
    return s.length >= suffix.length && s[$ - suffix.length .. $] == suffix;
}

// Local imports for helper functions
import std.algorithm : canFind, startsWith, among;
import std.array : join;
import std.conv : to;
