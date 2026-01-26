module mcl.commands.invoices.types;

import std.algorithm : joiner, map;
import std.array : array;
import std.conv : to;
import std.csv : csvReader, Malformed;
import std.datetime : Date;
import std.exception : ifThrown;
import std.file : dirEntries, exists, readText, SpanMode;
import std.path : baseName;

import mcl.utils.string : StringRepresentation;

// =============================================================================
// InvoiceItem - CSV record with fields matching column names
// =============================================================================

/// Invoice line item from CSV (field names match CSV headers for direct parsing)
struct InvoiceItem
{
    // Fields matching CSV columns exactly
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

    // Source file (set after CSV parsing, not from CSV)
    string file;

    // Typed accessor properties
    Date invoiceDate() const => Date.fromISOExtString(date[0 .. 10]);
    double invoicePrice() const => price.to!double.ifThrown(0.0);
    double invoicePriceWithVat() const => total_lvn.to!double.ifThrown(0.0);
}

// =============================================================================
// InvoiceItem Loading
// =============================================================================

/// Load all invoices from a directory of CSV files
InvoiceItem[] loadInvoiceItems(string invoicesDir)
in (invoicesDir.exists, "Invoice directory does not exist: " ~ invoicesDir)
{
    return dirEntries(invoicesDir, "*.csv", SpanMode.shallow)
        .map!(entry => parseInvoiceItemCsv(entry.name))
        .joiner
        .array;
}

/// Parse a single invoice CSV file
InvoiceItem[] parseInvoiceItemCsv(string filepath)
{
    import std.csv : CSVException;
    import std.stdio : stderr;

    auto filename = baseName(filepath);
        return filepath
            .readText
            .csvReader!(InvoiceItem, Malformed.ignore)(null)
            .map!((item) { item.file = filename; return item; })
            .array;
}

// =============================================================================
// ProductCategory - Unified product category enum
// =============================================================================

/// Known product categories for hardware components
enum ProductCategory
{
    @StringRepresentation("CPU") CPU,
    @StringRepresentation("Motherboard") MB,
    @StringRepresentation("RAM") RAM,
    @StringRepresentation("SSD") SSD,
    @StringRepresentation("HDD") HDD,
    @StringRepresentation("Graphics Card") GPU,
    @StringRepresentation("Fan") Fan,
    @StringRepresentation("Power Supply") PSU,
    @StringRepresentation("Case") Case,
    @StringRepresentation("Keyboard") Keyboard,
    @StringRepresentation("Mouse") Mouse,
    @StringRepresentation("Monitor") Monitor,
    @StringRepresentation("Webcam") Webcam,
    @StringRepresentation("Headphones") Headphones,
    @StringRepresentation("Cable") Cable,
    @StringRepresentation("UPS") UPS,
    @StringRepresentation("Power Strip") PowerStrip,
    @StringRepresentation("Network Switch") Switch,
    @StringRepresentation("Docking Station") DockingStation,
    @StringRepresentation("Laptop Stand") LaptopStand,
    @StringRepresentation("Backpack") Backpack,
    @StringRepresentation("Smartphone") Smartphone,
    @StringRepresentation("Services") Services,
    @StringRepresentation("Other") Other,
}

// =============================================================================
// Product - Unified product identity struct
// =============================================================================

/// Unified product identity
struct Product
{
    ProductCategory category;  // CPU, MB, RAM, SSD, GPU, etc.
    string vendor;             // Manufacturer/brand (e.g., "Intel", "Samsung")
    string model;              // Product model (e.g., "Core i9-13900K")
    string variant;            // "BOX", "Tray", or "" (for invoice grouping)
    string sn;                 // Serial number (optional, for matching)
}

// =============================================================================
// Shared Data Structures for Commands
// =============================================================================

/// Manual match record from manual-matches.csv
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
