module mcl.commands.invoice_heuristics;

import std.meta : AliasSeq;

import mcl.utils.heuristics;

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
    P!(`CNCP|CAVM`, "Cable"),
    P!(`NTRF`, "Rack"),
    P!(`ACCN`, "Bag"),
    P!(`UR[ROKA][OLAH]?`, "PowerStrip"),

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

    // Standalone (not tied to hosts)
    Cat!("UPS", CategoryType.standalone),
    Cat!("Switch", CategoryType.standalone),
    Cat!("Cable", CategoryType.standalone),
    Cat!("Rack", CategoryType.standalone),
    Cat!("Bag", CategoryType.standalone),
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
    W!"ASROCK",
    W!"ASUS",
    W!"MSI",
    W!"GIGABYTE",
    W!"EVGA",
    W!"ZOTAC",
    W!"PALIT",
    W!"PNY",
    W!"SAPPHIRE",
    W!"POWERCOLOR",
    W!"XFX",

    // Memory/Storage
    W!"CORSAIR",
    W!("G.SKILL", "GSKILL"),
    W!"KINGSTON",
    W!"CRUCIAL",
    W!"TEAMGROUP",
    W!"LEXAR",
    W!("A-DATA", "ADATA"),
    W!"SAMSUNG",
    W!("WESTERN DIGITAL", "WD"),
    W!"WD",
    W!"SEAGATE",
    W!"TOSHIBA",
    W!"HYNIX",
    W!("SILICON POWER", "SILICONPOWER"),

    // Cooling
    W!"NOCTUA",
    W!("BE QUIET", "BEQUIET"),
    W!("COOLER MASTER", "COOLERMASTER"),
    W!"ZALMAN",
    W!"ARCTIC",
    W!"DEEPCOOL",
    W!"EKWB",

    // Cases/PSU
    W!"SEASONIC",
    W!"THERMALTAKE",
    W!"NZXT",
    W!"FRACTAL",
    W!("LIAN LI", "LIANLI"),
    W!"PHANTEKS",

    // Peripherals
    W!"LOGITECH",
    W!"RAZER",
    W!"STEELSERIES",
    W!"HYPERX",
    W!"DUCKY",
    W!"GLORIOUS",

    // Monitors/OEM
    W!"DELL",
    W!"LG",
    W!"BENQ",
    W!"ACER",
    W!"VIEWSONIC",
    W!"AOC",
    W!"FUJITSU",

    // Contextual brands (checked only if not in compatibility context)
    W!"INTEL",
    W!"AMD",
    W!"NVIDIA",
);

alias ExtractBrand = BrandExtractor!AllBrands;

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
// Unified API Functions (for backward compatibility)
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
