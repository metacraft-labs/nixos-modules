module mcl.commands.coda.parser;

import std.algorithm : canFind, filter, startsWith;
import std.array : array;
import std.conv : to, ConvException;
import std.string : indexOf, split, strip, toLower;

import mcl.utils.coda.types : Table;

// =============================================================================
// REPL Command Types
// =============================================================================

struct ReplCommand
{
    enum Type
    {
        help,
        tables,
        describe,
        select,
        show,
        count,
        quit,
        unknown
    }

    Type type;
    string tableName;
    string whereColumn;
    string whereValue;
    string rowId;
    int limit = 20;
    string rawInput;
}

// =============================================================================
// Command Parsing
// =============================================================================

/// Parse a REPL command from user input
ReplCommand parseReplCommand(string input)
{
    ReplCommand cmd;
    cmd.rawInput = input;

    auto normalized = input.strip;
    if (normalized.length == 0)
    {
        cmd.type = ReplCommand.Type.unknown;
        return cmd;
    }

    auto tokens = normalized.split();
    if (tokens.length == 0)
    {
        cmd.type = ReplCommand.Type.unknown;
        return cmd;
    }

    auto command = tokens[0].toLower;

    switch (command)
    {
        case "help", "h", "?":
            cmd.type = ReplCommand.Type.help;
            break;

        case "tables", "table", "ls":
            cmd.type = ReplCommand.Type.tables;
            break;

        case "describe", "desc", "schema":
            cmd.type = ReplCommand.Type.describe;
            cmd.tableName = tokens.length > 1 ? tokens[1] : "";
            break;

        case "select", "sel", "s":
            cmd.type = ReplCommand.Type.select;
            cmd = parseSelectCommand(tokens, cmd);
            break;

        case "show", "get":
            cmd.type = ReplCommand.Type.show;
            cmd.tableName = tokens.length > 1 ? tokens[1] : "";
            cmd.rowId = tokens.length > 2 ? tokens[2] : "";
            break;

        case "count":
            cmd.type = ReplCommand.Type.count;
            cmd.tableName = tokens.length > 1 ? tokens[1] : "";
            break;

        case "quit", "exit", "q":
            cmd.type = ReplCommand.Type.quit;
            break;

        default:
            cmd.type = ReplCommand.Type.unknown;
    }

    return cmd;
}

/// Parse a select command with optional where clause and limit
ReplCommand parseSelectCommand(string[] tokens, ReplCommand cmd)
{
    // Patterns:
    // select <table>
    // select <table> limit N
    // select <table> where <col>=<val>
    // select <table> where <col>=<val> limit N

    if (tokens.length < 2)
    {
        cmd.tableName = "";
        return cmd;
    }

    cmd.tableName = tokens[1];

    // Parse remaining tokens
    for (size_t i = 2; i < tokens.length; i++)
    {
        auto token = tokens[i].toLower;

        if (token == "where" && i + 1 < tokens.length)
        {
            // Parse where clause (col=val)
            auto whereClause = tokens[i + 1];
            auto eqIdx = whereClause.indexOf('=');
            if (eqIdx > 0)
            {
                cmd.whereColumn = whereClause[0 .. eqIdx];
                cmd.whereValue = whereClause[eqIdx + 1 .. $];
            }
            i++;
        }
        else if (token == "limit" && i + 1 < tokens.length)
        {
            try
            {
                cmd.limit = tokens[i + 1].to!int;
            }
            catch (ConvException)
            {
                // Keep default limit
            }
            i++;
        }
    }

    return cmd;
}

// =============================================================================
// Table Name Resolution
// =============================================================================

/// Resolve table name with fuzzy matching (case-insensitive, partial match)
/// Returns table ID if found, null otherwise
string resolveTableId(string input, Table[] tables)
{
    if (input.length == 0)
        return null;

    auto inputLower = input.toLower;

    // Exact match first (by name)
    foreach (ref t; tables)
        if (t.name.toLower == inputLower)
            return t.id;

    // Exact match by ID
    foreach (ref t; tables)
        if (t.id == input)
            return t.id;

    // Partial match (starts with)
    foreach (ref t; tables)
        if (t.name.toLower.startsWith(inputLower))
            return t.id;

    // Contains match
    foreach (ref t; tables)
        if (t.name.toLower.canFind(inputLower))
            return t.id;

    return null;
}

/// Get table name by ID
string getTableName(string tableId, Table[] tables)
{
    foreach (ref t; tables)
        if (t.id == tableId)
            return t.name;
    return tableId;
}

// =============================================================================
// Unit Tests
// =============================================================================

@("coda.parser.parseReplCommand.help")
unittest
{
    auto cmd = parseReplCommand("help");
    assert(cmd.type == ReplCommand.Type.help);

    cmd = parseReplCommand("h");
    assert(cmd.type == ReplCommand.Type.help);

    cmd = parseReplCommand("?");
    assert(cmd.type == ReplCommand.Type.help);
}

@("coda.parser.parseReplCommand.tables")
unittest
{
    auto cmd = parseReplCommand("tables");
    assert(cmd.type == ReplCommand.Type.tables);

    cmd = parseReplCommand("ls");
    assert(cmd.type == ReplCommand.Type.tables);
}

@("coda.parser.parseReplCommand.describe")
unittest
{
    auto cmd = parseReplCommand("describe Employees");
    assert(cmd.type == ReplCommand.Type.describe);
    assert(cmd.tableName == "Employees");

    cmd = parseReplCommand("desc Sites");
    assert(cmd.type == ReplCommand.Type.describe);
    assert(cmd.tableName == "Sites");
}

@("coda.parser.parseReplCommand.select")
unittest
{
    auto cmd = parseReplCommand("select Employees");
    assert(cmd.type == ReplCommand.Type.select);
    assert(cmd.tableName == "Employees");
    assert(cmd.limit == 20);

    cmd = parseReplCommand("select Employees limit 5");
    assert(cmd.type == ReplCommand.Type.select);
    assert(cmd.tableName == "Employees");
    assert(cmd.limit == 5);

    cmd = parseReplCommand("select Employees where Status=Active");
    assert(cmd.type == ReplCommand.Type.select);
    assert(cmd.tableName == "Employees");
    assert(cmd.whereColumn == "Status");
    assert(cmd.whereValue == "Active");

    cmd = parseReplCommand("select Employees where Status=Active limit 10");
    assert(cmd.type == ReplCommand.Type.select);
    assert(cmd.tableName == "Employees");
    assert(cmd.whereColumn == "Status");
    assert(cmd.whereValue == "Active");
    assert(cmd.limit == 10);
}

@("coda.parser.parseReplCommand.show")
unittest
{
    auto cmd = parseReplCommand("show Employees i-abc123");
    assert(cmd.type == ReplCommand.Type.show);
    assert(cmd.tableName == "Employees");
    assert(cmd.rowId == "i-abc123");
}

@("coda.parser.parseReplCommand.count")
unittest
{
    auto cmd = parseReplCommand("count Employees");
    assert(cmd.type == ReplCommand.Type.count);
    assert(cmd.tableName == "Employees");
}

@("coda.parser.parseReplCommand.quit")
unittest
{
    auto cmd = parseReplCommand("quit");
    assert(cmd.type == ReplCommand.Type.quit);

    cmd = parseReplCommand("exit");
    assert(cmd.type == ReplCommand.Type.quit);

    cmd = parseReplCommand("q");
    assert(cmd.type == ReplCommand.Type.quit);
}

@("coda.parser.parseReplCommand.unknown")
unittest
{
    auto cmd = parseReplCommand("foobar");
    assert(cmd.type == ReplCommand.Type.unknown);
    assert(cmd.rawInput == "foobar");
}

@("coda.parser.resolveTableId")
unittest
{
    Table[] tables = [
        Table(id: "grid-abc", name: "Employees"),
        Table(id: "grid-def", name: "Sites"),
        Table(id: "grid-ghi", name: "EmployeeSeatAssignments"),
    ];

    // Exact match
    assert(resolveTableId("Employees", tables) == "grid-abc");
    assert(resolveTableId("employees", tables) == "grid-abc");

    // ID match
    assert(resolveTableId("grid-abc", tables) == "grid-abc");

    // Partial match
    assert(resolveTableId("Emp", tables) == "grid-abc");
    assert(resolveTableId("Seat", tables) == "grid-ghi");

    // No match
    assert(resolveTableId("NonExistent", tables) is null);
}
