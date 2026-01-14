module mcl.commands.match_invoices;

import std.stdio : writeln, File;
import std.conv : to;
import std.string : strip, toUpper, toLower, startsWith, endsWith;
import std.array : array, replace;
import std.algorithm : map, filter, canFind, min, joiner;
import std.file : exists, dirEntries, SpanMode, readText;
import std.path : baseName;
import std.json : JSONOptions, parseJSON;
import std.typecons : Nullable, nullable;
import std.csv : csvReader, Malformed;
import std.exception : ifThrown;

import argparse : Command, Description, NamedArgument, Placeholder, Required;

import mcl.utils.json : toJSON, fromJSON;
import mcl.commands.host_info : Part, HostParts;

// =============================================================================
// Command Args
// =============================================================================

@(Command("match-invoices")
    .Description("Match hardware parts to purchase invoices"))
struct MatchInvoicesArgs
{
    @(NamedArgument(["invoices"])
        .Placeholder("DIR")
        .Description("Directory containing invoice CSV files")
        .Required())
    string invoicesDir;

    @(NamedArgument(["host-info-dir"])
        .Placeholder("DIR")
        .Description("Directory containing host-info JSON files")
        .Required())
    string hostInfoDir;
}

// =============================================================================
// Invoice Data Structures
// =============================================================================

// CSV record structure matching the invoice file columns
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

struct MatchResult
{
    string hostname;
    PartMatch[] matches;
    Invoice[] unmatchedInvoices;
}

// =============================================================================
// Command Handler
// =============================================================================

int matchInvoices(MatchInvoicesArgs args)
{
    auto invoices = loadInvoices(args.invoicesDir);
    auto allHostParts = loadHostParts(args.hostInfoDir);

    allHostParts
        .map!(parts => matchPartsToInvoices(parts, invoices))
        .array
        .toJSON(true)
        .toPrettyString(JSONOptions.doNotEscapeSlashes)
        .writeln();

    return 0;
}

HostParts[] loadHostParts(string hostInfoDir)
{
    return exists(hostInfoDir)
        ? dirEntries(hostInfoDir, "*.json", SpanMode.shallow)
            .map!(entry => readText(entry.name).parseJSON.fromJSON!HostParts.ifThrown(HostParts.init))
            .filter!(p => p.hostname.length > 0)
            .array
        : [];
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
// Serial Number Normalization
// =============================================================================

string normalizeSerial(string sn)
{
    if (sn.length == 0)
        return "";

    auto normalized = sn.toUpper.strip;

    // Remove common prefixes
    if (normalized.startsWith("JAR"))
        normalized = normalized[3 .. $];
    if (normalized.startsWith("S") && normalized.length > 10)
        normalized = normalized[1 .. $];

    // Remove common suffixes
    if (normalized.endsWith("N") && normalized.length > 10)
        normalized = normalized[0 .. $ - 1];

    return normalized;
}

// Check if two serial numbers match (handles partial matches)
bool serialsMatch(string sn1, string sn2)
{
    if (sn1.length == 0 || sn2.length == 0)
        return false;

    auto norm1 = normalizeSerial(sn1);
    auto norm2 = normalizeSerial(sn2);

    if (norm1 == norm2)
        return true;

    // Check suffix match (invoice may have truncated SN)
    auto minLen = min(norm1.length, norm2.length);
    if (minLen >= 6)
    {
        if (norm1.endsWith(norm2[$ - minLen .. $]) || norm2.endsWith(norm1[$ - minLen .. $]))
            return true;
        if (norm1.canFind(norm2) || norm2.canFind(norm1))
            return true;
    }

    return false;
}

// =============================================================================
// Brand/Model Normalization
// =============================================================================

string normalizeBrand(string brand)
{
    auto normalized = brand.toLower.strip;

    // Common brand normalizations
    normalized = normalized
        .replace("intl", "")
        .replace("international", "")
        .replace("co.", "")
        .replace("ltd.", "")
        .replace("ltd", "")
        .replace("inc.", "")
        .replace("inc", "")
        .replace("corp.", "")
        .replace("corp", "")
        .replace(",", "")
        .replace(".", "")
        .replace(" ", "");

    return normalized;
}

bool brandsMatch(string brand1, string brand2)
{
    if (brand1.length == 0 || brand2.length == 0)
        return false;

    auto norm1 = normalizeBrand(brand1);
    auto norm2 = normalizeBrand(brand2);

    return norm1 == norm2 || norm1.canFind(norm2) || norm2.canFind(norm1);
}

string normalizeModel(string model)
{
    return model.toUpper.strip
        .replace(" ", "")
        .replace("-", "")
        .replace("_", "");
}

bool modelsMatch(string model1, string model2)
{
    if (model1.length == 0 || model2.length == 0)
        return false;

    auto norm1 = normalizeModel(model1);
    auto norm2 = normalizeModel(model2);

    return norm1 == norm2 || norm1.canFind(norm2) || norm2.canFind(norm1);
}

// =============================================================================
// Category Matching
// =============================================================================

bool categoriesMatch(string partCat, string invoiceCat)
{
    auto p = partCat.toLower;
    auto i = invoiceCat.toLower;

    if (p == i)
        return true;

    // Handle common category variations
    if (p == "cpu" && i.canFind("cpu"))
        return true;
    if (p == "mb" && (i.canFind("mb") || i.canFind("motherboard")))
        return true;
    if (p == "ram" && (i.canFind("ram") || i.canFind("memory") || i.canFind("ddr")))
        return true;
    if (p == "ssd" && (i.canFind("ssd") || i.canFind("disk") || i.canFind("drive")))
        return true;
    if (p == "gpu" && (i.canFind("gpu") || i.canFind("video") || i.canFind("graphics")))
        return true;

    return false;
}

// =============================================================================
// Matching Logic
// =============================================================================

MatchResult matchPartsToInvoices(HostParts parts, Invoice[] invoices)
{
    MatchResult result;
    result.hostname = parts.hostname;

    bool[] invoiceMatched = new bool[invoices.length];

    foreach (part; parts.parts)
    {
        PartMatch match;
        match.part = part;

        // Try serial number match first (highest confidence)
        if (part.sn.length > 0)
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

        // Try model + brand match (medium confidence)
        if (match.invoice.isNull && part.model.length > 0)
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

        result.matches ~= match;
    }

    // Collect unmatched invoices (only hardware-related)
    foreach (i, inv; invoices)
    {
        if (!invoiceMatched[i] && isHardwareInvoice(inv))
        {
            result.unmatchedInvoices ~= inv;
        }
    }

    return result;
}

bool isHardwareInvoice(Invoice inv)
{
    auto name = inv.name.toLower;
    return name.canFind("cpu") || name.canFind("mb") || name.canFind("motherboard") ||
        name.canFind("ram") || name.canFind("memory") || name.canFind("ddr") ||
        name.canFind("ssd") || name.canFind("disk") || name.canFind("gpu") ||
        name.canFind("video") || name.canFind("graphics");
}
