module mcl.commands.invoices.coda;

import std.algorithm : filter, map, sort, uniq;
import std.array : array, assocArray;
import std.format : format;
import std.process : environment;
import std.stdio : writeln, writefln;
import std.traits : EnumMembers;
import std.typecons : tuple;

import mcl.utils.coda : CodaApiClient, RowValues, CodaCell;
import mcl.utils.string : enumToString;

import mcl.commands.invoices.types : InvoiceItem, Product, ProductCategory, loadInvoiceItems;

// =============================================================================
// Table/Column Information Structures
// =============================================================================

/// Column metadata for display
struct ColumnInfo
{
    string id;
    string name;
    string type;
    bool calculated;
}

/// Table metadata with columns
struct TableInfo
{
    string id;
    string name;
    string tableType;
    string parentPageId;
    int rowCount;
    ColumnInfo[] columns;
}

// =============================================================================
// Coda Data Access Functions
// =============================================================================

/// Get a configured Coda API client
/// Requires CODA_API_TOKEN environment variable
CodaApiClient getCodaClient()
{
    auto apiToken = environment.get("CODA_API_TOKEN");
    if (apiToken is null || apiToken.length == 0)
    {
        throw new Exception("CODA_API_TOKEN environment variable is not set");
    }
    return CodaApiClient(apiToken);
}

/// List all tables and their columns for a Coda document
/// Optionally filter by pageId to only include tables on a specific page
TableInfo[] listTablesAndColumns(string docId, string pageId = null)
{
    auto coda = getCodaClient();

    auto tables = coda.listTables(docId);

    auto filteredTables = (pageId is null)
        ? tables
        : tables.filter!(t => t.parent.id == pageId).array;

    return filteredTables
        .map!(table => TableInfo(
            table.id,
            table.name,
            table.tableType,
            table.parent.id,
            table.rowCount,
            coda.listColumns(docId, table.id)
                .map!(col => ColumnInfo(
                    col.id,
                    col.name,
                    col.format.type,
                    col.calculated
                ))
                .array
        ))
        .array;
}

/// Print tables and columns in a human-readable format
/// Optionally filter by pageId to only include tables on a specific page
void printTablesAndColumns(string docId, string pageId = null)
{
    auto tables = listTablesAndColumns(docId, pageId);

    writefln("Document: %s", docId);
    if (pageId !is null)
        writefln("Page: %s", pageId);
    writefln("Found %d tables:\n", tables.length);

    foreach (table; tables)
    {
        writefln("Table: %s", table.name);
        writefln("  ID: %s", table.id);
        writefln("  Type: %s", table.tableType);
        writefln("  Rows: %d", table.rowCount);
        writefln("  Columns (%d):", table.columns.length);

        foreach (col; table.columns)
        {
            writefln("    - %s (id: %s, type: %s%s)",
                col.name,
                col.id,
                col.type,
                col.calculated ? ", calculated" : ""
            );
        }
        writeln();
    }
}

// =============================================================================
// Coda Table IDs (for page canvas-OJyzDZriCI in doc SIcXMyTJrL)
// =============================================================================

enum CodaTables : string
{
    Vendors = "grid-nOU9LzQh-Z",
    InventoryType = "grid-EYAqUcRk1u",
    ProductModels = "grid-yHjbFapp9X",
    Invoices = "grid-CN_3ijlwM0",
    InvoiceLines = "grid-oBc6KpUhq9",
}

// =============================================================================
// Coda Import Functions
// =============================================================================

/// Import unique vendors into Coda Vendors table
void importVendors(CodaApiClient coda, string docId, string[] vendors)
{
    writefln("Importing %d vendors...", vendors.length);

    auto rows = vendors
        .filter!(v => v.length > 0)
        .map!(vendor => RowValues([
            CodaCell("c-39ewHiT_ld", vendor),  // VendorName
        ]))
        .array;

    if (rows.length > 0)
        coda.upsertRows(docId, CodaTables.Vendors, rows, ["c-39ewHiT_ld"]);

    writefln("  Done: %d vendors imported", rows.length);
}

/// Import ProductCategory enum values into Coda InventoryType table
void importInventoryTypes(CodaApiClient coda, string docId)
{
    writeln("Importing inventory types (ProductCategory enum)...");

    RowValues[] rows;
    static foreach (cat; EnumMembers!ProductCategory)
    {
        rows ~= RowValues([
            CodaCell("c-Z6MT4koi1z", cat.enumToString),  // Type
        ]);
    }

    coda.upsertRows(docId, CodaTables.InventoryType, rows, ["c-Z6MT4koi1z"]);

    writefln("  Done: %d inventory types imported", rows.length);
}

/// Import unique products into Coda ProductModels table
void importProductModels(CodaApiClient coda, string docId, Product[] products)
{
    writefln("Importing %d product models...", products.length);

    auto rows = products
        .map!(p => RowValues([
            CodaCell("c-XVY32R_aKd", p.category.enumToString),  // Category (lookup)
            CodaCell("c-ZGEJEkS7MZ", p.vendor),                  // Vendor (lookup)
            CodaCell("c-U0ys8WDDOE", p.model),                   // Model
            CodaCell("c-cwfdlRm8F2", ""),                        // SKU (empty for now)
            CodaCell("c-kMA1lR7L78", p.sn),                      // sn
        ]))
        .array;

    if (rows.length > 0)
        coda.upsertRows(docId, CodaTables.ProductModels, rows, ["c-XVY32R_aKd", "c-ZGEJEkS7MZ", "c-U0ys8WDDOE"]);

    writefln("  Done: %d product models imported", rows.length);
}

/// Import invoices (one per CSV file) into Coda Invoices table
void importInvoices(CodaApiClient coda, string docId, InvoiceItem[] items)
{
    // Group by file to get one invoice per CSV
    InvoiceItem[][string] byFile;
    foreach (ref item; items)
    {
        byFile[item.file] ~= item;
    }

    writefln("Importing %d invoices...", byFile.length);

    auto rows = byFile.byKeyValue
        .map!((kv) {
            auto file = kv.key;
            auto fileItems = kv.value;
            auto first = fileItems[0];

            // Extract invoice number from filename (e.g., "2023-01-03 2344304.csv" -> "2344304")
            import std.string : indexOf;
            import std.path : baseName, stripExtension;
            auto base = file.baseName.stripExtension;
            auto spaceIdx = base.indexOf(" ");
            auto invoiceNo = spaceIdx > 0 ? base[spaceIdx + 1 .. $] : first.purchasedbid;

            // Calculate total
            double total = 0;
            foreach (ref fi; fileItems)
                total += fi.invoicePriceWithVat;

            return RowValues([
                CodaCell("c-5wjpbddEh0", invoiceNo),                    // InvoiceNo
                CodaCell("c-7NF7hrw7Sf", ""),                           // Vendor (TODO: extract)
                CodaCell("c-P2BmCrYxgQ", first.date[0 .. 10]),          // InvoiceDate
                CodaCell("c-iP7seJ0ZZW", "BGN"),                        // Currency
                CodaCell("c-VzN7ZOk89b", format!"%.2f"(total)),         // InvoiceTotal
                CodaCell("c-jClcbXrU-o", file),                         // File
            ]);
        })
        .array;

    if (rows.length > 0)
        coda.upsertRows(docId, CodaTables.Invoices, rows, ["c-5wjpbddEh0"]);

    writefln("  Done: %d invoices imported", rows.length);
}

/// Import invoice line items into Coda InvoiceLines table
void importInvoiceLines(CodaApiClient coda, string docId, InvoiceItem[] items)
{
    writefln("Importing %d invoice lines...", items.length);

    auto rows = items
        .map!(item => RowValues([
            CodaCell("c-xd7ygn_T3R", item.file),                       // Invoice (file ref)
            CodaCell("c-0HyoCbQLw5", item.descr),                      // Description
            CodaCell("c-iDNvgazJxl", item.productid),                  // SKU
            CodaCell("c-G0Ff_DAcGe", item.manifacturer),               // Manufacturer
            CodaCell("c-VZQDalMP51", item.model),                      // Model
            CodaCell("c-HdPEMJRLi1", "1"),                             // Qty (default 1)
            CodaCell("c-qxeCYEkBdl", item.price),                      // UnitNet
            CodaCell("c--cimjEFpUc", item.total_lvn),                  // UnitGross
            CodaCell("c-fYl6j-aAEa", item.price),                      // LineNet
            CodaCell("c-WFNq7mCBUm", item.total_lvn),                  // LineGross
        ]))
        .array;

    if (rows.length > 0)
        coda.upsertRows(docId, CodaTables.InvoiceLines, rows, ["c-xd7ygn_T3R", "c-iDNvgazJxl"]);

    writefln("  Done: %d invoice lines imported", rows.length);
}

/// Import all invoice data to Coda
void importAllInvoiceData(string docId, string invoicesDir)
{
    import mcl.commands.invoices.list : groupInvoiceItemsByProduct;

    writefln("=== Importing invoice data from %s ===\n", invoicesDir);

    auto coda = getCodaClient();

    // Load invoice items
    writeln("Loading invoice items...");
    auto items = loadInvoiceItems(invoicesDir);
    writefln("  Loaded %d items\n", items.length);

    // Extract unique products (across all categories)
    Product[] products;
    static foreach (cat; EnumMembers!ProductCategory)
    {
        {
            auto categoryProducts = groupInvoiceItemsByProduct(items, cat);
            foreach (ref po; categoryProducts)
                products ~= po.product;
        }
    }

    // Extract unique vendors from products
    auto vendors = products
        .map!(p => p.vendor)
        .array
        .sort
        .uniq
        .array;

    // Import in dependency order
    importInventoryTypes(coda, docId);
    importVendors(coda, docId, vendors);
    importProductModels(coda, docId, products);
    importInvoices(coda, docId, items);
    importInvoiceLines(coda, docId, items);

    writeln("\n=== Import complete ===");
}
