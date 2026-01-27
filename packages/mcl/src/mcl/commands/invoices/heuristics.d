module mcl.commands.invoices.heuristics;

import std.meta : AliasSeq;

import mcl.utils.heuristics;
import mcl.commands.invoices.types : ProductCategory;

// =============================================================================
// Category Extraction from JAR Product Codes
// =============================================================================

/// Extract category from JAR product code prefix
/// e.g., "SSDSAMSUNGMZV8P2T0BW" -> "SSD", "CPUPINTELI912900K" -> "CPU"
alias CategoryFromCode = RuleSet!(
    // CPU
    P!(`CPU[PA]`, "CPU"),

    // Motherboard (various Intel/AMD prefixes)
    P!(`MB[IA][AGIM]`, "MB"),
    P!(`MBA[AG]`, "MB"),

    // RAM
    P!(`MRAM`, "RAM"),
    P!(`MSOD`, "RAM"),  // SO-DIMM

    // Storage
    P!(`SSD[SKLA]?`, "SSD"),
    P!(`HDD[P]?`, "HDD"),

    // GPU
    P!(`VCR[F]?`, "GPU"),

    // Cooling
    P!(`FAN[CN]?`, "Fan"),

    // Power
    P!(`PWR[P]?`, "PSU"),

    // Case
    P!(`CASE`, "Case"),

    // Peripherals
    P!(`KB[DULRCSHA]`, "Keyboard"),
    P!(`MO[LRAS]|MOA4`, "Mouse"),
    P!(`MN[LC]?`, "Monitor"),
    P!(`FWEB`, "Webcam"),
    P!(`MULH`, "Headphones"),
    P!(`MOP[LGR]`, "Pad"),

    // Standalone
    P!(`UPS[CP]?`, "UPS"),
    P!(`NTLH|SWTP`, "Switch"),
    P!(`CNCP|CAVM|CCBCN`, "Cable"),  // CCBCN for cable channels (Elmark)
    P!(`NTRF`, "Rack"),
    P!(`ACCN`, "Backpack"),
    P!(`UR[A-Z]`, "PowerStrip"),  // UREATON, URHAMA, URPHILIPS, URVALVNOS

    // Computer accessories
    P!(`DSM[A-Z]`, "DockingStation"),  // j5create docking stations
    P!(`OTHN`, "LaptopStand"),          // NewStar laptop stands

    // Mobile devices
    P!(`TKGSM`, "Smartphone"),          // Samsung/other smartphones

    // Ignored
    P!(`USL[AR]`, "Service"),
    P!(`_AVA`, "Advance"),
    P!(`_PC_`, "Bundle"),
    P!(`_OTH`, "Other"),
    P!(`XXXX`, "Shipping"),
);

// =============================================================================
// Category Classification
// =============================================================================

alias Categories = CategoryClassifier!(
    // Auto-matchable to hosts
    Cat!("CPU", CategoryType.autoMatch),
    Cat!("MB", CategoryType.autoMatch),
    Cat!("RAM", CategoryType.autoMatch),
    Cat!("SSD", CategoryType.autoMatch),
    Cat!("HDD", CategoryType.autoMatch),
    Cat!("GPU", CategoryType.autoMatch),
    Cat!("Fan", CategoryType.autoMatch),
    Cat!("PSU", CategoryType.autoMatch),
    Cat!("Case", CategoryType.autoMatch),

    // Peripherals (manual matching)
    Cat!("Keyboard", CategoryType.peripheral),
    Cat!("Mouse", CategoryType.peripheral),
    Cat!("Monitor", CategoryType.peripheral),
    Cat!("Webcam", CategoryType.peripheral),
    Cat!("Headphones", CategoryType.peripheral),
    Cat!("DockingStation", CategoryType.peripheral),
    Cat!("LaptopStand", CategoryType.peripheral),

    // Standalone (not tied to hosts)
    Cat!("UPS", CategoryType.standalone),
    Cat!("Switch", CategoryType.standalone),
    Cat!("Cable", CategoryType.standalone),
    Cat!("Rack", CategoryType.standalone),
    Cat!("Backpack", CategoryType.standalone),
    Cat!("PowerStrip", CategoryType.standalone),
    Cat!("Pad", CategoryType.standalone),

    // Ignored
    Cat!("Service", CategoryType.ignored),
    Cat!("Advance", CategoryType.ignored),
    Cat!("Bundle", CategoryType.ignored),
    Cat!("Other", CategoryType.ignored),
    Cat!("Shipping", CategoryType.ignored),
);

// =============================================================================
// Category Matching (Part Name -> Invoice Category)
// =============================================================================

alias CategoryMatch = CategoryMatcher!(
    Equiv!("cpu", `cpu`),
    Equiv!("mb", `mb|motherboard|mainboard`),
    Equiv!("ram", `ram|memory|ddr`),
    Equiv!("ssd", `ssd|disk|drive|nvme`),
    Equiv!("hdd", `hdd|disk|drive`),
    Equiv!("gpu", `gpu|video|graphics|vga`),
    Equiv!("keyboard", `kbd|keyboard`),
    Equiv!("mouse", `mouse|mice`),
    Equiv!("webcam", `camera|webcam`),
    Equiv!("monitor", `monitor|display`),
);

// =============================================================================
// Brand Extraction from Product Descriptions
// =============================================================================

/// All brands (primary + contextual combined, contextual checked last)
alias AllBrands = AliasSeq!(
    // Motherboard/GPU manufacturers
    W!"ASRock",
    W!"ASUS",
    W!"MSI",
    W!"Gigabyte",
    W!"EVGA",
    W!"Zotac",
    W!"Palit",
    W!"PNY",
    W!"Sapphire",
    W!"PowerColor",
    W!"XFX",

    // Memory/Storage
    W!"Corsair",
    W!("G.Skill", "GSKILL"),
    W!("Kingston", "Kinston"),  // Kinston is common typo
    W!"Crucial",
    W!"TeamGroup",
    W!"Lexar",
    W!("A-DATA", "ADATA"),
    W!"Samsung",
    W!("Western Digital", "WD"),
    W!"Seagate",
    W!"Toshiba",
    W!"Hynix",
    W!("Silicon Power", "SILICONPOWER", "SPCC"),

    // Cooling
    W!"Noctua",
    W!("be quiet!", "BE QUIET", "BEQUIET"),
    W!("Cooler Master", "COOLERMASTER"),
    W!"Zalman",
    W!"Arctic",
    W!"DeepCool",
    W!"EKWB",

    // Cases/PSU
    W!"Seasonic",
    W!"Thermaltake",
    W!"NZXT",
    W!("Fractal Design", "FRACTAL"),
    W!("Lian Li", "LIANLI"),
    W!"Phanteks",
    W!"1stPlayer",
    W!"Chieftec",

    // Peripherals
    W!"Logitech",
    W!"Razer",
    W!"SteelSeries",
    W!"HyperX",
    W!"Ducky",
    W!"Glorious",
    W!"Macally",
    W!"Apple",
    W!"Jabra",
    W!"beyerdynamic",
    W!"Sennheiser",
    W!"Sandberg",
    W!"CHERRY",
    W!("A4Tech", "A4"),

    // Monitors/OEM
    W!"Dell",
    W!"LG",
    W!"BenQ",
    W!"Acer",
    W!"ViewSonic",
    W!"AOC",
    W!"Fujitsu",
    W!"Iiyama",

    // UPS/Power
    W!"CyberPower",
    W!"Eaton",
    W!"PowerWalker",
    W!"APC",
    W!"Allocacoc",
    W!"ROLINE",
    W!"HAMA",
    W!"Philips",
    W!"VALVNOS",
    W!"Okoffice",

    // Network/Cables
    W!"Cisco",
    W!("TP-Link", "TPLINK"),
    W!"Ubiquiti",
    W!"VCom",
    W!"Vention",

    // Accessories/Other
    W!"j5create",
    W!"NewStar",
    W!"Xiaomi",
    W!"Genesis",
    W!("Dark Project", "DARKPROJECT"),
    W!"Elmark",
    W!("Urban Explorer", "URBANEXPLORER"),

    // Contextual brands (checked only if not in compatibility context)
    W!"Intel",
    W!"AMD",
    W!"NVIDIA",
);

alias ExtractBrand = BrandExtractor!AllBrands;

/// Get all aliases for a brand name (from AllBrands)
/// Used for removing brand aliases from model names
string[] getBrandAliases(string brand)
{
    import std.string : toLower;

    string[] aliases;
    static foreach (Rule; AllBrands)
    {
        if (Rule.displayName.toLower == brand.toLower)
            aliases = Rule.getAllAliases();
    }
    return aliases;
}

// =============================================================================
// Brand Normalization
// =============================================================================

alias NormalizeBrand = AliasResolver!(
    Alias!("msi", `micro-star.*`, `msi`),
    Alias!("siliconpower", `silicon\s*power`, `spcc`),
    Alias!("wd", `western\s*digital`),
    Alias!("gskill", `g\.?\s*skill`),
    Alias!("adata", `a-?data`),
    Alias!("bequiet", `be\s*quiet`),
    Alias!("coolermaster", `cooler\s*master`),
    Alias!("lianli", `lian\s*li`),
);

// =============================================================================
// Brand Matching
// =============================================================================

alias BrandMatch = AnyMatcher!(
    ExactMatcher!NormalizeBrand,
    ContainsMatcher!NormalizeBrand,
);

// =============================================================================
// Serial Number Normalization & Matching
// =============================================================================

alias NormalizeSerial = RegexNormalizer!(
    Repl!(`^JAR`),           // Remove JAR prefix
    Repl!(`^S(?=.{10,})`),   // Remove leading S if long enough
    Repl!(`N$(?<=.{10,})`),  // Remove trailing N if long enough
    Repl!(`\s+`),            // Remove whitespace
);

alias SerialMatch = AnyMatcher!(
    ExactMatcher!NormalizeSerial,
    SuffixMatcher!(NormalizeSerial, 6),
    ContainsMatcher!NormalizeSerial,
);

// =============================================================================
// Model Token Extraction
// =============================================================================

/// Noise words to filter from model tokens
alias ModelNoiseFilter = NoiseFilter!(
    "USB", "RECEIVER", "KEYBOARD", "MOUSE", "GAMING", "RGB",
    "GEN", "INTEL", "AMD", "CORE", "RYZEN", "PRO", "PLUS",
    "EDITION", "SERIES", "VERSION"
);

alias ModelTokens = TokenExtractor!(
    ModelNoiseFilter,

    // Critical patterns (must match)
    Crit!(`\b(\d{4,5}[A-Z]*\d*[A-Z]*)\b`),              // CPU SKU: 13900K, 7950X, 5800X3D
    Crit!(`\b(RTX|GTX|RX)?\s*(\d{4})\s*(TI|XT|XTX|SUPER)?\b`, [2, 3]),  // GPU: 4090, 3080TI
    Crit!(`\b(CT\d+P\d+[A-Z]*SSD\d*)\b`),               // Crucial SSD
    Crit!(`\b(MZ-?[A-Z0-9]+)\b`),                        // Samsung SSD
    Crit!(`\b(SKC\d+[A-Z]*\d*)\b`),                      // Kingston SSD
    Crit!(`\b(NM\d+)\b`),                                // Lexar SSD

    // Soft patterns (supplementary)
    Soft!(`\b(I[3579])\b`),                              // CPU tier: i3, i5, i7, i9
    Soft!(`\b(RTX|GTX|RX|RADEON|GEFORCE)\b`),           // GPU family
    Soft!(`\b([A-Z][A-Z0-9]{2,})\b`),                    // General product codes
);

// =============================================================================
// Model Normalization
// =============================================================================

alias NormalizeModel = RegexNormalizer!(
    // Remove trademark symbols
    Repl!(`\(R\)|\(TM\)|®|™`),

    // Remove CPU frequency info
    Repl!(`\s*(CPU)?\s*@\s*\d+\.?\d*\s*GHZ`),

    // Remove common noise prefixes
    Repl!(`\bINTEL\b`),
    Repl!(`\bAMD\b`),
    Repl!(`\bCORE\b`),
    Repl!(`\bRYZEN\b`),

    // Remove generation prefixes
    Repl!(`\b\d{1,2}TH\s+GEN\b`),

    // Remove separators for final comparison
    Repl!(`[\s\-_]`),
);

// =============================================================================
// Model Matching
// =============================================================================

alias ModelMatch = AnyMatcher!(
    ExactMatcher!NormalizeModel,
    ContainsMatcher!NormalizeModel,
    TokenMatcher!ModelTokens,
);

// =============================================================================
// API Functions
// =============================================================================

/// Extract category from JAR product code
string categoryFromCode(string code)
{
    return CategoryFromCode.eval(code);
}

/// Check if category is auto-matchable
bool isAutoMatchCategory(string category)
{
    return Categories.isAutoMatch(category);
}

/// Check if category is a peripheral
bool isPeripheralCategory(string category)
{
    return Categories.isPeripheral(category);
}

/// Check if category is standalone
bool isStandaloneCategory(string category)
{
    return Categories.isStandalone(category);
}

/// Check if category should be ignored
bool isIgnoredCategory(string category)
{
    return Categories.isIgnored(category);
}

/// Check if part category matches invoice category
bool categoriesMatch(string partCat, string invoiceCat)
{
    return CategoryMatch.match(partCat, invoiceCat);
}

/// Extract brand from product description
string extractBrandFromProduct(string product)
{
    return ExtractBrand.eval(product);
}

/// Normalize brand name
string normalizeBrand(string brand)
{
    return NormalizeBrand.eval(brand);
}

/// Check if brands match
bool brandsMatch(string brand1, string brand2)
{
    return BrandMatch.match(brand1, brand2);
}

/// Normalize serial number
string normalizeSerial(string sn)
{
    if (sn.length == 0)
        return "";
    return NormalizeSerial.eval(sn);
}

/// Check if serial numbers match
bool serialsMatch(string sn1, string sn2)
{
    return SerialMatch.match(sn1, sn2);
}

/// Normalize model string
string normalizeModel(string model)
{
    return NormalizeModel.eval(model);
}

/// Check if models match
bool modelsMatch(string model1, string model2)
{
    return ModelMatch.match(model1, model2);
}

/// Check if model matches product description (for aggregate invoices)
bool modelsMatchProduct(string model, string product)
{
    // Same as modelsMatch but could have specialized logic
    return modelsMatch(model, product);
}

// =============================================================================
// Product Category Matching (for list command)
// =============================================================================

/// Patterns for matching user input to ProductCategory
alias ProductCategoryMatch = RuleSet!(
    // Core components
    P!(`cpu`, "CPU"),
    P!(`mb|motherboard|mainboard`, "MB"),
    P!(`ram|memory|ddr`, "RAM"),
    P!(`ssd|nvme`, "SSD"),
    P!(`hdd|hard\s*drive`, "HDD"),
    P!(`gpu|video|graphics|vga`, "GPU"),
    P!(`fan|cool`, "Fan"),
    P!(`psu|power\s*supply`, "PSU"),
    P!(`case|chassis`, "Case"),

    // Peripherals
    P!(`keyboard|kbd`, "Keyboard"),
    P!(`mouse|mice`, "Mouse"),
    P!(`monitor|display|screen`, "Monitor"),
    P!(`webcam|camera`, "Webcam"),
    P!(`headphone|headset`, "Headphones"),
    P!(`docking|dock`, "DockingStation"),
    P!(`laptop\s*stand|stand`, "LaptopStand"),
    P!(`backpack|bag|раница`, "Backpack"),

    // Mobile/Other
    P!(`smartphone|phone|gsm|mobile`, "Smartphone"),
    P!(`cable|cord`, "Cable"),
    P!(`ups`, "UPS"),
    P!(`power\s*strip|surge\s*protector|extension`, "PowerStrip"),
    P!(`switch|hub`, "Switch"),
    P!(`service|услуг`, "Services"),
    P!(`other`, "Other"),
);

/// Patterns for matching invoice 'name' field to category
alias InvoiceNameMatch = RuleSet!(
    // Core components
    C!(`^cpu$`, "CPU"),
    C!(`^mb$|motherboard|mainboard|дънна`, "MB"),
    C!(`^ram`, "RAM"),  // Matches "RAM", "RAM 16GB", etc.
    C!(`^ssd$|nvme`, "SSD"),
    C!(`^hdd$|hard\s*drive`, "HDD"),
    C!(`^gpu$|^svga|video.*card|graphics`, "GPU"),  // Added SVGA
    C!(`^fan$|охлажд|cooler`, "Fan"),
    C!(`power\s*supply|захранване`, "PSU"),
    C!(`^case$|кутия`, "Case"),

    // Peripherals
    C!(`^kbd$|keyboard|клавиатура`, "Keyboard"),  // Added KBD
    C!(`^mouse$|^pad$|мишка`, "Mouse"),  // Added Pad (mouse pad)
    C!(`^monitor`, "Monitor"),  // Matches "Monitor", "Monitor 27\"", etc.
    C!(`^camera$|webcam|уеб.*камера`, "Webcam"),  // Added Camera
    C!(`headphone|слушалк`, "Headphones"),

    // Computer accessories
    C!(`^чанта$|раница|backpack`, "Backpack"),
    C!(`докинг|docking`, "DockingStation"),
    C!(`стойка.*лаптоп|laptop.*stand`, "LaptopStand"),

    // Infrastructure
    C!(`^cable$|кабел`, "Cable"),
    C!(`^lan$`, "Cable"),  // LAN cables -> Cable
    C!(`^ups$`, "UPS"),
    C!(`разклонител|power\s*strip`, "PowerStrip"),
    C!(`^switch$|комутатор`, "Switch"),
    C!(`услуг|service`, "Services"),

    // Mobile devices
    C!(`^gsm$|смартфон|телефон`, "Smartphone"),

    // Catch-all for unrecognized (Computer, Multimedia, Toner, etc.)
    C!(`^computer$|^multimedia$|^toner$|^other$`, "Other"),
);

/// Match user input to ProductCategory, returns null if no match
import std.typecons : Nullable, nullable;

Nullable!ProductCategory matchProductCategory(string input)
{
    import std.string : strip, toLower;
    import std.conv : to;
    import std.traits : EnumMembers;

    auto normalized = input.toLower.strip;

    // Try exact enum name match first
    static foreach (cat; EnumMembers!ProductCategory)
    {
        if (normalized == cat.to!string.toLower)
            return nullable(cat);
    }

    // Try fuzzy pattern match
    auto matched = ProductCategoryMatch.eval(normalized);
    if (matched.length > 0)
    {
        static foreach (cat; EnumMembers!ProductCategory)
        {
            if (matched == cat.to!string)
                return nullable(cat);
        }
    }

    return Nullable!ProductCategory.init;
}

/// Check if invoice name field matches a category
bool invoiceNameMatchesCategory(string invoiceName, ProductCategory category)
{
    import std.string : strip, toLower;
    import std.conv : to;

    auto name = invoiceName.toLower.strip;
    auto catStr = category.to!string;

    // Check exact match
    if (name == catStr.toLower)
        return true;

    // Check pattern match
    auto matched = InvoiceNameMatch.eval(name);
    return matched == catStr;
}

// =============================================================================
// Model Name Cleaning (for list command)
// =============================================================================

/// Extract variant from model string (BOX, Tray)
alias VariantExtractor = RuleSet!(
    C!(`\bBOX\b`, "BOX"),
    C!(`\bTRAY\b`, "Tray"),
);

/// Detect if Intel box SKU present (for implicit BOX variant)
alias HasIntelBoxSku = RuleSet!(
    C!(`\bBX\d{10,}`, "BOX"),
);

/// Check if string looks like a description (Cyrillic or common prefixes)
alias IsDescription = RuleSet!(
    C!(`[\u0400-\u04FF]`, "cyrillic"),
    P!(`Памет|Процесор|Видео|Охлаждане|Захранване|Дънна`, "prefix"),
);

/// Check if string starts with a manufacturer SKU (may have extra text after)
alias StartsWithSku = RuleSet!(
    // SKUs with dash/slash separators (ASD600Q-960GU31-CBK, MZ-V8P2T0BW, SKC3000S/1024G)
    P!(`[A-Z0-9]+[-/][A-Z0-9]+[-/]?[A-Z0-9]*(\s|$)`, "sku-segmented"),
    // Simple SKUs without separators (MZV8P2T0BW)
    P!(`[A-Z]{2,4}[A-Z0-9]{6,}(\s|$)`, "sku-simple"),
);

/// Check if product name is just "Brand SKU" (e.g., "Logitech 920-009800")
/// These need model extraction from full description
alias IsBrandPlusSku = RuleSet!(
    // Brand followed by numeric SKU pattern (920-009800)
    C!(`^\w+\s+\d{3}-\d{6,}`, "brand-sku-dash"),
    // Brand followed by alphanumeric SKU (RZ03-03380100-R3M1)
    C!(`^\w+\s+[A-Z]{2}\d{2}-`, "brand-sku-prefix"),
    // Brand followed by letter-dash-number SKU (CP-9020234-EU)
    C!(`^\w+\s+[A-Z]{2}-\d{5,}`, "brand-sku-letter-dash"),
    // Samsung SSD SKUs (MZ-V8P2T0BW, MZ-77Q4T0BW)
    C!(`^\w+\s+MZ-[A-Z0-9]+$`, "brand-samsung-sku"),
    // Kingston SSD SKUs (SKC3000D, SKC3000S/1024G)
    C!(`^\w+\s+SKC\d+[A-Z]*`, "brand-kingston-sku"),
    // Corsair RAM SKUs (CMK32GX4M2E3200C16)
    C!(`^\w+\s+CM[A-Z0-9]+$`, "brand-corsair-ram-sku"),
    // Kingston FURY RAM SKUs (KF560C36BBK2-64, KF556C40BBK2-64, KF432C16BBK2/64)
    C!(`^\w+\s+KF\d+C\d+[A-Z0-9\-/]*$`, "brand-kingston-fury-sku"),
    // Note: ValueRAM SKUs (KVR...) are NOT included here - the SKU *is* the product name
);

// =============================================================================
// Model Name Cleaning API Functions
// =============================================================================

/// Extract variant (BOX, Tray) from string
string extractVariant(string s)
{
    return VariantExtractor.eval(s);
}

/// Check if model contains Intel box SKU (implies BOX variant)
bool hasIntelBoxSku(string model)
{
    return HasIntelBoxSku.matches(model);
}

/// Remove variant keywords from model (preserves case)
string removeVariantFromModel(string model)
{
    import std.regex : ctRegex, replaceAll;
    import std.string : strip;

    auto result = model;
    // Remove all BOX/TRAY occurrences (handles "BOX BOX" cases)
    enum boxRx = ctRegex!(`\s+BOX\b`, "i");
    enum trayRx = ctRegex!(`\s+TRAY\b`, "i");
    result = result.replaceAll(boxRx, "");
    result = result.replaceAll(trayRx, "");
    return result.strip;
}

/// Remove SKU suffixes from model (preserves case)
string removeSkuSuffix(string model)
{
    import std.regex : ctRegex, replaceAll;
    import std.string : strip;

    auto result = model;
    // Intel box SKU suffixes (BX8071513900K)
    enum intelSkuRx = ctRegex!(`\s+BX\d{10,}[A-Z]*\s*$`, "i");
    // AMD product codes (100-100000059WOF) - can appear anywhere, not just at end
    enum amdSkuRx = ctRegex!(`\s+100-\d+[A-Z]*\b`, "i");
    // Samsung SSD SKUs (MZ-V8P2T0BW, MZ-77Q4T0BW) - can appear anywhere
    enum samsungSkuRx = ctRegex!(`\s+MZ-[A-Z0-9]+\b`, "i");
    // Kingston SSD SKUs (SKC3000D, SKC3000S)
    enum kingstonSsdSkuRx = ctRegex!(`\s+SKC\d+[A-Z]*\b`, "i");
    // Kingston FURY RAM SKUs (KF560C36, KF556C3, KF560C40, KF432C16BBK2/64)
    enum kingstonFurySkuRx = ctRegex!(`\s+KF\d+C\d*[A-Z0-9/\-]*\b`, "i");
    // Note: ValueRAM SKUs (KVR...) are NOT removed - the SKU *is* the product name
    // Corsair RAM SKUs (CMK32GX4M2E3200C16)
    enum corsairRamSkuRx = ctRegex!(`\s+CM[A-Z]\d+[A-Z0-9]+\b`, "i");
    // Trailing storage SKUs with capacity (SKC3000S/1024G, SA400S37/480G)
    // Requires: known storage prefix + digits + "/" + capacity (3+ digits + G)
    // This avoids stripping model names like "QP230/50" or "HA-1300BA3"
    enum trailingStorageSkuRx = ctRegex!(`\s+(?:SKC|SA\d{3})[A-Z0-9]+/\d{3,}G\s*$`, "i");
    // Corsair-style SKU suffixes (CP-9020234-EU, CP-9020279-EU)
    enum corsairSkuRx = ctRegex!(`\s+CP-\d+-[A-Z]{2}\s*$`, "i");
    // Razer SKU codes (RZ04-03800100-R3M1)
    enum razerSkuRx = ctRegex!(`\s+RZ\d{2}-\d+-[A-Z0-9]+\s*$`, "i");
    // Jabra SKU codes (100-55930000-60)
    enum jabraSkuRx = ctRegex!(`\s+\d{3}-\d{8,}-\d+\s*$`, "i");
    // Logitech SKU codes (981-001213, 920-009800) - can be truncated (981-00)
    enum logitechSkuRx = ctRegex!(`\s+9\d{2}-\d{2,}\s*$`, "i");
    // ASUS case/component SKUs (90DC0090-B090)
    enum asusSkuRx = ctRegex!(`\s+\d{2}[A-Z]{2}\d{4}-[A-Z]\d{3}\s*$`, "i");
    // Trailing JAR internal codes (pure numbers like 73014)
    enum trailingNumberRx = ctRegex!(`\s+\d{4,}\s*$`);
    // Double spaces
    enum doubleSpaceRx = ctRegex!(`\s{2,}`);

    result = result.replaceAll(intelSkuRx, "");
    result = result.replaceAll(amdSkuRx, "");
    result = result.replaceAll(samsungSkuRx, "");
    result = result.replaceAll(kingstonSsdSkuRx, "");
    result = result.replaceAll(kingstonFurySkuRx, "");
    result = result.replaceAll(corsairRamSkuRx, "");
    result = result.replaceAll(trailingStorageSkuRx, "");
    result = result.replaceAll(corsairSkuRx, "");
    result = result.replaceAll(razerSkuRx, "");
    result = result.replaceAll(jabraSkuRx, "");
    result = result.replaceAll(logitechSkuRx, "");
    result = result.replaceAll(asusSkuRx, "");
    result = result.replaceAll(trailingNumberRx, "");
    result = result.replaceAll(doubleSpaceRx, " ");
    return result.strip;
}

/// Remove category prefixes from product name (PSU, Захранване, etc.)
string removeCategoryPrefix(string productName)
{
    import std.regex : ctRegex, replaceFirst;
    import std.string : strip;

    auto result = productName;
    // Common category prefixes (English and Bulgarian)
    enum prefixRx = ctRegex!(`^(PSU|Switch|Захранване|Охладител|Клавиатура|Мишка|Монитор|Памет|Процесор|Слушалки|Гейминг слушалки|Разклонител|Пач кабел|Дънна платка)\s+`, "i");
    result = result.replaceFirst(prefixRx, "");
    return result.strip;
}

/// Check if string looks like a description
bool looksLikeDescription(string s)
{
    return IsDescription.matches(s);
}

/// Check if string looks like it starts with a SKU
bool looksLikePureSku(string s)
{
    import std.string : strip;
    return StartsWithSku.matches(s.strip);
}

/// Check if product name is just "Brand SKU" format
bool isBrandPlusSku(string productName)
{
    return IsBrandPlusSku.matches(productName);
}

/// Extract model name from full description when descr48 only has "Brand SKU"
/// e.g., "Logitech MK295 Silent Wireless Combo (920-009800), ..." -> "MK295 Silent Wireless Combo"
/// e.g., "Corsair RM750 (CP-9020234-EU), ..." -> "RM750"
/// e.g., "Samsung 980 PRO (MZ-V8P2T0BW), ..." -> "980 PRO"
string extractModelFromFullDescription(string brand, string descr)
{
    import std.regex : ctRegex, matchFirst, regex;
    import std.string : strip, toUpper;

    if (descr.length == 0 || brand.length == 0)
        return "";

    // Build dynamic pattern: "Brand Model (SKU)" where Brand is the extracted brand
    // Model can start with letter or digit (e.g., "980 PRO", "MK295")
    // SKU can be alphanumeric with dashes (920-009800, CP-9020234-EU, MZ-V8P2T0BW)
    auto brandPattern = brand ~ `\s+([A-Za-z0-9][A-Za-z0-9\s\-]+?)\s*\([A-Za-z0-9\-]+\)`;
    auto rx1 = regex(brandPattern, "i");
    auto m1 = descr.matchFirst(rx1);
    if (!m1.empty)
        return m1[1].strip;

    // Fallback: "Brand Model," pattern
    auto brandCommaPattern = brand ~ `\s+([A-Za-z0-9][A-Za-z0-9\s\-]+?)(?:,|\s+\()`;
    auto rx2 = regex(brandCommaPattern, "i");
    auto m2 = descr.matchFirst(rx2);
    if (!m2.empty)
        return m2[1].strip;

    return "";
}
