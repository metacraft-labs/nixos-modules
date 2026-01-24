module mcl.commands.match_invoices;

import std.stdio : writeln, File;
import std.conv : to;
import std.string : strip, toUpper, toLower, startsWith, endsWith, split, indexOf;
import std.array : array, replace;
import std.algorithm : map, filter, canFind, min, joiner, sort;
import std.file : exists, dirEntries, SpanMode, readText;
import std.path : baseName;
import std.json : JSONOptions, parseJSON, JSONValue, JSONType;
import std.typecons : Nullable, nullable;
import std.csv : csvReader, Malformed;
import std.exception : ifThrown;

import argparse : Command, Description, NamedArgument, Placeholder, Required;

import mcl.utils.json : toJSON, fromJSON;
import mcl.commands.host_info : Part, HostParts;
import mcl.commands.invoice_heuristics;

// =============================================================================
// Command Args
// =============================================================================

@(Command("match-invoices")
    .Description("Match hardware parts to purchase invoices"))
struct MatchInvoicesArgs
{
    @(NamedArgument(["aggregate"])
        .Placeholder("FILE")
        .Description("Primary aggregate CSV file from JAR (spravkaZahariKaradjov.csv)"))
    string aggregateFile;

    @(NamedArgument(["invoices"])
        .Placeholder("DIR")
        .Description("Directory containing individual invoice CSV files"))
    string invoicesDir;

    @(NamedArgument(["host-info-dir"])
        .Placeholder("DIR")
        .Description("Directory containing host-info JSON files")
        .Required())
    string hostInfoDir;

    @(NamedArgument(["manual-matches"])
        .Placeholder("FILE")
        .Description("CSV file with manual match overrides"))
    string manualMatchesFile;

    @(NamedArgument(["export-unmatched"])
        .Placeholder("FILE")
        .Description("Export unmatched items to CSV for manual review"))
    string exportUnmatchedFile;
}

// =============================================================================
// Invoice Data Structures
// =============================================================================

// CSV record structure matching the individual invoice file columns
struct CsvRecord
{
    string purchasedbid;
    string clientdbid;
    string date;
    string name;
    string mark;
    string model;
    string sn;
    string price;
    string vat;
    string lastchange;
    string modul;
    string manifacturer;
    string productid;
    string descr;
    string waranty;
    string total_lvn;
    string endprice;
    string manufacturer_code;
    string descr48;
}

// CSV record structure matching the aggregate JAR file (spravkaZahariKaradjov.csv)
// Columns: Продажба ID,Дата,Продукт,code,Брой,Единична цена с ДДС,Общо с ДДС,
//          Номер документ,Фактурна дата,Адрес за доставка,Товарителница,SN,Забележка
struct AggregateRecord
{
    string saleId;        // Продажба ID
    string date;          // Дата (YYYY.MM.DD)
    string product;       // Продукт (full Bulgarian description)
    string code;          // Product code with category prefix
    string quantity;      // Брой
    string unitPrice;     // Единична цена с ДДС
    string totalPrice;    // Общо с ДДС
    string docNumber;     // Номер документ
    string invoiceDate;   // Фактурна дата
    string deliveryAddr;  // Адрес за доставка
    string trackingNum;   // Товарителница
    string sn;            // SN (comma-separated for bulk purchases)
    string notes;         // Забележка
}

// Normalized invoice from aggregate file with category extracted from code prefix
struct AggregateInvoice
{
    string source = "aggregate";  // Source identifier
    string saleId;                // Sale/Invoice ID
    string date;                  // Purchase date
    string category;              // Normalized category from code prefix
    string code;                  // Original product code
    string product;               // Full product description
    string sn;                    // Serial number (single, expanded from comma-separated)
    string price;                 // Unit price with VAT
    int quantity;                 // Quantity purchased

    this(AggregateRecord r, string expandedSn)
    {
        this.saleId = r.saleId;
        this.date = r.date;
        this.code = r.code;
        this.category = categoryFromCode(r.code);
        this.product = r.product;
        this.sn = expandedSn;
        this.price = r.unitPrice;
        this.quantity = r.quantity.to!int.ifThrown(1);
    }
}

// Manual match record from manual-matches.csv
struct ManualMatchRecord
{
    string invoiceId;
    string invoiceSn;
    string invoiceDate;
    string category;
    string brand;
    string model;
    string matchType;  // serial, model, manual, standalone, ignored
    string hostname;
    string notes;
}

struct Invoice
{
    string file;           // Source CSV filename (added after parsing)
    string purchasedbid;   // Invoice ID
    string date;           // Purchase date
    string name;           // Category (CPU, MB, RAM, SSD, etc.)
    string mark;           // Manufacturer/brand
    string model;          // Product model
    string sn;             // Serial number
    string price;          // Price
    string descr;          // Description

    this(string file, CsvRecord r)
    {
        this.file = file;
        this.purchasedbid = r.purchasedbid;
        this.date = r.date;
        this.name = r.name;
        this.mark = r.mark;
        this.model = r.model;
        this.sn = r.sn;
        this.price = r.price;
        this.descr = r.descr;
    }
}

struct PartMatch
{
    Part part;
    Nullable!InvoiceInfo invoice;
    string confidence;     // "high", "medium", "low", or ""
    string matchType;      // "serial", "model", "model+brand", or ""
}

struct InvoiceInfo
{
    string file;
    string purchasedbid;
    string date;
    string price;
    string descr;
}

struct HostMatchResult
{
    string hostname;
    PartMatch[] matches;
}

struct CategoryStats
{
    string category;
    int total;
    int matched;
    int unmatched;
}

struct InvoiceStats
{
    int totalEntries;           // Total lines in aggregate file
    int totalExpanded;          // After expanding comma-separated SNs
    int totalMatched;           // Matched to hosts
    int totalUnmatched;         // Not matched
    CategoryStats[] byCategory; // Breakdown by category
}

struct MatchOutput
{
    HostMatchResult[] hosts;
    Invoice[] unmatchedInvoices;
    AggregateInvoice[] unmatchedAggregateInvoices;
    ManualMatchRecord[] standaloneItems;
    ManualMatchRecord[] ignoredItems;
    InvoiceStats aggregateStats; // Invoice-side statistics
}



// Compute statistics for aggregate invoices (all categories)
InvoiceStats computeAggregateStats(AggregateInvoice[] invoices, bool[] matched)
{
    InvoiceStats stats;
    stats.totalExpanded = cast(int) invoices.length;

    // Count matched/unmatched
    foreach (i, inv; invoices)
    {
        if (matched[i])
            stats.totalMatched++;
        else
            stats.totalUnmatched++;
    }

    // Group by category
    int[string] categoryTotal;
    int[string] categoryMatched;

    foreach (i, inv; invoices)
    {
        auto cat = inv.category.length > 0 ? inv.category : "(no category)";
        categoryTotal[cat] = categoryTotal.get(cat, 0) + 1;
        if (matched[i])
            categoryMatched[cat] = categoryMatched.get(cat, 0) + 1;
    }

    // Build category stats array sorted by total count descending
    foreach (cat, total; categoryTotal)
    {
        auto matchedCount = categoryMatched.get(cat, 0);
        stats.byCategory ~= CategoryStats(
            cat,
            total,
            matchedCount,
            total - matchedCount
        );
    }

    // Sort by total descending
    import std.algorithm : sort;
    stats.byCategory.sort!((a, b) => a.total > b.total);

    return stats;
}

// =============================================================================
// Command Handler
// =============================================================================

int matchInvoices(MatchInvoicesArgs args)
{
    // Load invoices from aggregate file (primary) and/or individual files (secondary)
    auto aggregateInvoices = args.aggregateFile.length > 0
        ? loadAggregateInvoices(args.aggregateFile)
        : [];
    auto individualInvoices = args.invoicesDir.length > 0
        ? loadInvoices(args.invoicesDir)
        : [];

    auto allHostParts = loadHostParts(args.hostInfoDir);
    auto manualMatches = args.manualMatchesFile.length > 0
        ? loadManualMatches(args.manualMatchesFile)
        : [];

    // Track which invoices get matched globally
    bool[] invoiceMatched = new bool[individualInvoices.length];
    bool[] aggregateMatched = new bool[aggregateInvoices.length];

    // Build host results map for manual match injection
    HostMatchResult[string] hostResults;
    foreach (parts; allHostParts)
        hostResults[parts.hostname] = HostMatchResult(parts.hostname, []);

    MatchOutput output;

    // Apply manual matches first (they take precedence)
    foreach (manual; manualMatches)
    {
        // Mark matching invoices as matched
        markInvoiceMatched(manual, aggregateInvoices, individualInvoices,
                          aggregateMatched, invoiceMatched);

        // Route by match type
        if (manual.matchType == "standalone")
        {
            output.standaloneItems ~= manual;
        }
        else if (manual.matchType == "ignored")
        {
            output.ignoredItems ~= manual;
        }
        else if (manual.hostname.length > 0 && manual.hostname in hostResults)
        {
            // Add as matched part to the host
            hostResults[manual.hostname].matches ~= PartMatch(
                Part(manual.category, manual.brand, manual.model, manual.invoiceSn),
                InvoiceInfo(
                    "manual",
                    manual.invoiceId,
                    manual.invoiceDate,
                    "",
                    manual.notes
                ).nullable,
                "high",
                "manual"
            );
        }
    }

    // Auto-match remaining parts
    foreach (parts; allHostParts)
    {
        auto autoMatches = matchPartsToInvoices(parts, individualInvoices, aggregateInvoices,
                                                invoiceMatched, aggregateMatched);
        hostResults[parts.hostname].matches ~= autoMatches.matches;
    }

    output.hosts = hostResults.values.array;

    // Collect unmatched invoices (only hardware-related)
    foreach (i, inv; individualInvoices)
    {
        if (!invoiceMatched[i] && isHardwareInvoice(inv))
            output.unmatchedInvoices ~= inv;
    }

    // Collect unmatched aggregate invoices (only auto-matchable categories)
    foreach (i, agg; aggregateInvoices)
    {
        if (!aggregateMatched[i] && isAutoMatchCategory(agg.category))
            output.unmatchedAggregateInvoices ~= agg;
    }

    // Compute invoice-side statistics for all aggregate invoices
    output.aggregateStats = computeAggregateStats(aggregateInvoices, aggregateMatched);

    // Export unmatched items to CSV if requested
    if (args.exportUnmatchedFile.length > 0)
        exportUnmatchedToCsv(args.exportUnmatchedFile, output);

    output
        .toJSON(true)
        .toPrettyString(JSONOptions.doNotEscapeSlashes)
        .writeln();

    return 0;
}

// Mark invoice as matched based on manual match record
void markInvoiceMatched(ManualMatchRecord manual,
                        AggregateInvoice[] aggregateInvoices, Invoice[] individualInvoices,
                        ref bool[] aggregateMatched, ref bool[] invoiceMatched)
{
    // Try to find in aggregate invoices first
    foreach (i, agg; aggregateInvoices)
    {
        if (!aggregateMatched[i] &&
            (agg.saleId == manual.invoiceId || serialsMatch(agg.sn, manual.invoiceSn)))
        {
            aggregateMatched[i] = true;
            return;
        }
    }

    // Try individual invoices
    foreach (i, inv; individualInvoices)
    {
        if (!invoiceMatched[i] &&
            (inv.purchasedbid == manual.invoiceId || serialsMatch(inv.sn, manual.invoiceSn)))
        {
            invoiceMatched[i] = true;
            return;
        }
    }
}

// Load host parts from JSON files with nested "output" structure
HostParts[] loadHostParts(string hostInfoDir)
{
    if (!exists(hostInfoDir))
        return [];

    return dirEntries(hostInfoDir, "*.json", SpanMode.shallow)
        .map!(entry => parseHostInfoJson(readText(entry.name)))
        .filter!(p => p.hostname.length > 0)
        .array;
}

// Parse host-info JSON which has nested structure: { output: { hostname, parts } }
HostParts parseHostInfoJson(string jsonText)
{
    try
    {
        auto json = parseJSON(jsonText);

        // Handle nested "output" structure
        if ("output" in json && json["output"].type == JSONType.object)
        {
            auto output = json["output"];
            HostParts result;

            if ("hostname" in output)
                result.hostname = output["hostname"].str;

            if ("parts" in output && output["parts"].type == JSONType.array)
            {
                foreach (partJson; output["parts"].array)
                {
                    Part part;
                    if ("name" in partJson) part.name = partJson["name"].str;
                    if ("mark" in partJson) part.mark = partJson["mark"].str;
                    if ("model" in partJson) part.model = partJson["model"].str;
                    if ("sn" in partJson) part.sn = partJson["sn"].str;
                    result.parts ~= part;
                }
            }

            return result;
        }

        // Fallback: try direct structure
        return jsonText.parseJSON.fromJSON!HostParts;
    }
    catch (Exception)
    {
        return HostParts.init;
    }
}

// Load manual matches from CSV file
ManualMatchRecord[] loadManualMatches(string filepath)
{
    if (!exists(filepath))
        return [];

    return ifThrown(
        readText(filepath)
            .split("\n")
            .filter!(line => line.length > 0 && !line.startsWith("#"))
            .map!(line => parseManualMatchLine(line))
            .filter!(r => r.invoiceId.length > 0)
            .array,
        cast(ManualMatchRecord[]) []
    );
}

ManualMatchRecord parseManualMatchLine(string line)
{
    auto fields = line.split(",");
    if (fields.length < 9)
        return ManualMatchRecord.init;

    return ManualMatchRecord(
        fields[0].strip,  // invoiceId
        fields[1].strip,  // invoiceSn
        fields[2].strip,  // invoiceDate
        fields[3].strip,  // category
        fields[4].strip,  // brand
        fields[5].strip,  // model
        fields[6].strip,  // matchType
        fields[7].strip,  // hostname
        fields[8].strip   // notes
    );
}

// =============================================================================
// Invoice Loading
// =============================================================================

Invoice[] loadInvoices(string invoicesDir)
{
    return exists(invoicesDir)
        ? dirEntries(invoicesDir, "*.csv", SpanMode.shallow)
            .map!(entry => parseInvoiceCsv(entry.name))
            .joiner
            .array
        : [];
}

Invoice[] parseInvoiceCsv(string filepath)
{
    auto filename = baseName(filepath);
    return ifThrown(
        readText(filepath)
            .csvReader!(CsvRecord, Malformed.ignore)(null)
            .map!(record => Invoice(filename, record))
            .array,
        cast(Invoice[]) []
    );
}

// =============================================================================
// Aggregate Invoice Loading
// =============================================================================

AggregateInvoice[] loadAggregateInvoices(string filepath)
{
    if (!exists(filepath))
        return [];

    AggregateInvoice[] result;

    try
    {
        auto content = readText(filepath);
        auto records = content.csvReader!(AggregateRecord, Malformed.ignore)(null);

        foreach (record; records)
        {
            // Expand comma-separated serial numbers into individual invoices
            auto sns = expandSerialNumbers(record.sn);

            if (sns.length == 0)
            {
                // No SN - create single invoice entry
                result ~= AggregateInvoice(record, "");
            }
            else
            {
                // Create one invoice per SN
                foreach (sn; sns)
                    result ~= AggregateInvoice(record, sn);
            }
        }
    }
    catch (Exception)
    {
        return [];
    }

    return result;
}

// Expand comma-separated serial numbers into individual entries
// e.g., "SN1, SN2, SN3" -> ["SN1", "SN2", "SN3"]
string[] expandSerialNumbers(string snField)
{
    if (snField.length == 0)
        return [];

    return snField
        .split(",")
        .map!(s => s.strip)
        .filter!(s => s.length > 0)
        .array;
}



// =============================================================================
// Matching Logic
// =============================================================================

HostMatchResult matchPartsToInvoices(HostParts parts, Invoice[] invoices, AggregateInvoice[] aggregateInvoices,
                                     ref bool[] invoiceMatched, ref bool[] aggregateMatched)
{
    HostMatchResult result;
    result.hostname = parts.hostname;

    foreach (part; parts.parts)
    {
        PartMatch match;
        match.part = part;

        // Try serial number match against aggregate invoices first (primary source)
        if (part.sn.length > 0)
        {
            foreach (i, agg; aggregateInvoices)
            {
                if (!aggregateMatched[i] && serialsMatch(part.sn, agg.sn))
                {
                    match.invoice = InvoiceInfo(
                        agg.source, agg.saleId, agg.date, agg.price, agg.product
                    ).nullable;
                    match.confidence = "high";
                    match.matchType = "serial";
                    aggregateMatched[i] = true;
                    break;
                }
            }
        }

        // Try serial number match against individual invoices (secondary)
        if (match.invoice.isNull && part.sn.length > 0)
        {
            foreach (i, inv; invoices)
            {
                if (!invoiceMatched[i] && serialsMatch(part.sn, inv.sn))
                {
                    match.invoice = InvoiceInfo(
                        inv.file, inv.purchasedbid, inv.date, inv.price, inv.descr
                    ).nullable;
                    match.confidence = "high";
                    match.matchType = "serial";
                    invoiceMatched[i] = true;
                    break;
                }
            }
        }

        // Try model match against aggregate invoices
        auto modelLower = part.model.toLower;
        bool isGenericReceiver = modelLower.canFind("usb receiver") ||
            modelLower.canFind("unifying receiver") ||
            modelLower.canFind("nano receiver");

        if (match.invoice.isNull && part.model.length > 0 && !isGenericReceiver)
        {
            // Try aggregate invoices first (using category from code prefix)
            foreach (i, agg; aggregateInvoices)
            {
                if (!aggregateMatched[i] &&
                    categoriesMatch(part.name, agg.category) &&
                    modelsMatchProduct(part.model, agg.product))
                {
                    // Enforce brand matching for aggregate invoices
                    auto productBrand = extractBrandFromProduct(agg.product);
                    
                    // If product has a brand, require it to match part brand (if part has one)
                    // This prevents ASRock parts from matching MSI invoices
                    bool brandOk = productBrand.length == 0 ||  // No brand in product = can match
                        part.mark.length == 0 ||                 // No brand in part = can match
                        brandsMatch(part.mark, productBrand);    // Both have brands = must match

                    if (brandOk)
                    {
                        match.invoice = InvoiceInfo(
                            agg.source, agg.saleId, agg.date, agg.price, agg.product
                        ).nullable;
                        match.confidence = brandsMatch(part.mark, productBrand) ? "medium" : "low";
                        match.matchType = brandsMatch(part.mark, productBrand) ? "model+brand" : "model";
                        aggregateMatched[i] = true;
                        break;
                    }
                }
            }

            // Try individual invoices
            if (match.invoice.isNull)
            {
                foreach (i, inv; invoices)
                {
                    if (!invoiceMatched[i] &&
                        categoriesMatch(part.name, inv.name) &&
                        modelsMatch(part.model, inv.model))
                    {
                        bool brandOk = part.mark.length == 0 || inv.mark.length == 0 ||
                            brandsMatch(part.mark, inv.mark);

                        if (brandOk)
                        {
                            match.invoice = InvoiceInfo(
                                inv.file, inv.purchasedbid, inv.date, inv.price, inv.descr
                            ).nullable;
                            match.confidence = brandsMatch(part.mark, inv.mark) ? "medium" : "low";
                            match.matchType = brandsMatch(part.mark, inv.mark) ? "model+brand" : "model";
                            invoiceMatched[i] = true;
                            break;
                        }
                    }
                }
            }
        }

        result.matches ~= match;
    }

    return result;
}

// Check if invoice is for hardware (auto-matchable category)
bool isHardwareInvoice(Invoice inv)
{
    // Try to match the invoice name to known hardware categories
    foreach (cat; ["cpu", "mb", "ram", "ssd", "hdd", "gpu"])
    {
        if (categoriesMatch(cat, inv.name))
            return true;
    }
    return false;
}

// =============================================================================
// CSV Export for Manual Review
// =============================================================================

void exportUnmatchedToCsv(string filepath, MatchOutput output)
{
    auto file = File(filepath, "w");

    // Header matching manual-matches.csv format
    file.writeln("invoice_id,invoice_sn,invoice_date,category,brand,model,match_type,hostname,notes");

    // Export unmatched aggregate invoices
    foreach (agg; output.unmatchedAggregateInvoices)
    {
        auto brand = extractBrandFromProduct(agg.product);
        file.writefln("%s,%s,%s,%s,%s,%s,,,# %s",
            escapeCsvField(agg.saleId),
            escapeCsvField(agg.sn),
            escapeCsvField(agg.date),
            escapeCsvField(agg.category),
            escapeCsvField(brand),
            escapeCsvField(agg.product),
            escapeCsvField(agg.code)
        );
    }

    // Export unmatched individual invoices
    foreach (inv; output.unmatchedInvoices)
    {
        file.writefln("%s,%s,%s,%s,%s,%s,,,# %s",
            escapeCsvField(inv.purchasedbid),
            escapeCsvField(inv.sn),
            escapeCsvField(inv.date),
            escapeCsvField(inv.name),
            escapeCsvField(inv.mark),
            escapeCsvField(inv.model),
            escapeCsvField(inv.file)
        );
    }

    // Export unmatched host parts (parts without invoice matches)
    foreach (host; output.hosts)
    {
        foreach (match; host.matches)
        {
            if (match.invoice.isNull)
            {
                file.writefln(",,%s,%s,%s,%s,,%s,# needs invoice",
                    "",  // no date
                    escapeCsvField(match.part.name),
                    escapeCsvField(match.part.mark),
                    escapeCsvField(match.part.model),
                    escapeCsvField(host.hostname)
                );
            }
        }
    }
}

string escapeCsvField(string field)
{
    if (field.canFind(",") || field.canFind("\"") || field.canFind("\n"))
        return "\"" ~ field.replace("\"", "\"\"") ~ "\"";
    return field;
}
