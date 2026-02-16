module mcl.commands.invoices.match;

import std.stdio : writeln, writefln, File;
import std.conv : to;
import std.string : strip, toLower, startsWith, split;
import std.array : array, replace;
import std.algorithm : map, filter, canFind;
import std.file : exists, dirEntries, SpanMode, readText;
import std.json : JSONOptions, parseJSON, JSONType;
import std.exception : ifThrown;

import argparse : Command, Default, Description, matchCmd, NamedArgument, Placeholder, Required, SubCommand;

import mcl.utils.json : toJSON, fromJSON;
import mcl.commands.host_info : HostParts;
import mcl.commands.invoices.types : InvoiceItem, ManualMatchRecord, Product, ProductCategory, loadInvoiceItems;
import mcl.commands.invoices.heuristics : isAutoMatchCategory,
    categoriesMatch, extractBrandFromProduct, brandsMatch, serialsMatch,
    modelsMatch, matchProductCategory;
import mcl.commands.invoices.list : ListArgs, listProducts;

// =============================================================================
// Command Args
// =============================================================================

@(Command("match-invoices")
    .Description("Match hardware parts to purchase invoices"))
struct MatchInvoicesArgs
{
    SubCommand!(
        Default!MatchArgs,
        ListArgs
    ) cmd;
}

/// Match subcommand - matches parts to invoices (default behavior)
@(Command("match")
    .Description("Match hardware parts to purchase invoices"))
struct MatchArgs
{
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
// Match Data Structures
// =============================================================================

struct PartMatch
{
    Product part;
    const(InvoiceItem)* invoice;
    string confidence;     // "high", "medium", "low", or ""
    string matchType;      // "serial", "model", "model+brand", or ""
}

struct HostMatchResult
{
    string hostname;
    PartMatch[] matches;
}

struct MatchOutput
{
    HostMatchResult[] hosts;
    InvoiceItem[] unmatchedInvoiceItems;
    ManualMatchRecord[] standaloneItems;
    ManualMatchRecord[] ignoredItems;
}

// =============================================================================
// Command Handler
// =============================================================================

/// Main command dispatcher
int matchInvoices(MatchInvoicesArgs args)
{
    return args.cmd.matchCmd!(
        (MatchArgs a) => doMatch(a),
        (ListArgs a) => listProducts(a)
    );
}

/// Match subcommand handler
int doMatch(MatchArgs args)
{
    auto invoices = args.invoicesDir.length > 0
        ? loadInvoiceItems(args.invoicesDir)
        : [];

    auto allHostParts = loadHostParts(args.hostInfoDir);
    auto manualMatches = args.manualMatchesFile.length > 0
        ? loadManualMatches(args.manualMatchesFile)
        : [];

    // Track which invoices get matched globally
    bool[] invoiceMatched = new bool[invoices.length];

    // Build host results map for manual match injection
    HostMatchResult[string] hostResults;
    foreach (parts; allHostParts)
        hostResults[parts.hostname] = HostMatchResult(parts.hostname, []);

    MatchOutput output;

    // Apply manual matches first (they take precedence)
    foreach (manual; manualMatches)
    {
        // Find and mark matching invoice
        auto invoicePtr = findAndMarkInvoiceItem(manual, invoices, invoiceMatched);

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
            auto cat = matchProductCategory(manual.category);
            hostResults[manual.hostname].matches ~= PartMatch(
                part: Product(
                    category: cat.isNull ? ProductCategory.Other : cat.get,
                    vendor: manual.brand,
                    model: manual.model,
                    sn: manual.invoiceSn,
                ),
                invoice: invoicePtr,
                confidence: "high",
                matchType: "manual"
            );
        }
    }

    // Auto-match remaining parts
    foreach (parts; allHostParts)
    {
        auto autoMatches = matchPartsToInvoiceItems(parts, invoices, invoiceMatched);
        hostResults[parts.hostname].matches ~= autoMatches.matches;
    }

    output.hosts = hostResults.values.array;

    // Collect unmatched invoices (only hardware-related)
    foreach (i, inv; invoices)
    {
        if (!invoiceMatched[i] && isHardwareInvoiceItem(inv))
            output.unmatchedInvoiceItems ~= inv;
    }

    // Export unmatched items to CSV if requested
    if (args.exportUnmatchedFile.length > 0)
        exportUnmatchedToCsv(args.exportUnmatchedFile, output);

    output
        .toJSON(true)
        .toPrettyString(JSONOptions.doNotEscapeSlashes)
        .writeln();

    return 0;
}

// =============================================================================
// Manual Match Handling
// =============================================================================

/// Find and mark invoice as matched based on manual match record, returns pointer to matched invoice
const(InvoiceItem)* findAndMarkInvoiceItem(ManualMatchRecord manual, InvoiceItem[] invoices, ref bool[] invoiceMatched)
{
    foreach (i, ref inv; invoices)
    {
        if (!invoiceMatched[i] &&
            (inv.purchasedbid == manual.invoiceId || serialsMatch(inv.sn, manual.invoiceSn)))
        {
            invoiceMatched[i] = true;
            return &inv;
        }
    }
    return null;
}

// =============================================================================
// Host Parts Loading
// =============================================================================

/// Load host parts from JSON files with nested "output" structure
HostParts[] loadHostParts(string hostInfoDir)
{
    if (!exists(hostInfoDir))
        return [];

    return dirEntries(hostInfoDir, "*.json", SpanMode.shallow)
        .map!(entry => parseHostInfoJson(readText(entry.name)))
        .filter!(p => p.hostname.length > 0)
        .array;
}

/// Parse host-info JSON which has nested structure: { output: { hostname, parts } }
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
                    Product part;
                    if ("name" in partJson)
                    {
                        auto cat = matchProductCategory(partJson["name"].str);
                        part.category = cat.isNull ? ProductCategory.Other : cat.get;
                    }
                    if ("mark" in partJson) part.vendor = partJson["mark"].str;
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

/// Load manual matches from CSV file
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
// Matching Logic
// =============================================================================

HostMatchResult matchPartsToInvoiceItems(HostParts parts, InvoiceItem[] invoices, ref bool[] invoiceMatched)
{
    HostMatchResult result;
    result.hostname = parts.hostname;

    foreach (part; parts.parts)
    {
        PartMatch match;
        match.part = part;

        // Try serial number match first
        if (part.sn.length > 0)
        {
            foreach (i, ref inv; invoices)
            {
                if (!invoiceMatched[i] && serialsMatch(part.sn, inv.sn))
                {
                    match.invoice = &inv;
                    match.confidence = "high";
                    match.matchType = "serial";
                    invoiceMatched[i] = true;
                    break;
                }
            }
        }

        // Skip generic receivers for model matching
        auto modelLower = part.model.toLower;
        bool isGenericReceiver = modelLower.canFind("usb receiver") ||
            modelLower.canFind("unifying receiver") ||
            modelLower.canFind("nano receiver");

        // Try model match
        if (match.invoice is null && part.model.length > 0 && !isGenericReceiver)
        {
            foreach (i, ref inv; invoices)
            {
                if (!invoiceMatched[i] &&
                    categoriesMatch(part.category.to!string, inv.name) &&
                    modelsMatch(part.model, inv.model))
                {
                    bool brandOk = part.vendor.length == 0 || inv.mark.length == 0 ||
                        brandsMatch(part.vendor, inv.mark);

                    if (brandOk)
                    {
                        match.invoice = &inv;
                        match.confidence = brandsMatch(part.vendor, inv.mark) ? "medium" : "low";
                        match.matchType = brandsMatch(part.vendor, inv.mark) ? "model+brand" : "model";
                        invoiceMatched[i] = true;
                        break;
                    }
                }
            }
        }

        result.matches ~= match;
    }

    return result;
}

/// Check if invoice is for hardware (auto-matchable category)
bool isHardwareInvoiceItem(InvoiceItem inv)
{
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

    // Export unmatched individual invoices
    foreach (inv; output.unmatchedInvoiceItems)
    {
        file.writefln("%s,%s,%s,%s,%s,%s,,,# %s",
            escapeCsvField(inv.purchasedbid),
            escapeCsvField(inv.sn),
            escapeCsvField(inv.invoiceDate.toISOExtString),
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
            if (match.invoice is null)
            {
                file.writefln(",,%s,%s,%s,%s,,%s,# needs invoice",
                    "",  // no date
                    escapeCsvField(match.part.category.to!string),
                    escapeCsvField(match.part.vendor),
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
