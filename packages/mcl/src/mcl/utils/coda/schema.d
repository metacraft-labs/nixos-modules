module mcl.utils.coda.schema;

import std.typecons : Nullable;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.datetime : SysTime;

import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.coda.types : RowValues, CodaCell;
import mcl.utils.coda.client : CodaApiClient;

// =============================================================================
// UDA Definitions for Type-Safe Coda Schema Mapping
// =============================================================================

/// Coda column type enumeration
enum CodaType
{
    text,
    number,
    date,
    checkbox,
    reference,
    select,
    currency,
    percent,
}

/// Table schema UDA - maps struct to a Coda table by logical name
struct CodaTable
{
    string tableName;
}

/// Column schema UDA - maps struct field to a Coda column by logical name
struct CodaColumn
{
    string columnName;
    CodaType type = CodaType.text;
}

/// Mark field as key column for upsert operations
struct KeyColumn {}

/// Mark field as read-only (calculated field, not sent on upsert)
struct CodaReadOnly {}

/// Reference to another table by logical name
struct CodaReference
{
    string targetTableName;
}

// =============================================================================
// Runtime Configuration Types
// =============================================================================

/// Runtime ID mapping for a column
struct ColumnIdMapping
{
    string columnName;
    string columnId;
}

/// Runtime ID mapping for a table
struct TableIdMapping
{
    string tableName;
    string tableId;
    ColumnIdMapping[] columns;

    /// Lookup column ID by name
    Nullable!string getColumnId(string colName) const
    {
        foreach (ref col; columns)
            if (col.columnName == colName)
                return Nullable!string(col.columnId);
        return Nullable!string.init;
    }
}

/// Full document configuration
struct CodaDocConfig
{
    string docId;
    string pageId;
    TableIdMapping[] tables;

    /// Lookup table mapping by name (returns copy)
    Nullable!TableIdMapping getTable(string tableName) const
    {
        foreach (t; tables)
            if (t.tableName == tableName)
                return Nullable!TableIdMapping(TableIdMapping(t.tableName, t.tableId, t.columns.dup));
        return Nullable!TableIdMapping.init;
    }

    /// Lookup table ID by name
    Nullable!string getTableId(string tableName) const
    {
        if (auto t = getTable(tableName))
            return Nullable!string(t.get.tableId);
        return Nullable!string.init;
    }

    /// Lookup column ID by table and column name
    Nullable!string getColumnId(string tableName, string columnName) const
    {
        if (auto t = getTable(tableName))
            return t.get.getColumnId(columnName);
        return Nullable!string.init;
    }
}

/// Load configuration from JSON file
CodaDocConfig loadCodaConfig(string configPath)
{
    import std.file : readText;
    return configPath.readText.parseJSON.fromJSON!CodaDocConfig;
}

// =============================================================================
// CodaIdResolver - Runtime ID Resolution with Caching
// =============================================================================

/// Resolver that merges config, runtime overrides, and API introspection
struct CodaIdResolver
{
    CodaApiClient* coda;
    CodaDocConfig config;
    TableIdMapping[string] runtimeOverrides;
    TableIdMapping[string] resolvedCache;

    /// Resolve table ID - tries config, then override, then introspection
    string resolveTableId(string tableName)
    {
        // 1. Check config file
        if (auto id = config.getTableId(tableName))
            return id.get;

        // 2. Check runtime override
        if (auto p = tableName in runtimeOverrides)
            return p.tableId;

        // 3. Check cache
        if (auto p = tableName in resolvedCache)
            return p.tableId;

        // 4. Fallback: API introspection
        auto tables = coda.listTables(config.docId);
        foreach (ref t; tables)
        {
            if (t.name == tableName)
            {
                // Cache the resolved table
                resolvedCache[tableName] = TableIdMapping(
                    tableName: tableName,
                    tableId: t.id,
                );
                return t.id;
            }
        }

        throw new Exception("Cannot resolve table: " ~ tableName);
    }

    /// Resolve column ID - tries config, then override, then introspection
    string resolveColumnId(string tableName, string columnName)
    {
        // 1. Check config file
        if (auto id = config.getColumnId(tableName, columnName))
            return id.get;

        // 2. Check runtime override
        if (auto p = tableName in runtimeOverrides)
            if (auto colId = p.getColumnId(columnName))
                return colId.get;

        // 3. Check cache
        if (auto p = tableName in resolvedCache)
            if (auto colId = p.getColumnId(columnName))
                return colId.get;

        // 4. Fallback: API introspection
        auto tableId = resolveTableId(tableName);
        auto columns = coda.listColumns(config.docId, tableId);
        foreach (ref c; columns)
        {
            if (c.name == columnName)
            {
                // Cache the resolved column
                if (auto p = tableName in resolvedCache)
                    p.columns ~= ColumnIdMapping(columnName: columnName, columnId: c.id);
                else
                    resolvedCache[tableName] = TableIdMapping(
                        tableName: tableName,
                        tableId: tableId,
                        columns: [ColumnIdMapping(columnName: columnName, columnId: c.id)],
                    );
                return c.id;
            }
        }

        throw new Exception("Cannot resolve column: " ~ tableName ~ "." ~ columnName);
    }

    /// Convert resolver state (with cached resolutions) to exportable config
    CodaDocConfig toResolvedConfig()
    {
        CodaDocConfig result;
        result.docId = config.docId;
        result.pageId = config.pageId;

        // Start with original config tables (make copies)
        foreach (t; config.tables)
            result.tables ~= TableIdMapping(t.tableName, t.tableId, t.columns.dup);

        // Merge in resolved cache (avoiding duplicates)
        foreach (tableName, mapping; resolvedCache)
        {
            bool found = false;
            foreach (ref t; result.tables)
            {
                if (t.tableName == tableName)
                {
                    // Merge columns
                    foreach (col; mapping.columns)
                    {
                        bool colFound = false;
                        foreach (c; t.columns)
                            if (c.columnName == col.columnName)
                                colFound = true;
                        if (!colFound)
                            t.columns ~= col;
                    }
                    found = true;
                    break;
                }
            }
            if (!found)
                result.tables ~= mapping;
        }

        return result;
    }
}

/// Introspect entire Coda document and generate full config
CodaDocConfig introspectCodaDocument(CodaApiClient* coda, string docId, string pageId = "")
{
    CodaDocConfig config;
    config.docId = docId;
    config.pageId = pageId;

    auto tables = coda.listTables(docId);
    foreach (ref table; tables)
    {
        // Filter by page if specified
        if (pageId.length > 0 && table.parent.id != pageId)
            continue;

        TableIdMapping tableMapping;
        tableMapping.tableName = table.name;
        tableMapping.tableId = table.id;

        auto columns = coda.listColumns(docId, table.id);
        foreach (ref col; columns)
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

/// Export resolved config to JSON file
void exportCodaConfig(const CodaDocConfig config, string outputPath)
{
    import std.file : write;
    // Note: simplify=false ensures arrays are preserved as arrays even with single elements
    auto json = config.toJSON(false).toPrettyString(JSONOptions.doNotEscapeSlashes);
    write(outputPath, json);
}

// =============================================================================
// Compile-Time Template Functions for Schema Introspection
// =============================================================================

/// Get the table name from a struct type with @CodaTable UDA
template getTableName(T) if (is(T == struct))
{
    import std.traits : hasUDA, getUDAs;

    static if (hasUDA!(T, CodaTable))
        enum getTableName = getUDAs!(T, CodaTable)[0].tableName;
    else
        static assert(0, T.stringof ~ " does not have @CodaTable UDA");
}

/// Get column names marked with @KeyColumn
template getKeyColumnNames(T) if (is(T == struct))
{
    import std.traits : hasUDA, getUDAs;

    enum string[] getKeyColumnNames = () {
        string[] keys;
        static foreach (field; T.tupleof)
        {
            static if (hasUDA!(field, KeyColumn) && hasUDA!(field, CodaColumn))
            {
                keys ~= getUDAs!(field, CodaColumn)[0].columnName;
            }
        }
        return keys;
    }();
}

// =============================================================================
// Runtime Conversion Functions
// =============================================================================

/// Convert D value to Coda-compatible string representation
private string convertToCodaValue(T)(T value, CodaType codaType)
{
    import std.conv : to;
    import std.traits : isNumeric, isFloatingPoint;
    import std.format : format;

    static if (is(T == bool))
        return value ? "true" : "false";
    else static if (isFloatingPoint!T)
        return format!"%.2f"(value);
    else static if (isNumeric!T)
        return value.to!string;
    else static if (is(T == SysTime))
        return value.toISOExtString();
    else static if (is(T == string))
        return value;
    else static if (is(T == enum))
    {
        import mcl.utils.string : enumToString;
        return value.enumToString;
    }
    else
        return value.to!string;
}

/// Convert struct to RowValues using runtime ID resolution
RowValues toRowValues(T)(in T value, ref CodaIdResolver resolver) if (is(T == struct))
{
    import std.traits : hasUDA, getUDAs;

    enum tableName = getTableName!T;
    CodaCell[] cells;

    static foreach (idx, field; T.tupleof)
    {
        static if (hasUDA!(field, CodaColumn) && !hasUDA!(field, CodaReadOnly))
        {{
            enum col = getUDAs!(field, CodaColumn)[0];
            auto columnId = resolver.resolveColumnId(tableName, col.columnName);
            cells ~= CodaCell(columnId, convertToCodaValue(value.tupleof[idx], col.type));
        }}
    }

    return RowValues(cells);
}

/// Get key column IDs at runtime
string[] getKeyColumnIds(T)(ref CodaIdResolver resolver) if (is(T == struct))
{
    import std.traits : hasUDA, getUDAs;

    enum tableName = getTableName!T;
    string[] keys;

    static foreach (field; T.tupleof)
    {
        static if (hasUDA!(field, KeyColumn) && hasUDA!(field, CodaColumn))
        {{
            enum col = getUDAs!(field, CodaColumn)[0];
            keys ~= resolver.resolveColumnId(tableName, col.columnName);
        }}
    }

    return keys;
}

// =============================================================================
// High-Level API Functions
// =============================================================================

/// Type-safe upsert with runtime ID resolution
void upsertCodaRows(T)(CodaApiClient* coda, ref CodaIdResolver resolver, T[] rows)
    if (is(T == struct))
{
    import std.algorithm : map;
    import std.array : array;

    if (rows.length == 0)
        return;

    enum tableName = getTableName!T;
    auto tableId = resolver.resolveTableId(tableName);
    auto keyColumns = getKeyColumnIds!T(resolver);
    auto rowValues = rows.map!(r => r.toRowValues(resolver)).array;

    coda.upsertRows(resolver.config.docId, tableId, rowValues, keyColumns);
}

/// Convenience: create resolver and upsert
void upsertCodaRows(T)(CodaApiClient* coda, CodaDocConfig config, T[] rows)
    if (is(T == struct))
{
    auto resolver = CodaIdResolver(coda, config);
    upsertCodaRows(coda, resolver, rows);
}

/// Type-safe single row upsert
void upsertCodaRow(T)(CodaApiClient* coda, ref CodaIdResolver resolver, T row)
    if (is(T == struct))
{
    upsertCodaRows(coda, resolver, [row]);
}

/// Convenience: create resolver and upsert single row
void upsertCodaRow(T)(CodaApiClient* coda, CodaDocConfig config, T row)
    if (is(T == struct))
{
    auto resolver = CodaIdResolver(coda, config);
    upsertCodaRow(coda, resolver, row);
}

// =============================================================================
// Unit Tests for UDA System
// =============================================================================

@("coda.uda.getTableName")
unittest
{
    @CodaTable("TestTable")
    struct TestRow
    {
        @CodaColumn("Col1")
        string field1;
    }

    static assert(getTableName!TestRow == "TestTable");
}

@("coda.uda.getKeyColumnNames")
unittest
{
    @CodaTable("TestTable")
    struct TestRow
    {
        @CodaColumn("Col1")
        @KeyColumn
        string key1;

        @CodaColumn("Col2")
        string normal;

        @CodaColumn("Col3")
        @KeyColumn
        string key2;
    }

    static assert(getKeyColumnNames!TestRow == ["Col1", "Col3"]);
}

@("coda.config.lookup")
unittest
{
    auto config = CodaDocConfig(
        docId: "test-doc",
        pageId: "test-page",
        tables: [
            TableIdMapping(
                tableName: "Vendors",
                tableId: "grid-123",
                columns: [
                    ColumnIdMapping(columnName: "Name", columnId: "c-abc"),
                    ColumnIdMapping(columnName: "Code", columnId: "c-def"),
                ],
            ),
        ],
    );

    assert(config.getTableId("Vendors").get == "grid-123");
    assert(config.getTableId("NonExistent").isNull);
    assert(config.getColumnId("Vendors", "Name").get == "c-abc");
    assert(config.getColumnId("Vendors", "Code").get == "c-def");
    assert(config.getColumnId("Vendors", "NonExistent").isNull);
}

@("coda.uda.toRowValues.mock")
unittest
{
    // Test toRowValues with a mock resolver that uses config lookup only
    @CodaTable("TestTable")
    struct TestRow
    {
        @CodaColumn("Name")
        string name;

        @CodaColumn("Count", CodaType.number)
        int count;

        @CodaColumn("Active", CodaType.checkbox)
        bool active;

        @CodaReadOnly
        @CodaColumn("Computed")
        string computed;  // Should be excluded
    }

    auto config = CodaDocConfig(
        docId: "test-doc",
        tables: [
            TableIdMapping(
                tableName: "TestTable",
                tableId: "grid-test",
                columns: [
                    ColumnIdMapping(columnName: "Name", columnId: "c-name"),
                    ColumnIdMapping(columnName: "Count", columnId: "c-count"),
                    ColumnIdMapping(columnName: "Active", columnId: "c-active"),
                    ColumnIdMapping(columnName: "Computed", columnId: "c-computed"),
                ],
            ),
        ],
    );

    auto resolver = CodaIdResolver(
        coda: null,  // Not used since config has all IDs
        config: config,
    );

    auto row = TestRow(name: "Test", count: 42, active: true, computed: "ignored");
    auto rowValues = row.toRowValues(resolver);

    assert(rowValues.cells.length == 3);  // Computed is excluded
    assert(rowValues.cells[0].column == "c-name");
    assert(rowValues.cells[0].value == "Test");
    assert(rowValues.cells[1].column == "c-count");
    assert(rowValues.cells[1].value == "42");
    assert(rowValues.cells[2].column == "c-active");
    assert(rowValues.cells[2].value == "true");
}

@("coda.uda.getKeyColumnIds.mock")
unittest
{
    @CodaTable("TestTable")
    struct TestRow
    {
        @CodaColumn("Key1")
        @KeyColumn
        string key1;

        @CodaColumn("Normal")
        string normal;

        @CodaColumn("Key2")
        @KeyColumn
        string key2;
    }

    auto config = CodaDocConfig(
        docId: "test-doc",
        tables: [
            TableIdMapping(
                tableName: "TestTable",
                tableId: "grid-test",
                columns: [
                    ColumnIdMapping(columnName: "Key1", columnId: "c-k1"),
                    ColumnIdMapping(columnName: "Normal", columnId: "c-n"),
                    ColumnIdMapping(columnName: "Key2", columnId: "c-k2"),
                ],
            ),
        ],
    );

    auto resolver = CodaIdResolver(
        coda: null,
        config: config,
    );

    auto keyIds = getKeyColumnIds!TestRow(resolver);
    assert(keyIds == ["c-k1", "c-k2"]);
}
