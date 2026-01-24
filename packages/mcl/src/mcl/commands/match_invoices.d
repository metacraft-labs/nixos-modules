module mcl.commands.match_invoices;

import std.stdio : writeln, File;
import std.conv : to;
import std.string : strip, toUpper, toLower, startsWith, endsWith, split, indexOf;
import std.array : array, replace;
import std.algorithm : map, filter, canFind, min, joiner;
import std.file : exists, dirEntries, SpanMode, readText;
import std.path : baseName;
import std.json : JSONOptions, parseJSON, JSONValue, JSONType;
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

// =============================================================================
// Category Extraction from Code Prefix
// =============================================================================

// Extract normalized category from JAR product code prefix
// e.g., "SSDSAMSUNGMZV8P2T0BW" -> "SSD", "CPUPINTELI912900K" -> "CPU"
string categoryFromCode(string code)
{
    if (code.length < 3)
        return "";

    auto upper = code.toUpper;

    // CPU
    if (upper.startsWith("CPUP") || upper.startsWith("CPUA"))
        return "CPU";

    // Motherboard
    if (upper.startsWith("MBIA") || upper.startsWith("MBIG") ||
        upper.startsWith("MBIM") || upper.startsWith("MBAA") ||
        upper.startsWith("MBAG"))
        return "MB";

    // RAM
    if (upper.startsWith("MRAM") || upper.startsWith("MSOD"))
        return "RAM";

    // SSD
    if (upper.startsWith("SSDS") || upper.startsWith("SSDK") ||
        upper.startsWith("SSDL") || upper.startsWith("SSDA") ||
        upper.startsWith("SSD"))
        return "SSD";

    // HDD
    if (upper.startsWith("HDDP") || upper.startsWith("HDD"))
        return "HDD";

    // GPU/Video Card
    if (upper.startsWith("VCRF") || upper.startsWith("VCR"))
        return "GPU";

    // Fan/Cooler
    if (upper.startsWith("FANC") || upper.startsWith("FANN") ||
        upper.startsWith("FAN"))
        return "Fan";

    // Power Supply
    if (upper.startsWith("PWRP") || upper.startsWith("PWR"))
        return "PSU";

    // Case
    if (upper.startsWith("CASE"))
        return "Case";

    // Keyboard
    if (upper.startsWith("KBDU") || upper.startsWith("KBLO") ||
        upper.startsWith("KBRA") || upper.startsWith("KBDA") ||
        upper.startsWith("KBCH") || upper.startsWith("KBST") ||
        upper.startsWith("KB"))
        return "Keyboard";

    // Mouse
    if (upper.startsWith("MOLO") || upper.startsWith("MORA") ||
        upper.startsWith("MSUS") || upper.startsWith("MOA4") ||
        upper.startsWith("MO"))
        return "Mouse";

    // Monitor
    if (upper.startsWith("MNLC") || upper.startsWith("MN"))
        return "Monitor";

    // Webcam
    if (upper.startsWith("FWEB"))
        return "Webcam";

    // Headphones
    if (upper.startsWith("MULH"))
        return "Headphones";

    // Mouse pad
    if (upper.startsWith("MOPL") || upper.startsWith("MOPG") ||
        upper.startsWith("MOPR"))
        return "Pad";

    // UPS
    if (upper.startsWith("UPSC") || upper.startsWith("UPSP") ||
        upper.startsWith("UPS"))
        return "UPS";

    // Network Switch
    if (upper.startsWith("NTLH") || upper.startsWith("SWTP"))
        return "Switch";

    // Cable
    if (upper.startsWith("CNCP") || upper.startsWith("CAVM"))
        return "Cable";

    // Network Rack
    if (upper.startsWith("NTRF"))
        return "Rack";

    // Bag/Backpack
    if (upper.startsWith("ACCN"))
        return "Bag";

    // Power Strip
    if (upper.startsWith("URRO") || upper.startsWith("UROK") ||
        upper.startsWith("URAL") || upper.startsWith("URHA"))
        return "PowerStrip";

    // Services (ignored)
    if (upper.startsWith("USLA") || upper.startsWith("USLR"))
        return "Service";

    // Advance payment (ignored)
    if (upper.startsWith("_AVA"))
        return "Advance";

    // Computer bundle (ignored)
    if (upper.startsWith("_PC_"))
        return "Bundle";

    // Other/Credit (ignored)
    if (upper.startsWith("_OTH"))
        return "Other";

    // Shipping (ignored)
    if (upper.startsWith("XXXX"))
        return "Shipping";

    return "";
}

// Check if category should be auto-matched to hosts
bool isAutoMatchCategory(string category)
{
    return category == "CPU" || category == "MB" || category == "RAM" ||
           category == "SSD" || category == "HDD" || category == "GPU" ||
           category == "Fan" || category == "PSU" || category == "Case";
}

// Check if category is a peripheral that can be manually matched
bool isPeripheralCategory(string category)
{
    return category == "Keyboard" || category == "Mouse" ||
           category == "Monitor" || category == "Webcam" ||
           category == "Headphones";
}

// Check if category is standalone (not tied to a host)
bool isStandaloneCategory(string category)
{
    return category == "UPS" || category == "Switch" || category == "Cable" ||
           category == "Rack" || category == "Bag" || category == "PowerStrip" ||
           category == "Pad";
}

// Check if category should be ignored
bool isIgnoredCategory(string category)
{
    return category == "Service" || category == "Advance" ||
           category == "Bundle" || category == "Other" || category == "Shipping";
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

    // Handle common brand aliases
    if (normalized == "micro-starinternational" || normalized == "micro-star" ||
        normalized.startsWith("micro-star"))
        return "msi";
    if (normalized == "siliconpower" || normalized == "spcc")
        return "siliconpower";
    if (normalized == "westerndigital")
        return "wd";

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

// Extract brand from product description (for aggregate invoices)
// e.g., "Дънна платка MSI PRO Z790-P WIFI" -> "MSI"
// Searches for brand anywhere in description (Bulgarian descriptions start with category)
string extractBrandFromProduct(string product)
{
    auto upper = product.toUpper.strip;

    // Skip Intel/AMD if they appear in compatibility context (e.g., "Intel LGA 1700")
    bool hasCompatContext = upper.canFind("LGA") || upper.canFind("SOCKET") ||
                            upper.canFind("AM4") || upper.canFind("AM5");

    // Common motherboard/GPU/hardware brands (check in order of specificity)
    // More specific brands first to avoid false positives
    immutable string[] brands = [
        "ASROCK", "ASUS", "MSI", "GIGABYTE", "EVGA", "ZOTAC", "PALIT", "PNY",
        "SAPPHIRE", "POWERCOLOR", "XFX",
        "CORSAIR", "G.SKILL", "KINGSTON", "CRUCIAL", "TEAMGROUP", "LEXAR", "A-DATA",
        "SAMSUNG", "WESTERN DIGITAL", "WD", "SEAGATE", "TOSHIBA", "HYNIX", "SILICON POWER",
        "NOCTUA", "BE QUIET", "COOLER MASTER", "ZALMAN", "ARCTIC", "DEEPCOOL", "EKWB",
        "SEASONIC", "THERMALTAKE", "NZXT", "FRACTAL", "LIAN LI", "PHANTEKS",
        "LOGITECH", "RAZER", "STEELSERIES", "HYPERX", "DUCKY", "GLORIOUS",
        "DELL", "LG", "BENQ", "ACER", "VIEWSONIC", "AOC", "FUJITSU",
    ];

    // Look for brand anywhere in description (Bulgarian products start with category name)
    foreach (brand; brands)
    {
        // Check for " BRAND " or " BRAND-" pattern (word boundaries)
        if (upper.canFind(" " ~ brand ~ " ") || upper.canFind(" " ~ brand ~ "-") ||
            upper.canFind(" " ~ brand ~ ",") || upper.canFind("(" ~ brand ~ ")") ||
            upper.startsWith(brand ~ " ") || upper.startsWith(brand ~ "-"))
            return brand;
    }

    // Only check Intel/AMD/NVIDIA if not in compatibility context
    if (!hasCompatContext)
    {
        if (upper.canFind(" INTEL ") || upper.startsWith("INTEL "))
            return "INTEL";
        if (upper.canFind(" AMD ") || upper.startsWith("AMD "))
            return "AMD";
        if (upper.canFind(" NVIDIA ") || upper.startsWith("NVIDIA "))
            return "NVIDIA";
    }

    return "";
}

string normalizeModel(string model)
{
    import std.regex : regex, replaceAll;

    auto normalized = model.toUpper.strip
        // Remove trademark symbols
        .replace("(R)", "")
        .replace("(TM)", "")
        .replace("®", "")
        .replace("™", "")
        // Remove common prefixes that add noise
        .replace("INTEL", "")
        .replace("AMD", "")
        .replace("CORE", "")
        .replace("RYZEN", "");

    // Remove CPU frequency info like "@ 2.80GHz" or "CPU @ 3.0GHz"
    normalized = normalized.replaceAll(regex(`\s*(CPU)?\s*@\s*\d+\.\d+\s*GHZ`, "i"), "");

    // Remove generation prefixes
    normalized = normalized
        .replace("14TH GEN", "")
        .replace("13TH GEN", "")
        .replace("12TH GEN", "")
        .replace("11TH GEN", "")
        .replace("10TH GEN", "")
        // Remove separators
        .replace(" ", "")
        .replace("-", "")
        .replace("_", "");

    return normalized;
}

struct ModelTokens
{
    string[] skus;        // Critical identifiers: 13900K, 7950X, 4090 (must match exactly)
    string[] descriptors; // Soft identifiers: I9, RTX, PRO (help but not required)
}

// Extract key identifying tokens from a model string
// SKUs are critical (must match), descriptors are supplementary
ModelTokens extractModelTokens(string model)
{
    import std.regex : regex, matchAll;
    import std.uni : toUpper;

    ModelTokens tokens;
    auto normalized = model.toUpper;

    // Match CPU SKU numbers like 13900K, 7950X, 5800X3D - these are CRITICAL
    auto skuPattern = regex(`\b(\d{4,5}[A-Z]*\d*[A-Z]*)\b`);
    foreach (m; normalized.matchAll(skuPattern))
        tokens.skus ~= m[1].to!string;

    // Match GPU model numbers like 4090, 3080, 7900 - CRITICAL
    auto gpuNumPattern = regex(`\b(RTX|GTX|RX)?\s*(\d{4})\s*(TI|XT|XTX|SUPER)?\b`);
    foreach (m; normalized.matchAll(gpuNumPattern))
    {
        // The 4-digit number with optional suffix is the critical part
        string sku = m[2].to!string;
        if (m[3].length > 0)
            sku ~= m[3].to!string;
        if (sku.length > 0)
            tokens.skus ~= sku;
    }

    // Match SSD part numbers like CT2000P3PSSD8 (Crucial), MZ-V8P2T0BW (Samsung)
    auto ssdPartPattern = regex(`\b(CT\d+P\d+[A-Z]*SSD\d*|MZ-?[A-Z0-9]+|SKC\d+[A-Z]*\d*|NM\d+)\b`);
    foreach (m; normalized.matchAll(ssdPartPattern))
        tokens.skus ~= m[1].to!string;

    // Match CPU tier identifiers like i9, i7 - descriptors only
    auto cpuTierPattern = regex(`\b(I[3579])\b`);
    foreach (m; normalized.matchAll(cpuTierPattern))
        tokens.descriptors ~= m[1].to!string;

    // Match GPU family prefixes - descriptors only
    auto gpuFamilyPattern = regex(`\b(RTX|GTX|RX|RADEON|GEFORCE)\b`);
    foreach (m; normalized.matchAll(gpuFamilyPattern))
        tokens.descriptors ~= m[1].to!string;

    // Match peripheral product names (words 3+ chars) - treat as SKUs for peripherals
    auto productPattern = regex(`\b([A-Z][A-Z0-9]{2,}|V\d+)\b`);
    foreach (m; normalized.matchAll(productPattern))
    {
        auto token = m[1].to!string;
        // Skip common noise words
        if (token != "USB" && token != "RECEIVER" && token != "KEYBOARD" &&
            token != "MOUSE" && token != "GAMING" && token != "RGB" &&
            token != "GEN" && token != "INTEL" && token != "AMD" &&
            token != "CORE" && token != "RYZEN" && token != "PRO")
            tokens.descriptors ~= token;
    }

    return tokens;
}

bool modelsMatch(string model1, string model2)
{
    if (model1.length == 0 || model2.length == 0)
        return false;

    auto norm1 = normalizeModel(model1);
    auto norm2 = normalizeModel(model2);

    // Direct match after normalization
    if (norm1 == norm2 || norm1.canFind(norm2) || norm2.canFind(norm1))
        return true;

    // Token-based matching with strict SKU requirements
    auto tokens1 = extractModelTokens(model1);
    auto tokens2 = extractModelTokens(model2);

    // If both have SKUs, ALL SKUs from the shorter list must match
    // This prevents i9-12900K matching i9-13900K (different SKU numbers)
    if (tokens1.skus.length > 0 && tokens2.skus.length > 0)
    {
        auto shorter = tokens1.skus.length <= tokens2.skus.length ? tokens1.skus : tokens2.skus;
        auto longer = tokens1.skus.length > tokens2.skus.length ? tokens1.skus : tokens2.skus;

        foreach (sku; shorter)
        {
            if (!longer.canFind(sku))
                return false;  // SKU mismatch = no match
        }
        return true;  // All SKUs matched
    }

    // Fallback for items without clear SKUs: require descriptor overlap
    if (tokens1.descriptors.length > 0 && tokens2.descriptors.length > 0)
    {
        auto shorter = tokens1.descriptors.length <= tokens2.descriptors.length
            ? tokens1.descriptors : tokens2.descriptors;
        auto longer = tokens1.descriptors.length > tokens2.descriptors.length
            ? tokens1.descriptors : tokens2.descriptors;

        size_t matchCount = 0;
        foreach (t; shorter)
        {
            if (longer.canFind(t))
                matchCount++;
        }

        // Require ALL descriptors to match for items without SKUs
        return matchCount == shorter.length;
    }

    return false;
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
    if (p == "keyboard" && (i.canFind("kbd") || i.canFind("keyboard")))
        return true;
    if (p == "mouse" && (i.canFind("mouse") || i.canFind("mice")))
        return true;
    if (p == "webcam" && (i.canFind("camera") || i.canFind("webcam")))
        return true;

    return false;
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

// Check if model matches product description (for aggregate invoices)
// The aggregate file has full Bulgarian product descriptions, not just model numbers
bool modelsMatchProduct(string model, string product)
{
    if (model.length == 0 || product.length == 0)
        return false;

    auto modelTokens = extractModelTokens(model);
    auto productTokens = extractModelTokens(product);

    // If model has SKUs, ALL must appear in product description
    if (modelTokens.skus.length > 0)
    {
        foreach (sku; modelTokens.skus)
        {
            if (!productTokens.skus.canFind(sku))
                return false;
        }
        return true;
    }

    // Fallback: require all descriptors to match
    if (modelTokens.descriptors.length > 0 && productTokens.descriptors.length > 0)
    {
        foreach (desc; modelTokens.descriptors)
        {
            if (!productTokens.descriptors.canFind(desc))
                return false;
        }
        return true;
    }

    return false;
}

bool isHardwareInvoice(Invoice inv)
{
    auto name = inv.name.toLower;
    return name.canFind("cpu") || name.canFind("mb") || name.canFind("motherboard") ||
        name.canFind("ram") || name.canFind("memory") || name.canFind("ddr") ||
        name.canFind("ssd") || name.canFind("disk") || name.canFind("gpu") ||
        name.canFind("video") || name.canFind("graphics");
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
