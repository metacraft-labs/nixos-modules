module mcl.utils.heuristics;

import std.algorithm : canFind, map, filter, min;
import std.array : array, replace;
import std.conv : to;
import std.meta : AliasSeq, staticMap, allSatisfy;
import std.regex : Regex, regex, matchFirst, matchAll, replaceAll, ctRegex;
import std.string : toLower, toUpper, startsWith, endsWith, strip;
import std.traits : Parameters, ReturnType, isCallable;

// =============================================================================
// Core Heuristic Infrastructure
// =============================================================================

/// A heuristic rule using regex pattern matching.
/// Maps input matching `pattern` to `result`.
struct Rule(string pattern_, string result_)
{
    enum pattern = pattern_;
    enum result = result_;

    // Compile regex at compile time for efficiency
    enum rx = ctRegex!("^" ~ pattern_, "i");

    /// Check if input matches this rule
    static bool matches(string input)
    {
        return !input.matchFirst(rx).empty;
    }

    /// Get result if matches, otherwise null
    static string match(string input)
    {
        return matches(input) ? result : null;
    }
}

/// Rule that matches anywhere in string (not just prefix)
struct ContainsRule(string pattern_, string result_)
{
    enum pattern = pattern_;
    enum result = result_;
    enum rx = ctRegex!(pattern_, "i");

    static bool matches(string input)
    {
        return !input.matchFirst(rx).empty;
    }

    static string match(string input)
    {
        return matches(input) ? result : null;
    }
}

/// Rule with word boundary matching (for brand extraction)
/// First argument is the display name (also matched), subsequent args are aliases
struct WordRule(string displayName_, Aliases...)
{
    enum displayName = displayName_;
    alias aliases = Aliases;

    // Build alternation pattern: displayName|alias1|alias2|...
    private static string buildPattern()
    {
        string result = displayName_;
        static foreach (alias_; Aliases)
            result ~= "|" ~ alias_;
        return result;
    }

    // Match word with boundaries: space/start before, space/punctuation/end after
    enum rx = ctRegex!(`(?:^|[\s(])(?:` ~ buildPattern() ~ `)(?:[\s,\-)]|$)`, "i");

    static bool matches(string input)
    {
        return !input.matchFirst(rx).empty;
    }

    static string match(string input)
    {
        return matches(input) ? displayName : null;
    }

    /// Get all aliases for this brand (for removal from model names)
    static string[] getAllAliases()
    {
        string[] result;
        static foreach (alias_; Aliases)
            result ~= alias_;
        return result;
    }
}

// =============================================================================
// Rule Set - Evaluate Multiple Rules
// =============================================================================

/// Compile-time rule set that evaluates rules in order, returns first match
template RuleSet(Rules...)
{
    /// Evaluate rules against input, return first matching result or fallback
    static string eval(string input, string fallback = "")
    {
        static foreach (R; Rules)
        {{
            auto result = R.match(input);
            if (result !is null)
                return result;
        }}
        return fallback;
    }

    /// Check if any rule matches
    static bool matches(string input)
    {
        static foreach (R; Rules)
        {
            if (R.matches(input))
                return true;
        }
        return false;
    }

    /// Get all matching results (for debugging/inspection)
    static string[] allMatches(string input)
    {
        string[] results;
        static foreach (R; Rules)
        {
            if (R.matches(input))
                results ~= R.result;
        }
        return results;
    }
}

// =============================================================================
// Alias Resolution (Brand/Model Normalization)
// =============================================================================

/// Define aliases that normalize to a canonical value
struct Alias(string canonical_, Patterns...)
{
    enum canonical = canonical_;

    // Build regex alternation from patterns
    private static string buildPattern()
    {
        string result = "^(?:";
        static foreach (i, pat; Patterns)
        {
            static if (i > 0)
                result ~= "|";
            result ~= pat;
        }
        result ~= ")";
        return result;
    }

    enum rx = ctRegex!(buildPattern(), "i");

    static bool matches(string input)
    {
        return !input.matchFirst(rx).empty;
    }

    static string resolve(string input)
    {
        return matches(input) ? canonical : null;
    }
}

/// Resolver that applies alias rules to normalize strings
template AliasResolver(Aliases...)
{
    static string eval(string input)
    {
        auto normalized = input.toLower.strip;

        // Apply cleanup transformations first
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

        // Check aliases
        static foreach (A; Aliases)
        {{
            auto result = A.resolve(normalized);
            if (result !is null)
                return result;
        }}

        return normalized;
    }
}

// =============================================================================
// Brand Extraction with Context Awareness
// =============================================================================

/// Extract brands from text, with optional context-sensitive brands
template BrandExtractor(PrimaryBrands...)
{
    static string eval(string text)
    {
        auto upper = text.toUpper.strip;

        // Check for compatibility context (e.g., "Intel LGA 1700")
        enum contextRx = ctRegex!(`\b(LGA|SOCKET|AM4|AM5)\b`, "i");
        bool hasCompatContext = !upper.matchFirst(contextRx).empty;

        // Check primary brands
        static foreach (B; PrimaryBrands)
        {{
            static if (isContextualBrand!B)
            {
                // Only check contextual brands if not in compatibility context
                if (!hasCompatContext && B.matches(upper))
                    return B.displayName;
            }
            else
            {
                if (B.matches(upper))
                    return B.displayName;
            }
        }}

        return "";
    }

    private template isContextualBrand(B)
    {
        enum isContextualBrand = B.displayName == "Intel" || B.displayName == "AMD" || B.displayName == "NVIDIA";
    }
}

// =============================================================================
// Token Extraction for Model Matching
// =============================================================================

/// Token pattern definition
struct TokenPattern(string pattern_, bool critical_ = true, size_t[] groups_ = [1])
{
    enum pattern = pattern_;
    enum isCritical = critical_;
    enum groups = groups_;
    enum rx = ctRegex!(pattern_, "i");

    /// Extract tokens from input
    static string[] extract(string input)
    {
        string[] tokens;
        foreach (m; input.matchAll(rx))
        {
            string token;
            static foreach (g; groups_)
            {
                if (m[g].length > 0)
                    token ~= m[g].to!string;
            }
            if (token.length > 0)
                tokens ~= token;
        }
        return tokens;
    }
}

/// Noise words to filter from tokens
struct NoiseFilter(Words...)
{
    static bool isNoise(string token)
    {
        auto upper = token.toUpper;
        static foreach (w; Words)
        {
            if (upper == w)
                return true;
        }
        return false;
    }

    static string[] filter(string[] tokens)
    {
        return tokens.filter!(t => !isNoise(t)).array;
    }
}

/// Token extractor combining multiple patterns
template TokenExtractor(NoiseFilterT, Patterns...)
{
    struct Tokens
    {
        string[] critical;   // Must match (SKUs, part numbers)
        string[] soft;       // Supplementary (descriptors)
    }

    static Tokens extract(string input)
    {
        Tokens result;
        auto upper = input.toUpper;

        static foreach (P; Patterns)
        {{
            auto extracted = P.extract(upper);
            auto filtered = NoiseFilterT.filter(extracted);

            static if (P.isCritical)
                result.critical ~= filtered;
            else
                result.soft ~= filtered;
        }}

        return result;
    }
}

/// Token-based matcher
template TokenMatcher(alias extractor)
{
    static bool match(string a, string b)
    {
        auto tokensA = extractor.extract(a);
        auto tokensB = extractor.extract(b);

        // If both have critical tokens, ALL from shorter list must match
        if (tokensA.critical.length > 0 && tokensB.critical.length > 0)
        {
            auto shorter = tokensA.critical.length <= tokensB.critical.length
                ? tokensA.critical : tokensB.critical;
            auto longer = tokensA.critical.length > tokensB.critical.length
                ? tokensA.critical : tokensB.critical;

            foreach (token; shorter)
            {
                if (!longer.canFind(token))
                    return false;
            }
            return true;
        }

        // Fallback: require all soft tokens to match
        if (tokensA.soft.length > 0 && tokensB.soft.length > 0)
        {
            auto shorter = tokensA.soft.length <= tokensB.soft.length
                ? tokensA.soft : tokensB.soft;
            auto longer = tokensA.soft.length > tokensB.soft.length
                ? tokensA.soft : tokensB.soft;

            foreach (token; shorter)
            {
                if (!longer.canFind(token))
                    return false;
            }
            return true;
        }

        return false;
    }
}

// =============================================================================
// String Normalization Pipeline
// =============================================================================

/// Normalizer using regex replacements
template RegexNormalizer(Replacements...)
{
    static string eval(string input)
    {
        string result = input.toUpper.strip;

        static foreach (R; Replacements)
        {{
            enum rx = ctRegex!(R.pattern, "i");
            result = result.replaceAll(rx, R.replacement);
        }}

        return result;
    }
}

/// Replacement rule for normalizer
struct Repl(string pattern_, string replacement_ = "")
{
    enum pattern = pattern_;
    enum replacement = replacement_;
}

// =============================================================================
// Composable Matchers
// =============================================================================

/// Combine multiple match strategies - returns true if ANY matches
template AnyMatcher(Strategies...)
{
    static bool match(string a, string b)
    {
        if (a.length == 0 || b.length == 0)
            return false;

        static foreach (S; Strategies)
        {
            if (S.match(a, b))
                return true;
        }
        return false;
    }
}

/// Combine multiple match strategies - returns true if ALL match
template AllMatcher(Strategies...)
{
    static bool match(string a, string b)
    {
        if (a.length == 0 || b.length == 0)
            return false;

        static foreach (S; Strategies)
        {
            if (!S.match(a, b))
                return false;
        }
        return true;
    }
}

/// Exact match after normalization
template ExactMatcher(alias normalizer)
{
    static bool match(string a, string b)
    {
        return normalizer.eval(a) == normalizer.eval(b);
    }
}

/// Substring containment match
template ContainsMatcher(alias normalizer)
{
    static bool match(string a, string b)
    {
        auto na = normalizer.eval(a);
        auto nb = normalizer.eval(b);
        return na.canFind(nb) || nb.canFind(na);
    }
}

/// Suffix match for truncated values (serial numbers)
template SuffixMatcher(alias normalizer, size_t minLen = 6)
{
    static bool match(string a, string b)
    {
        auto na = normalizer.eval(a);
        auto nb = normalizer.eval(b);

        auto len = min(na.length, nb.length);
        if (len >= minLen)
        {
            return na.endsWith(nb[$ - len .. $]) ||
                nb.endsWith(na[$ - len .. $]) ||
                na.canFind(nb) || nb.canFind(na);
        }
        return false;
    }
}

// =============================================================================
// Category Classification
// =============================================================================

enum CategoryType
{
    autoMatch,   // CPU, MB, SSD, etc. - auto-matchable to hosts
    peripheral,  // Keyboard, Mouse, etc. - manually matchable
    standalone,  // UPS, Switch, etc. - not tied to hosts
    ignored,     // Service, Shipping, etc. - skip
    unknown,
}

/// Category definition
struct Cat(string name_, CategoryType type_)
{
    enum name = name_;
    enum type = type_;
}

/// Category classifier
template CategoryClassifier(Categories...)
{
    static CategoryType classify(string category)
    {
        auto cat = category.toLower;
        static foreach (C; Categories)
        {
            if (cat == C.name.toLower)
                return C.type;
        }
        return CategoryType.unknown;
    }

    static bool isAutoMatch(string cat) { return classify(cat) == CategoryType.autoMatch; }
    static bool isPeripheral(string cat) { return classify(cat) == CategoryType.peripheral; }
    static bool isStandalone(string cat) { return classify(cat) == CategoryType.standalone; }
    static bool isIgnored(string cat) { return classify(cat) == CategoryType.ignored; }
}

/// Category equivalence for matching part names to invoice categories
struct Equiv(string partCat_, InvoicePats...)
{
    enum partCat = partCat_;

    // Build alternation pattern
    private static string buildPattern()
    {
        string result = "(?:";
        static foreach (i, pat; InvoicePats)
        {
            static if (i > 0)
                result ~= "|";
            result ~= pat;
        }
        result ~= ")";
        return result;
    }

    enum rx = ctRegex!(buildPattern(), "i");

    static bool matches(string invoiceCat)
    {
        return !invoiceCat.matchFirst(rx).empty;
    }
}

/// Category matcher using equivalence rules
template CategoryMatcher(Equivs...)
{
    static bool match(string partCat, string invoiceCat)
    {
        auto p = partCat.toLower;
        auto i = invoiceCat.toLower;

        if (p == i)
            return true;

        static foreach (E; Equivs)
        {
            if (p == E.partCat.toLower && E.matches(i))
                return true;
        }
        return false;
    }
}

// =============================================================================
// Convenience Aliases
// =============================================================================

/// Prefix rule (anchored at start)
alias P(string pattern, string result) = Rule!(pattern, result);

/// Contains rule (matches anywhere)
alias C(string pattern, string result) = ContainsRule!(pattern, result);

/// Word-boundary rule (for brand extraction)
/// W!"Brand" matches "Brand" (case-insensitive) and returns "Brand"
/// W!("Brand", "ALIAS1", "ALIAS2") matches any of them and returns "Brand"
alias W(string displayName, Aliases...) = WordRule!(displayName, Aliases);

/// Critical token pattern
alias Crit(string pattern) = TokenPattern!(pattern, true);
alias Crit(string pattern, size_t[] groups) = TokenPattern!(pattern, true, groups);

/// Soft token pattern
alias Soft(string pattern) = TokenPattern!(pattern, false);
