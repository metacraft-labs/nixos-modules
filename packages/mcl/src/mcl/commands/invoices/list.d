module mcl.commands.invoices.list;

import std.stdio : writeln, writefln;
import std.conv : to;
import std.string : strip, toLower, indexOf;
import std.array : array, assocArray, join;
import std.algorithm : map, filter, sort, joiner, each, startsWith;
import std.datetime : Date;
import std.file : exists;
import std.path : baseName;
import std.json : JSONOptions;
import std.traits : EnumMembers, FieldNameTuple;
import std.typecons : tuple;

import argparse : Command, Description, NamedArgument, Placeholder;

import mcl.utils.json : toJSON;
import mcl.commands.invoices.types : InvoiceItem, loadInvoiceItems, Product, ProductCategory;
import mcl.commands.invoices.heuristics : extractBrandFromProduct, matchProductCategory,
    invoiceNameMatchesCategory, extractVariant, removeVariantFromModel, removeSkuSuffix,
    removeCategoryPrefix, isBrandPlusSku, extractModelFromFullDescription, categoryFromCode,
    getBrandAliases;

// =============================================================================
// Command Args
// =============================================================================

/// List subcommand - lists products by category
@(Command("list")
    .Description("List products by category from invoices"))
struct ListArgs
{
    @(NamedArgument(["invoices"])
        .Placeholder("DIR")
        .Description("Directory containing individual invoice CSV files"))
    string invoicesDir;

    @(NamedArgument(["category", "categories", "c"])
        .Placeholder("CATEGORY")
        .Description("Categories to filter (e.g., cpu, ssd, ram). Use 'all' for all, '?' for help"))
    string[] category;

    @(NamedArgument(["details", "d"])
        .Placeholder("FIELDS")
        .Description("Fields to show: productid, price, date, invoice, variant, sn. Use 'all' for all, '?' for help"))
    string[] details;

    @(NamedArgument(["json"])
        .Description("Output as JSON instead of text"))
    bool jsonOutput;
}

// =============================================================================
// Data Structures
// =============================================================================

/// Single product with all its invoice occurrences
struct ProductOccurrence
{
    Product product;              // Unified product identity
    InvoiceItem[] invoices;       // All invoice items for this product
}

/// Output for list command - keyed by ProductCategory
alias ListOutput = ProductOccurrence[][ProductCategory];

/// Price statistics for a category
struct CategoryPriceStats
{
    double totalValue = 0;
    double avgPrice = 0;
    double minPrice = 0;
    double maxPrice = 0;
    size_t itemCount = 0;
}

/// Overall statistics computed from invoice items
struct ListStatistics
{
    // Count stats
    size_t totalItems;           // Total invoice line items
    size_t uniqueByProductId;    // Unique productid values
    size_t uniqueByName;         // Unique normalized product names

    // Price stats per category
    CategoryPriceStats[ProductCategory] categoryStats;

    // Date stats
    Date earliestDate;
    Date latestDate;
}

// =============================================================================
// Command Handler
// =============================================================================

/// List products by category
int listProducts(ListArgs args)
{
    import std.stdio : stderr;

    // Handle --category=? or --category=help
    if (args.category.length == 1 && (args.category[0] == "?" || args.category[0].toLower == "help"))
    {
        writeln("Available categories:");
        static foreach (cat; EnumMembers!ProductCategory)
            writeln("  ", cat.to!string);
        writeln("\nUse --category=all to list all categories");
        writeln("Use multiple --category flags to list specific categories");
        return 0;
    }

    // Handle --details=? or --details=help
    if (args.details.length == 1 && (args.details[0] == "?" || args.details[0].toLower == "help"))
    {
        writeln("Available detail fields:");
        static foreach (field; FieldNameTuple!InvoiceItem)
            writeln("  ", field);
        writeln("\nUse --details=all to show all fields");
        writeln("Example: --details=productid --details=price");
        return 0;
    }

    // Validate invoices directory (required for all other operations)
    if (args.invoicesDir.length == 0)
    {
        stderr.writeln("Error: --invoices directory is required");
        return 1;
    }

    if (!exists(args.invoicesDir))
    {
        stderr.writeln("Error: invoices directory not found: ", args.invoicesDir);
        return 1;
    }

    // Validate category argument
    if (args.category.length == 0)
    {
        stderr.writeln("Error: --category is required (use --category=? for help)");
        return 1;
    }

    // Determine which categories to process
    ProductCategory[] categories;
    foreach (catArg; args.category)
    {
        if (catArg.toLower == "all")
        {
            categories = [EnumMembers!ProductCategory];
        }
        else
        {
            auto matchedCategory = matchProductCategory(catArg);
            if (matchedCategory.isNull)
            {
                stderr.writeln("Error: unknown category '", catArg, "'");
                stderr.writeln("Use --category=? to see available categories");
                return 1;
            }
            categories ~= matchedCategory.get;
        }
    }

    // Load invoices and group by product for each category
    auto invoices = loadInvoiceItems(args.invoicesDir);
    auto outputs = categories
        .map!(c => tuple(c, groupInvoiceItemsByProduct(invoices, c)))
        .assocArray;

    // Output results
    if (args.jsonOutput)
    {
        outputs.toJSON(true)
            .toPrettyString(JSONOptions.doNotEscapeSlashes)
            .writeln();
    }
    else
    {
        outputs
            .computeStatistics()
            .printStatisticsBox();

        foreach (cat, products; outputs)
            printCategoryOutput(products, cat, args.details);
    }

    return 0;
}

// =============================================================================
// Helper Functions
// =============================================================================

/// Compute statistics from list outputs
ListStatistics computeStatistics(ListOutput outputs)
{
    ListStatistics stats;
    bool[string] seenProductIds;
    bool[string] seenNames;

    foreach (cat, products; outputs)
    {
        CategoryPriceStats catStats;

        foreach (product; products)
        {
            // Build unique name key from vendor + model + variant
            auto nameKey = product.product.vendor ~ " " ~ product.product.model;
            if (product.product.variant.length > 0)
                nameKey ~= " " ~ product.product.variant;

            if (nameKey !in seenNames)
                seenNames[nameKey] = true;

            foreach (ref inv; product.invoices)
            {
                stats.totalItems++;
                catStats.itemCount++;

                // Count unique productids
                auto pid = inv.productid;
                if (pid.length > 0 && pid !in seenProductIds)
                    seenProductIds[pid] = true;

                auto price = inv.invoicePriceWithVat;
                auto date = inv.invoiceDate;

                // Category price stats
                if (price > 0)
                {
                    catStats.totalValue += price;
                    if (catStats.minPrice == 0 || price < catStats.minPrice)
                        catStats.minPrice = price;
                    if (price > catStats.maxPrice)
                        catStats.maxPrice = price;
                }

                // Global date stats
                if (date != Date.init)
                {
                    if (stats.earliestDate == Date.init || date < stats.earliestDate)
                        stats.earliestDate = date;
                    if (stats.latestDate == Date.init || date > stats.latestDate)
                        stats.latestDate = date;
                }
            }
        }

        if (catStats.itemCount > 0)
            catStats.avgPrice = catStats.totalValue / catStats.itemCount;

        stats.categoryStats[cat] = catStats;
    }

    stats.uniqueByProductId = seenProductIds.length;
    stats.uniqueByName = seenNames.length;

    return stats;
}

/// Print statistics in a box format
void printStatisticsBox(ListStatistics stats)
{
    // All lines are exactly 62 characters wide (including borders)
    writefln("╔════════════════════════════════════════════════════════════╗");
    writefln("║                        Statistics                          ║");
    writefln("╠════════════════════════════════════════════════════════════╣");
    writefln("║  Total items:          %-4d                                ║", stats.totalItems);
    writefln("║  Unique (productid):   %-4d                                ║", stats.uniqueByProductId);
    writefln("║  Unique (name):        %-4d                                ║", stats.uniqueByName);
    writefln("║  Date range:           %s to %s            ║",
            stats.earliestDate.toISOExtString, stats.latestDate.toISOExtString);
    writefln("╠════════════════════════════════════════════════════════════╣");
    writefln("║  Category     Items     Total      Avg      Min      Max   ║");
    writefln("╟────────────────────────────────────────────────────────────╢");
    foreach (cat, catStats; stats.categoryStats)
    {
        writefln("║  %-10s  %5d  %9.2f  %7.2f  %7.2f  %7.2f   ║",
            cat.to!string, catStats.itemCount, catStats.totalValue,
            catStats.avgPrice, catStats.minPrice, catStats.maxPrice);
    }
    writefln("╚════════════════════════════════════════════════════════════╝");
    writefln("");
}

/// Print category output in text format
void printCategoryOutput(ProductOccurrence[] products, ProductCategory category, string[] detailFields)
{
    import std.range : iota;

    writeln("# Category: ", category.to!string);
    foreach (ref occurrence; products)
    {
        auto parts = [occurrence.product.vendor, occurrence.product.model, occurrence.product.variant]
            .filter!(s => s.length > 0);
        writefln("* %s", parts.join(" "));

        if (detailFields)
        {
            iota(occurrence.invoices.length)
                .map!(i => detailFields
                    .map!(field => field ~ ": " ~ getInvoiceField(occurrence, i, field))
                    .join(", "))
                .filter!(s => !!s)
                .each!(s => writefln!"  - %s"(s));

            writeln();
        }
    }
    if (!detailFields) writeln();
}

/// Get field value from invoice by name
string getInvoiceField(ref const ProductOccurrence occurrence, size_t invoiceIdx, string field)
{
    import mcl.utils.reflection : getField, hasField;
    import std.string : startsWith;

    const InvoiceItem* inv = &occurrence.invoices[invoiceIdx];

    // Handle product.* fields (e.g., product.vendor, product.model)
    if (field.startsWith("product."))
    {
        auto productField = field[8 .. $];  // Skip "product."
        if (hasField!Product(productField))
            return getField(occurrence.product, productField);
        return "";
    }

    // Handle computed/derived fields
    switch (field)
    {
        case "variant": return occurrence.product.variant;
        case "invoice": return extractInvoiceItemNumber(inv.file, inv.purchasedbid);
        case "date": return formatDate(inv.invoiceDate);
        case "price":
            return inv.invoicePriceWithVat.to!string;
        default:
            // Use generic reflection for direct InvoiceItem fields
            if (hasField!InvoiceItem(field))
                return getField(*inv, field);
            return "";
    }
}

/// Check if invoice matches category (by name field or productid code)
bool invoiceMatchesCategory(ref InvoiceItem inv, ProductCategory category)
{
    import std.conv : to;

    // Check by productid code first - this is more specific
    string codeCategory = "";
    if (inv.productid.length > 0)
        codeCategory = categoryFromCode(inv.productid);

    // If productid maps to a specific category, use that
    if (codeCategory.length > 0)
    {
        // If requesting Other, exclude items that have a specific category from productid
        if (category == ProductCategory.Other)
            return codeCategory == "Other";
        return codeCategory == category.to!string;
    }

    // Fallback: check by name field
    return invoiceNameMatchesCategory(inv.name, category);
}

/// Group invoices by product, filtered by category
ProductOccurrence[] groupInvoiceItemsByProduct(InvoiceItem[] invoices, ProductCategory category)
{
    // Build Product -> InvoiceItem[] mapping
    // Key is (vendor, model, variant) tuple serialized as string
    InvoiceItem[][string] groups;
    Product[string] productsByKey;

    foreach (ref inv; invoices)
    {
        if (!invoiceMatchesCategory(inv, category))
            continue;

        auto product = extractProduct(inv, category);
        auto key = product.vendor ~ "|" ~ product.model ~ "|" ~ product.variant;

        groups[key] ~= inv;
        if (key !in productsByKey)
            productsByKey[key] = product;
    }

    // Convert to sorted array (sort by key for consistent ordering)
    auto keys = groups.keys.array;
    keys.sort();

    ProductOccurrence[] result;
    foreach (key; keys)
    {
        result ~= ProductOccurrence(
            product: productsByKey[key],
            invoices: groups[key]
        );
    }

    return result;
}

/// Extract Product from invoice item
Product extractProduct(ref InvoiceItem inv, ProductCategory category)
{
    // Strip "#ProductCode" suffix from descr48
    auto hashIdx = inv.descr48.indexOf('#');
    auto productName = hashIdx > 0 ? inv.descr48[0 .. hashIdx] : inv.descr48;

    // Remove category prefixes (PSU, Захранване, etc.)
    productName = removeCategoryPrefix(productName);

    // Extract and normalize brand (handles "Be Quiet" -> "be quiet!", etc.)
    auto brand = extractBrandFromProduct(productName);

    // Fallback: use 'mark' field if brand not found in descr48 (e.g., Zalman Reserator)
    if (brand.length == 0 && inv.mark.length > 0)
    {
        brand = extractBrandFromProduct(inv.mark);
        // If mark contains a known brand, prepend it to productName for proper model extraction
        if (brand.length > 0)
            productName = brand ~ " " ~ productName;
    }

    // If descr48 is just "Brand SKU", try to get actual model from full description
    if (brand.length > 0 && isBrandPlusSku(productName) && inv.descr.length > 0)
    {
        auto extractedModel = extractModelFromFullDescription(brand, inv.descr);
        if (extractedModel.length > 0)
            productName = brand ~ " " ~ extractedModel;
    }

    // Extract variant (BOX, Tray)
    auto variant = extractVariant(productName);

    // Clean the product name to get the model
    auto model = removeVariantFromModel(productName);
    model = removeSkuSuffix(model);

    // Category-specific normalization
    if (category == ProductCategory.RAM)
        model = normalizeRamSpecs(model, inv.descr);
    else
        model = normalizeCapacity(model);

    // Remove brand from model if present (to avoid "Intel Intel Core i9" or "Разклонител HAMA 47631")
    if (brand.length > 0)
    {
        import std.regex : replaceAll, regex, escaper;
        import std.string : replace;
        import std.array : array;
        import std.utf : byChar;

        // Escape regex special characters in brand name (e.g., "be quiet!" -> "be quiet\!")
        string escapedBrand = escaper(brand).byChar.array.idup;

        // Remove brand (case-insensitive) - use word boundary at start, flexible at end
        // This handles brands ending in non-word chars like "be quiet!"
        auto brandRx = regex(`\b` ~ escapedBrand ~ `(?:\s|$)`, "i");
        model = model.replaceAll(brandRx, " ");

        // Also remove brand aliases (from AllBrands definition)
        foreach (alias_; getBrandAliases(brand))
        {
            string escapedAlias = escaper(alias_).byChar.array.idup;
            auto aliasRx = regex(`\b` ~ escapedAlias ~ `(?:\s|$)`, "i");
            model = model.replaceAll(aliasRx, " ");
        }

        model = model.replace("  ", " ").strip;
    }

    // Remove Bulgarian words from model
    model = removeBulgarianWords(model);

    return Product(
        category: category,
        vendor: brand,
        model: model.strip,
        variant: variant,
        sn: inv.sn,
    );
}

/// Remove common Bulgarian words from model names
string removeBulgarianWords(string model)
{
    import std.regex : ctRegex, replaceAll;
    import std.string : strip;

    // Bulgarian color words (black, white, grey)
    enum colorRx = ctRegex!(`\s+(черна|черен|бяла|бял|сива|сив|бяло|черно)\b`, "i");
    // Bulgarian words for power strip parts (sockets, Schuko, etc.)
    enum powerStripRx = ctRegex!(`\s*(Шуко|Евро|букси|гнезда|без\s+бу\w*|,\s*\d+м|Разклонител)\b`, "i");
    // Trailing punctuation and truncated words
    enum trailingCyrillicRx = ctRegex!(`\s+[А-Яа-я]$|,\s*$`);
    // Multiple spaces
    enum multiSpaceRx = ctRegex!(`\s{2,}`);

    auto result = model;
    result = result.replaceAll(colorRx, "");
    result = result.replaceAll(powerStripRx, "");
    result = result.replaceAll(trailingCyrillicRx, "");
    result = result.replaceAll(multiSpaceRx, " ");
    return result.strip;
}

/// Normalize capacity: move to end, convert 1024GB -> 1TB
string normalizeCapacity(string model)
{
    import std.regex : ctRegex, matchFirst, replaceFirst;
    import std.string : toUpper, endsWith, replace;

    enum capacityRx = ctRegex!(`\b(\d+)\s*(TB|GB)\b`, "i");
    auto capMatch = model.matchFirst(capacityRx);

    if (capMatch.empty)
        return model;

    int amount = capMatch[1].to!int;
    string unit = capMatch[2].toUpper;

    // Normalize: 1024GB -> 1TB, 2048GB -> 2TB
    if (unit == "GB" && amount >= 1000 && amount % 1024 == 0)
    {
        amount = amount / 1024;
        unit = "TB";
    }

    string capacity = amount.to!string ~ unit;

    // Remove from current position, append at end
    auto result = model.replaceFirst(capacityRx, "")
        .replace("  ", " ")
        .strip;

    if (!result.toUpper.endsWith(capacity))
        result = result ~ " " ~ capacity;

    return result;
}

/// Normalize RAM specs: extract capacity, DDR gen, and speed into consistent format
/// Output format: "[Model] [Capacity] [DDR-Speed]" e.g., "FURY Beast Black 2x32GB DDR5-6000"
/// If descr is provided, specs can be extracted from there when not found in model
string normalizeRamSpecs(string model, string descr = "")
{
    import std.regex : ctRegex, matchFirst, matchAll, replaceAll;
    import std.string : toUpper, replace, strip;
    import std.conv : to;
    import std.algorithm : map, maxElement;
    import std.array : array, join;

    // Patterns for extraction
    enum configCapacityRx = ctRegex!(`\b(\d+)\s*x\s*(\d+)\s*GB\b`, "i");  // 2x32GB, 4x32GB
    enum simpleCapacityRx = ctRegex!(`\b(\d+)\s*GB\b`, "i");               // 64GB, 16GB
    enum ddrGenRx = ctRegex!(`\bDDR([45])\b`, "i");                        // DDR4, DDR5
    enum speedMhzRx = ctRegex!(`\b(\d{4,})\s*MH?z\b`, "i");               // 6000MHz, 5600Mhz
    enum speedMtsRx = ctRegex!(`\b(\d{4,})\s*MT/s\b`, "i");               // 5600MT/s
    // ValueRAM SKU pattern: KVR[speed][type][cas][config]-[size]
    // e.g., KVR56S46BD8-48 = 5600MT/s SO-DIMM 48GB
    enum valueRamRx = ctRegex!(`\bKVR(\d{2})([SU])(\d{2})[A-Z0-9]+-(\d+)\b`, "i");
    // Kit configuration in description: "(2x 32GB)" or "(4x 32GB)"
    enum descrKitRx = ctRegex!(`\((\d+)\s*x\s*(\d+)\s*GB\)`, "i");
    // Empty parens and artifacts
    enum emptyParensRx = ctRegex!(`\(\s*\)`, "i");
    enum truncatedDdr = ctRegex!(`\s+D$|\s+D\s+`, "i");  // Truncated "DDR" at end or standalone
    enum multiSpace = ctRegex!(`\s{2,}`);

    string result = model;
    string capacity = "";
    string ddrGen = "";
    string speed = "";

    // Check for ValueRAM SKU first (decode specs from SKU)
    auto valueRamMatch = result.matchFirst(valueRamRx);
    if (!valueRamMatch.empty)
    {
        // Decode ValueRAM SKU
        int speedCode = valueRamMatch[1].to!int * 100;  // 56 -> 5600
        string memType = valueRamMatch[2].toUpper == "S" ? "SO-DIMM" : "";
        int size = valueRamMatch[4].to!int;

        capacity = size.to!string ~ "GB";
        ddrGen = "DDR5";  // Modern ValueRAM is DDR5
        speed = speedCode.to!string;

        // Replace SKU with readable name
        result = "ValueRAM" ~ (memType.length > 0 ? " " ~ memType : "");
    }
    else
    {
        // First, try to get kit configuration from description (more reliable)
        // e.g., "Памет 64GB (2x 32GB) DDR5" -> "2x32GB"
        if (descr.length > 0)
        {
            auto descrKitMatch = descr.matchFirst(descrKitRx);
            if (!descrKitMatch.empty)
            {
                int sticks = descrKitMatch[1].to!int;
                int perStick = descrKitMatch[2].to!int;
                capacity = sticks.to!string ~ "x" ~ perStick.to!string ~ "GB";
            }
        }

        // Extract config capacity from model (2x32GB, 4x32GB) if not found in descr
        auto configMatch = result.matchFirst(configCapacityRx);
        if (!configMatch.empty)
        {
            if (capacity.length == 0)
            {
                int sticks = configMatch[1].to!int;
                int perStick = configMatch[2].to!int;
                capacity = sticks.to!string ~ "x" ~ perStick.to!string ~ "GB";
            }
        }
        // Always remove all config capacity patterns
        result = result.replaceAll(configCapacityRx, "");

        // Extract simple capacity (use largest if multiple found)
        auto capMatches = result.matchAll(simpleCapacityRx).map!(m => m[1].to!int).array;
        if (capMatches.length > 0)
        {
            int maxCap = capMatches.maxElement;
            // Only use simple capacity if we didn't find config capacity
            if (capacity.length == 0)
                capacity = maxCap.to!string ~ "GB";
        }
        // Always remove all simple capacity patterns
        result = result.replaceAll(simpleCapacityRx, "");

        // Extract DDR generation from model
        auto ddrMatch = result.matchFirst(ddrGenRx);
        if (!ddrMatch.empty)
            ddrGen = "DDR" ~ ddrMatch[1];
        result = result.replaceAll(ddrGenRx, "");

        // Extract speed from model (MHz or MT/s)
        auto speedMhz = result.matchFirst(speedMhzRx);
        auto speedMts = result.matchFirst(speedMtsRx);
        if (!speedMhz.empty)
            speed = speedMhz[1];
        else if (!speedMts.empty)
            speed = speedMts[1];
        result = result.replaceAll(speedMhzRx, "");
        result = result.replaceAll(speedMtsRx, "");

        // If specs not found in model, try to extract from description
        if (descr.length > 0)
        {
            if (ddrGen.length == 0)
            {
                auto descrDdr = descr.matchFirst(ddrGenRx);
                if (!descrDdr.empty)
                    ddrGen = "DDR" ~ descrDdr[1];
            }
            if (speed.length == 0)
            {
                auto descrSpeedMts = descr.matchFirst(speedMtsRx);
                auto descrSpeedMhz = descr.matchFirst(speedMhzRx);
                if (!descrSpeedMts.empty)
                    speed = descrSpeedMts[1];
                else if (!descrSpeedMhz.empty)
                    speed = descrSpeedMhz[1];
            }
            if (capacity.length == 0)
            {
                auto descrCap = descr.matchFirst(simpleCapacityRx);
                if (!descrCap.empty)
                    capacity = descrCap[1] ~ "GB";
            }
        }
    }

    // Clean up artifacts
    result = result.replaceAll(emptyParensRx, "");   // Remove "()"
    result = result.replaceAll(truncatedDdr, " ");   // Remove truncated "D" from DDR
    result = result.replaceAll(multiSpace, " ");     // Collapse spaces
    result = result.strip;

    // Remove trailing/leading parens
    while (result.length > 0 && (result[$ - 1] == '(' || result[$ - 1] == ')'))
        result = result[0 .. $ - 1].strip;
    while (result.length > 0 && (result[0] == '(' || result[0] == ')'))
        result = result[1 .. $].strip;

    // Build final format: [Model] [Capacity] [DDR-Speed]
    string[] specs;
    if (capacity.length > 0)
        specs ~= capacity;
    if (ddrGen.length > 0 && speed.length > 0)
        specs ~= ddrGen ~ "-" ~ speed;
    else if (ddrGen.length > 0)
        specs ~= ddrGen;
    else if (speed.length > 0)
        specs ~= speed ~ "MHz";

    if (specs.length > 0 && result.length > 0)
        return result ~ " " ~ specs.join(" ");
    else if (specs.length > 0)
        return specs.join(" ");

    return result;
}

/// Format date (extract YYYY-MM-DD from Date or use Date.toISOExtString)
string formatDate(Date date)
{
    import std.datetime : Date;
    return date == Date.init ? "" : date.toISOExtString();
}

/// Extract invoice number from filename or purchasedbid
string extractInvoiceItemNumber(string filename, string purchasedbid)
{
    // Try to extract from filename (e.g., "2023-01-03 2344304.csv" -> "2344304")
    auto base = baseName(filename);
    auto spaceIdx = base.indexOf(" ");
    if (spaceIdx > 0)
    {
        auto dotIdx = base.indexOf(".");
        if (dotIdx > spaceIdx)
            return base[spaceIdx + 1 .. dotIdx];
    }
    return purchasedbid;
}
