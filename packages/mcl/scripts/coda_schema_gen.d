#!/usr/bin/env dub
/+ dub.sdl:
    name "coda_schema_gen"
    dependency "mcl" path=".."
+/

/// Generates a CodaDocConfig JSON and/or D structs from a Coda document
/// by introspecting its tables and columns via the API.
///
/// Environment:
///   CODA_API_TOKEN - Required API token for Coda authentication
///
/// Example:
///   export CODA_API_TOKEN=your_token_here
///   ./coda_schema_gen.d abcDEF123 > my_doc_config.json
///   ./coda_schema_gen.d --d-file schema.d --module myapp.coda_schema abcDEF123

import std.stdio : writeln, stderr, File;
import std.process : environment;
import std.json : JSONOptions;
import std.array : array, join, replace;
import std.algorithm : map, filter;
import std.string : toLower, capitalize;
import std.uni : isAlphaNum;
import std.conv : to;

import argparse : NamedArgument, PositionalArgument, Placeholder, Command, Description, CLI;

import mcl.utils.json : toJSON;
import mcl.utils.coda : CodaApiClient, CodaDocConfig, CodaType, Column, Table;

@(Command("coda_schema_gen")
    .Description(
        "Generates CodaDocConfig JSON and/or D structs from a Coda document " ~
        "by introspecting its tables and columns via the API.\n\n" ~
        "Environment:\n" ~
        "  CODA_API_TOKEN - Required API token for authentication\n\n" ~
        "Examples:\n" ~
        "  ./coda_schema_gen.d abcDEF123 > config.json\n" ~
        "  ./coda_schema_gen.d --d-file schema.d abcDEF123\n" ~
        "  ./coda_schema_gen.d --d-file schema.d --json abcDEF123 > config.json"
    ))
struct Args
{
    @(PositionalArgument(0).Placeholder("docId").Description("The Coda document ID (from the URL)"))
    string docId;

    @(NamedArgument(["page"]).Placeholder("pageId").Description("Filter tables to a specific page"))
    string page;

    @(NamedArgument(["d-file"]).Placeholder("path").Description("Generate D source file with struct definitions"))
    string dFile;

    @(NamedArgument(["module"]).Placeholder("name").Description("Module name for generated D file"))
    string moduleName = "coda_schema";

    @(NamedArgument(["json"]).Description("Output JSON config to stdout (default if no --d-file)"))
    bool json;
}

mixin CLI!Args.main!(run);

int run(Args args)
{
    // Default to JSON output if no D file specified
    bool outputJson = args.json || args.dFile.length == 0;

    auto apiToken = environment.get("CODA_API_TOKEN");
    if (apiToken.length == 0)
    {
        stderr.writeln("Error: CODA_API_TOKEN environment variable is not set");
        return 1;
    }

    auto coda = CodaApiClient(apiToken);

    // Fetch tables and columns with full metadata
    auto tables = coda.listTables(args.docId);
    if (args.page.length > 0)
        tables = tables.filter!(t => t.parent.id == args.page).array;

    Column[][string] tableColumns;
    foreach (ref table; tables)
        tableColumns[table.id] = coda.listColumns(args.docId, table.id);

    // Build config
    auto config = buildConfig(args.docId, args.page, tables, tableColumns);

    if (outputJson)
    {
        config
            .toJSON(false)
            .toPrettyString(JSONOptions.doNotEscapeSlashes)
            .writeln();
    }

    if (args.dFile.length > 0)
    {
        auto regenerateCmd = buildRegenerateCommand(args);
        auto dCode = generateDCode(args.moduleName, tables, tableColumns, regenerateCmd);
        auto file = File(args.dFile, "w");
        file.write(dCode);
        file.close();
        stderr.writeln("Generated D file: ", args.dFile);
    }

    return 0;
}

CodaDocConfig buildConfig(string docId, string pageId, Table[] tables, Column[][string] tableColumns)
{
    import mcl.utils.coda.schema : CodaDocConfig, TableIdMapping, ColumnIdMapping;

    CodaDocConfig config;
    config.docId = docId;
    config.pageId = pageId;

    foreach (ref table; tables)
    {
        TableIdMapping tableMapping;
        tableMapping.tableName = table.name;
        tableMapping.tableId = table.id;

        foreach (ref col; tableColumns[table.id])
        {
            tableMapping.columns ~= ColumnIdMapping(
                columnName: col.name,
                columnId: col.id,
            );
        }

        config.tables ~= tableMapping;
    }

    return config;
}

/// Build the command string to regenerate this file
string buildRegenerateCommand(Args args)
{
    string cmd = "./coda_schema_gen.d";

    if (args.dFile.length > 0)
        cmd ~= " --d-file " ~ args.dFile;

    if (args.moduleName != "coda_schema")
        cmd ~= " --module " ~ args.moduleName;

    if (args.page.length > 0)
        cmd ~= " --page " ~ args.page;

    cmd ~= " " ~ args.docId;

    return cmd;
}

string generateDCode(string moduleName, Table[] tables, Column[][string] tableColumns, string regenerateCmd)
{
    string code;

    // Auto-generated file header
    code ~= "// DO NOT EDIT - This file is auto-generated\n";
    code ~= "// Regenerate with: " ~ regenerateCmd ~ "\n\n";

    // Build table name -> struct name mapping for typed references
    string[string] tableToStruct;
    foreach (ref table; tables)
        tableToStruct[table.name] = toStructName(table.name);

    // Module declaration
    code ~= "module " ~ moduleName ~ ";\n\n";

    // Imports - include Ref for typed references
    code ~= "import mcl.utils.coda.schema : CodaTable, CodaColumn, CodaType, KeyColumn, CodaReadOnly, Ref;\n\n";

    // Generate struct for each table
    foreach (ref table; tables)
    {
        auto structName = toStructName(table.name);
        auto columns = tableColumns[table.id];

        code ~= "@CodaTable(\"" ~ escapeString(table.name) ~ "\")\n";
        code ~= "struct " ~ structName ~ "\n";
        code ~= "{\n";

        foreach (ref col; columns)
        {
            auto fieldName = toFieldName(col.name);
            auto codaType = mapCodaType(col.format.type);
            string dType;

            // For reference columns, try to use typed Ref!T
            if ((col.format.type == "lookup" || col.format.type == "relation") &&
                !col.format.table.isNull)
            {
                auto targetTableName = col.format.table.get.name;
                if (auto targetStruct = targetTableName in tableToStruct)
                    dType = col.format.isArray ? "Ref!" ~ *targetStruct ~ "[]" : "Ref!" ~ *targetStruct;
                else
                    dType = mapDType(col.format.type, col.format.isArray);  // Fall back to string
            }
            else
            {
                dType = mapDType(col.format.type, col.format.isArray);
            }

            // Add @CodaReadOnly for calculated columns
            if (col.calculated)
                code ~= "    @CodaReadOnly\n";

            // Add @CodaColumn UDA
            if (codaType != "CodaType.text")
                code ~= "    @CodaColumn(\"" ~ escapeString(col.name) ~ "\", " ~ codaType ~ ")\n";
            else
                code ~= "    @CodaColumn(\"" ~ escapeString(col.name) ~ "\")\n";

            // Field declaration
            code ~= "    " ~ dType ~ " " ~ fieldName ~ ";\n\n";
        }

        code ~= "}\n\n";
    }

    return code;
}

/// Convert table name to D struct name (PascalCase, alphanumeric only)
string toStructName(string name)
{
    string result;
    bool capitalizeNext = true;

    foreach (c; name)
    {
        if (c.isAlphaNum)
        {
            result ~= capitalizeNext ? c.to!string.capitalize[0] : c;
            capitalizeNext = false;
        }
        else
            capitalizeNext = true;
    }

    // Ensure starts with letter
    if (result.length > 0 && !result[0].isAlphaNum)
        result = "Table" ~ result;

    return result.length > 0 ? result : "UnnamedTable";
}

/// Convert column name to D field name (camelCase, alphanumeric only)
string toFieldName(string name)
{
    string result;
    bool capitalizeNext = false;

    foreach (i, c; name)
    {
        if (c.isAlphaNum)
        {
            if (i == 0)
                result ~= c.to!string.toLower;
            else
                result ~= capitalizeNext ? c.to!string.capitalize[0] : c;
            capitalizeNext = false;
        }
        else
            capitalizeNext = true;
    }

    // Handle D keywords
    if (isKeyword(result))
        result ~= "_";

    return result.length > 0 ? result : "field";
}

/// Map Coda format type to CodaType enum string
string mapCodaType(string formatType)
{
    switch (formatType)
    {
        case "text", "richText", "email", "link", "phone":
            return "CodaType.text";
        case "number", "slider", "scale", "duration":
            return "CodaType.number";
        case "date", "dateTime", "time":
            return "CodaType.date";
        case "checkbox", "toggle":
            return "CodaType.checkbox";
        case "lookup", "relation":
            return "CodaType.reference";
        case "select", "selectList", "multiselect":
            return "CodaType.select";
        case "currency":
            return "CodaType.currency";
        case "percent":
            return "CodaType.percent";
        default:
            return "CodaType.text";
    }
}

/// Map Coda format type to D type
string mapDType(string formatType, bool isArray)
{
    string baseType;

    switch (formatType)
    {
        case "text", "richText", "email", "link", "phone", "select", "selectList":
            baseType = "string";
            break;
        case "number", "slider", "scale", "currency", "percent", "duration":
            baseType = "double";
            break;
        case "date", "dateTime", "time":
            baseType = "string";  // ISO date string
            break;
        case "checkbox", "toggle":
            baseType = "bool";
            break;
        case "lookup", "relation", "multiselect":
            baseType = "string";  // Reference ID or display value
            break;
        default:
            baseType = "string";
    }

    return isArray ? baseType ~ "[]" : baseType;
}

/// Escape string for D string literal
string escapeString(string s)
{
    return s.replace("\\", "\\\\").replace("\"", "\\\"");
}

/// Check if identifier is a D keyword
bool isKeyword(string s)
{
    static immutable keywords = [
        "abstract", "alias", "align", "asm", "assert", "auto",
        "body", "bool", "break", "byte",
        "case", "cast", "catch", "cdouble", "cent", "cfloat", "char", "class", "const", "continue", "creal",
        "dchar", "debug", "default", "delegate", "delete", "deprecated", "do", "double",
        "else", "enum", "export", "extern",
        "false", "final", "finally", "float", "for", "foreach", "foreach_reverse", "function",
        "goto",
        "idouble", "if", "ifloat", "immutable", "import", "in", "inout", "int", "interface", "invariant", "ireal", "is",
        "lazy", "long",
        "macro", "mixin", "module",
        "new", "nothrow", "null",
        "out", "override",
        "package", "pragma", "private", "protected", "public", "pure",
        "real", "ref", "return",
        "scope", "shared", "short", "static", "struct", "super", "switch", "synchronized",
        "template", "this", "throw", "true", "try", "typedef", "typeid", "typeof",
        "ubyte", "ucent", "uint", "ulong", "union", "unittest", "ushort",
        "version", "void", "volatile",
        "wchar", "while", "with",
        "__FILE__", "__LINE__", "__gshared", "__traits", "__vector", "__parameters",
    ];

    foreach (kw; keywords)
        if (s == kw)
            return true;
    return false;
}
