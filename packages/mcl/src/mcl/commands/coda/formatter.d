module mcl.commands.coda.formatter;

import std.algorithm : filter, map, max, maxElement, min;
import std.array : array, join;
import std.conv : to;
import std.json : JSONValue, JSONOptions;
import std.range : repeat;
import std.stdio : write, writeln, writefln;
import std.string : leftJustify;
import std.sumtype : match;

import mcl.utils.coda.types : Column, Row, RowValue, Table;

// =============================================================================
// ANSI Color Codes
// =============================================================================

enum Color : string
{
    reset = "\x1b[0m",
    bold = "\x1b[1m",
    gray = "\x1b[90m",
    cyan = "\x1b[36m",
    green = "\x1b[32m",
    yellow = "\x1b[33m",
}

string colored(string s, Color c, bool useColor)
{
    return useColor ? c ~ s ~ Color.reset : s;
}

// =============================================================================
// Table List Formatting
// =============================================================================

/// Format a list of tables for display
void formatTableList(Table[] tables, bool useColor)
{
    if (tables.length == 0)
    {
        writeln(colored("(no tables found)", Color.gray, useColor));
        return;
    }

    // Calculate column widths
    auto maxNameLen = tables.map!(t => t.name.length).maxElement(10);

    // Calculate source table names for views
    string[] sourceStrs;
    foreach (ref t; tables)
    {
        if (t.tableType == "view")
            sourceStrs ~= getViewSource(t, tables);
        else
            sourceStrs ~= "";
    }
    auto maxSourceLen = sourceStrs.map!(s => s.length).maxElement(6);

    // Header
    writefln("  %-*s  %8s  %-5s  %-*s  %s",
        maxNameLen, colored("Name", Color.cyan, useColor),
        colored("Rows", Color.cyan, useColor),
        colored("Type", Color.cyan, useColor),
        maxSourceLen, colored("Source", Color.cyan, useColor),
        colored("ID", Color.gray, useColor));
    writeln("  ", "-".repeat(maxNameLen + maxSourceLen + 45).array.join);

    // Rows
    foreach (idx, ref t; tables)
    {
        writefln("  %-*s  %8d  %-5s  %-*s  %s",
            maxNameLen, t.name,
            t.rowCount,
            t.tableType,
            maxSourceLen, sourceStrs[idx].length > 0
                ? sourceStrs[idx]
                : colored("-", Color.gray, useColor),
            colored(t.id, Color.gray, useColor));
    }
    writeln();
}

/// Get the source table name for a view
string getViewSource(ref const Table view, Table[] allTables)
{
    import std.regex : regex, matchFirst;

    // First try parentTable.name from API
    if (view.parentTable.name.length > 0)
        return view.parentTable.name;

    // Try to extract from view name patterns like "View of X" or "View N of X"
    auto viewOfPattern = regex(`^View(?: \d+)? of (.+)$`, "i");
    if (auto m = view.name.matchFirst(viewOfPattern))
        return m[1];

    return "";
}

// =============================================================================
// Schema Formatting
// =============================================================================

/// Format table schema (columns)
void formatSchema(string tableName, Column[] columns, bool useColor)
{
    writeln(colored("Table: ", Color.bold, useColor), tableName);
    writeln();

    if (columns.length == 0)
    {
        writeln(colored("  (no columns)", Color.gray, useColor));
        return;
    }

    auto maxNameLen = columns.map!(c => c.name.length).maxElement(10);

    writefln("  %-*s  %-12s  %s",
        maxNameLen, colored("Column", Color.cyan, useColor),
        colored("Type", Color.cyan, useColor),
        colored("Flags", Color.gray, useColor));
    writeln("  ", "-".repeat(maxNameLen + 30).array.join);

    foreach (ref c; columns)
    {
        string[] flags;
        if (c.calculated)
            flags ~= "calculated";
        if (c.display)
            flags ~= "display";

        writefln("  %-*s  %-12s  %s",
            maxNameLen, c.name,
            c.format.type,
            colored(flags.join(", "), Color.gray, useColor));
    }
    writeln();
}

// =============================================================================
// Row Formatting
// =============================================================================

/// Format rows as a table
void formatRows(Row[] rows, Column[] columns, bool useColor, int limit)
{
    if (rows.length == 0)
    {
        writeln(colored("(no rows)", Color.gray, useColor));
        return;
    }

    // Limit rows displayed
    auto displayRows = rows.length > limit ? rows[0 .. limit] : rows;

    // Select columns to display (skip very wide or complex columns)
    auto displayColumns = columns
        .filter!(c => c.format.type != "button" && c.format.type != "attachment")
        .array;

    if (displayColumns.length == 0)
        displayColumns = columns.length > 0 ? [columns[0]] : [];

    // Limit to first 6 columns for readability
    if (displayColumns.length > 6)
        displayColumns = displayColumns[0 .. 6];

    // Calculate column widths based on data
    size_t[] widths;
    foreach (ref col; displayColumns)
    {
        size_t w = col.name.length;
        foreach (ref row; displayRows)
        {
            auto val = formatCellValue(row, col.id);
            w = max(w, min(val.length, 40));
        }
        widths ~= w;
    }

    // Header
    write("  ");
    foreach (idx, ref col; displayColumns)
        write(leftJustify(colored(col.name, Color.cyan, useColor), widths[idx] + 2));
    writeln();

    write("  ");
    foreach (idx, _; displayColumns)
        write("-".repeat(widths[idx]).array.join, "  ");
    writeln();

    // Data rows
    foreach (ref row; displayRows)
    {
        write("  ");
        foreach (idx, ref col; displayColumns)
        {
            auto val = formatCellValue(row, col.id);
            // Truncate long values
            if (val.length > 40)
                val = val[0 .. 37] ~ "...";
            write(leftJustify(val, widths[idx] + 2));
        }
        writeln();
    }

    // Show truncation notice
    if (rows.length > limit)
    {
        writeln();
        writeln(colored("  ... and ", Color.gray, useColor),
            rows.length - limit,
            colored(" more rows (use 'limit' to show more)", Color.gray, useColor));
    }
    writeln();
}

/// Format a single row in detail view
void formatRowDetail(Row row, Column[] columns, bool useColor)
{
    writeln(colored("Row ID: ", Color.bold, useColor), row.id);
    writeln(colored("Name: ", Color.gray, useColor), row.name);
    writeln(colored("Index: ", Color.gray, useColor), row.index);
    writeln();

    if (columns.length == 0)
    {
        writeln(colored("  (no columns)", Color.gray, useColor));
        return;
    }

    auto maxNameLen = columns.map!(c => c.name.length).maxElement(10);

    foreach (ref col; columns)
    {
        auto val = formatCellValue(row, col.id);
        writefln("  %s: %s",
            colored(leftJustify(col.name, maxNameLen), Color.cyan, useColor),
            val);
    }
    writeln();
}

// =============================================================================
// Cell Value Formatting
// =============================================================================

/// Extract and format cell value from row
string formatCellValue(Row row, string columnId)
{
    if (auto pVal = columnId in row.values)
    {
        return (*pVal).match!(
            (string s) => s,
            (int i) => i.to!string,
            (double d) => formatDouble(d),
            (JSONValue j) => formatJsonValue(j),
            _ => "",  // bool, string[], int[], bool[] - rarely used directly
        );
    }
    return "";
}

/// Format a double value (avoid trailing zeros)
string formatDouble(double d)
{
    import std.format : format;

    if (d == cast(long) d)
        return (cast(long) d).to!string;
    return format("%.2f", d);
}

/// Format a JSON value for display
string formatJsonValue(JSONValue j)
{
    import std.json : JSONType;

    if (j.type == JSONType.null_)
        return "";
    if (j.type == JSONType.string)
        return j.str;
    if (j.type == JSONType.integer)
        return j.integer.to!string;
    if (j.type == JSONType.uinteger)
        return j.uinteger.to!string;
    if (j.type == JSONType.float_)
        return formatDouble(j.floating);
    if (j.type == JSONType.true_)
        return "true";
    if (j.type == JSONType.false_)
        return "false";

    // For arrays and objects, compact representation
    return j.toString(JSONOptions.doNotEscapeSlashes);
}

// =============================================================================
// Help Formatting
// =============================================================================

/// Display help message
void showHelp(bool useColor)
{
    writeln(colored("Available commands:", Color.bold, useColor));
    writeln();
    writeln("  ", colored("tables", Color.cyan, useColor), "                          List all tables in the document");
    writeln("  ", colored("describe", Color.cyan, useColor), " <table>                Show table schema (columns)");
    writeln("  ", colored("select", Color.cyan, useColor), " <table> [limit N]        Show rows from a table");
    writeln("  ", colored("select", Color.cyan, useColor), " <table> where <col>=<val> [limit N]");
    writeln("                                  Filter rows by column value");
    writeln("  ", colored("show", Color.cyan, useColor), " <table> <row-id>           Show detailed view of a single row");
    writeln("  ", colored("count", Color.cyan, useColor), " <table>                   Show row count for a table");
    writeln("  ", colored("help", Color.cyan, useColor), "                            Show this help message");
    writeln("  ", colored("quit", Color.cyan, useColor), "                            Exit the REPL");
    writeln();
    writeln(colored("Aliases:", Color.gray, useColor), " desc, sel/s, q/exit, ls, h/?");
    writeln(colored("Table names are case-insensitive and support partial matching.", Color.gray, useColor));
    writeln();
}
