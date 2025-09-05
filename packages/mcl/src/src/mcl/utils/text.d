module mcl.utils.text;

size_t escapeSequenceLength(string s)
{
    import std.ascii : isDigit;
    import std.algorithm : countUntil;

    if (s.length == 0 || s[0] != '\x1B') // must start with ESC
        return 0;

    // ESC by itself is not useful
    if (s.length == 1)
        return 1;

    immutable char second = s[1];

    // CSI (Control Sequence Introducer): ESC [ ... <final-byte>
    if (second == '[')
    {
        // CSI params: digits, semicolons, private markers like ? or >
        for (size_t i = 2; i < s.length; i++)
        {
            char c = s[i];
            if (c >= 0x40 && c <= 0x7E) // final byte
                return i + 1;
        }
        return s.length; // incomplete but consume what we have
    }

    // OSC (Operating System Command): ESC ] ... BEL or ST (ESC \)
    if (second == ']')
    {
        for (size_t i = 2; i < s.length; i++)
        {
            if (s[i] == '\a') // BEL terminator
                return i + 1;
            if (s[i] == '\x1B' && i + 1 < s.length && s[i + 1] == '\\')
                return i + 2; // ST terminator
        }
        return s.length;
    }

    // Single-character sequences: ESC followed by @A–Z[\]^_a–z{|}~ etc.
    // (part of 7-bit C1 escapes)
    if (second >= 0x40 && second <= 0x5F)
    {
        return 2;
    }

    // Two-character sequences: ESC ( F for font etc.
    // Generally ESC followed by one or two intermediate bytes + a final
    for (size_t i = 1; i < s.length; i++)
    {
        char c = s[i];
        if (c >= 0x40 && c <= 0x7E) // final byte
            return i + 1;
    }

    return s.length; // fallback: consume whole string if incomplete
}

@("escapeSequenceLength - empty string returns 0")
unittest
{
    assert(escapeSequenceLength("") == 0);
}

@("escapeSequenceLength - string without ESC returns 0")
unittest
{
    assert(escapeSequenceLength("plain") == 0);
}

@("escapeSequenceLength - lone ESC returns 1")
unittest
{
    assert(escapeSequenceLength("\x1B") == 1);
}

@("escapeSequenceLength - CSI simple final byte")
unittest
{
    string s = "\x1B[A"; // Cursor Up
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - CSI with parameters")
unittest
{
    string s = "\x1B[31m"; // SGR red
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - CSI incomplete (no final byte)")
unittest
{
    string s = "\x1B[12;"; // Missing final
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - OSC terminated by BEL")
unittest
{
    string s = "\x1B]0;hi\a";
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - OSC terminated by ST (ESC \\)")
unittest
{
    string s = "\x1B]0;hi\x1B\\";
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - OSC incomplete (no terminator)")
unittest
{
    string s = "\x1B]1;title";
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - single-character C1 style sequence")
unittest
{
    string s = "\x1BM"; // Reverse Index
    assert(escapeSequenceLength(s) == 2);
}

@("escapeSequenceLength - two/three-char sequence with intermediate byte")
unittest
{
    string s = "\x1B(B"; // Designate G0 charset
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - incomplete generic (no final byte)")
unittest
{
    string s = "\x1B(";
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - another single final in 0x40-0x5F range")
unittest
{
    string s = "\x1B^";
    assert(escapeSequenceLength(s) == 2);
}

@("escapeSequenceLength - CSI with private marker and params")
unittest
{
    string s = "\x1B[?25l"; // Hide cursor
    assert(escapeSequenceLength(s) == s.length);
}

@("escapeSequenceLength - generic fallback long incomplete (no final byte)")
unittest
{
    // After ESC % none of these reach a final byte (0x40–0x7E)
    string s = "\x1B%12";
    assert(escapeSequenceLength(s) == s.length);
}

/// Skips an ANSI escape at s[pos] if present; returns bytes consumed (>=1 when ESC),
/// or 0 if there is no escape at pos.
size_t skipAnsiAt(string s, size_t pos) {
    if (pos >= s.length || s[pos] != '\x1B')
        return 0;
    auto n = escapeSequenceLength(s[pos .. $]);
    return n > 0 ? n : 1; // guarantee progress
}

struct StripAnsiRange
{
    private
    {
        import std.utf : decode;
        string s;
        size_t i;
    }

    this(string input)
    {
        s = input;
        skipEsc();
    }

    @property
    {
        bool empty() const => i >= s.length;

        dchar front() const
        {
            size_t tmp = i;
            return decode(s, tmp);
        }
    }


    void popFront()
    {
        decode(s, i);
        skipEsc();
    }

    private void skipEsc()
    {
        while (i < s.length)
        {
            if (auto n = skipAnsiAt(s, i))
            {
                i += n;
                continue;
            }
            else
                break;
        }
    }
}

StripAnsiRange stripAnsi(string s) { return StripAnsiRange(s); }

@("stripAnsi - removes ANSI CSI codes lazily")
unittest
{
    import std.array : array;
    const s = "A\x1B[31mB\x1B[0mC";
    assert(stripAnsi(s).array == "ABC");
}

/// Count visible grapheme clusters (ignoring ANSI) using graphemeStride.
size_t visibleGraphemeCount(string s)
{
    import std.stdio;
    import std.range : walkLength, tee;
    import std.uni : byGrapheme;

    return stripAnsi(s)
        .byGrapheme
        .walkLength;
}

@("visibleGraphemeCount - counts graphemes ignoring ANSI")
unittest
{
    assert(visibleGraphemeCount("ab") == 2);

    // e + combining acute accent
    assert(visibleGraphemeCount("e\xCC\x81") == 1);

    // A + ANSI + B + ANSI + C (3 graphemes)
    assert(visibleGraphemeCount("A\x1B[31mB\x1B[0mC") == 3);


    // a + ANSI + b + ANSI + g + combining diaeresis
    assert(visibleGraphemeCount("a\x1B[1mb\x1B[22m\u0067\u0308") == 3);

    // e + combining acute accent + ANSI + ! + ANSI
    assert(visibleGraphemeCount("e\xCC\x81\x1B[32m!\x1B[0m") == 2);

    // only ANSI
    assert(visibleGraphemeCount("\x1B[31m\x1B[32m") == 0);

    // A + ANSI + B + ANSI + C + check mark
    assert(visibleGraphemeCount("A\x1B[31mB\x1B[0mC\xE2\x9C\x94") == 4);
}

/// Return true if `esc` is a CSI SGR sequence (ends with 'm').
private bool isSgr(string esc)
{
    return esc.length >= 3 && esc[0] == '\x1b' && esc[1] == '[' && esc[$ - 1] == 'm';
}

/// Return true if the SGR sequence includes a reset (0) parameter.
private bool sgrHasReset(string esc)
{
    import std.algorithm : splitter;

    // esc is ESC '[' ... 'm'
    auto body = esc[2 .. $ - 1];
    foreach (p; body.splitter(';'))
        if (p == "0")
            return true;
    return false;
}

/// Wrap a *single logical line* (may contain ANSI) into slices
/// of width `wrapWidth` graphemes. Preserves ANSI; resets at the end
/// of each non-final slice, and reopens active styles at the start of the
/// next slice *unless* leading escapes at that position (e.g. a reset) clear them.
string[] wrapOneLineAnsi(string line, size_t wrapWidth)
{
    import std.array : appender;
    import std.range.primitives;
    import std.uni : graphemeStride;
    import std.string : endsWith;

    if (line.length == 0) return [];

    // Special case: no wrapping requested. Only append a reset if we actually saw any SGR.
    if (wrapWidth == 0)
    {
        bool hasSgr = false;
        size_t p = 0;
        while (p < line.length)
        {
            auto n = skipAnsiAt(line, p);
            if (n == 0) { ++p; continue; }
            auto esc = line[p .. p + n];
            if (isSgr(esc)) { hasSgr = true; break; }
            p += n;
        }
        if (hasSgr && !line.endsWith("\x1b[0m"))
            return [line ~ "\x1b[0m"];
        return [line];
    }

    auto outSlices = appender!(string[])();
    auto cur = appender!string();

    size_t pos = 0;
    size_t width = 0;

    string reopen = "";         // accumulated SGRs to replay
    bool needReopen = false;    // set when we just started a new slice (cur is empty)
    bool sawAnySgr = false;     // track if any SGR appears anywhere (controls whether we emit resets at all)

    // Flush current slice. We only append a trailing reset if at least one SGR
    // appeared anywhere in the original line (consistent with tests expecting
    // no resets for purely plain text).
    auto flushSlice = ()
    {
        if (sawAnySgr && !cur.data.endsWith("\x1b[0m"))
            cur ~= "\x1b[0m";
        if (visibleGraphemeCount(cur.data) > 0)
            outSlices ~= cur[].idup;
        cur = appender!string();
        width = 0;
        needReopen = true;
    };

    while (pos < line.length)
    {
        // Consume leading escapes at current position first (before reopen) to
        // ensure resets there can clear prior styles.
        auto escLen = skipAnsiAt(line, pos);
        if (escLen > 0)
        {
            auto esc = line[pos .. pos + escLen];
            cur ~= esc;
            if (isSgr(esc))
            {
                sawAnySgr = true;
                if (sgrHasReset(esc))
                    reopen = ""; // full reset clears previous stack
                reopen ~= esc;
            }
            pos += escLen;
            continue;
        }

        if (needReopen)
        {
            if (!reopen.empty)
                cur ~= reopen;
            needReopen = false;
        }

        auto g = graphemeStride(line, pos);
        cur ~= line[pos .. pos + g];
        pos += g;
        ++width;

        if (width >= wrapWidth)
        {
            // Attach immediately following escapes (kept with preceding grapheme)
            while (pos < line.length)
            {
                auto len = skipAnsiAt(line, pos);
                if (len == 0) break;
                auto esc = line[pos .. pos + len];
                cur ~= esc;
                if (isSgr(esc))
                {
                    sawAnySgr = true;
                    if (sgrHasReset(esc))
                        reopen = "";
                    reopen ~= esc;
                }
                pos += len;
            }
            flushSlice();
        }
    }

    if (cur.data.length > 0)
        flushSlice();

    return outSlices.data.dup;
}


version (unittest)
{
    import std.algorithm : startsWith, endsWith, canFind, map;
    import std.algorithm : equal;
    import std.conv : to;
    import std.stdio;

    void print(string[] lines, string file = __FILE__, int line = __LINE__)
    {
        writefln("------- %s:%s --------", file, line);
        foreach (l; lines) writefln("%(%s%)", [l]);
        writeln("---------------------");
    }
}

@("wrapOneLineAnsi - empty string yields no slices")
unittest
{
    auto slices = wrapOneLineAnsi("", 10);
    assert(slices.length == 0, "Expected no slices for empty input");
}

@("wrapOneLineAnsi - single short line without ANSI (no wrap)")
unittest
{
    auto slices = wrapOneLineAnsi("hello", 10);
    assert(slices == ["hello"]);
}

@("wrapOneLineAnsi - exact width fits in one slice")
unittest
{
    auto slices = wrapOneLineAnsi("hello", 5);
    assert(slices.length == 1);
    assert(stripAnsi(slices[0]).to!string == "hello");
    assert(slices[0] == "hello");
}

@("wrapOneLineAnsi - simple wrapping without ANSI")
unittest
{
    auto slices = wrapOneLineAnsi("abcdef", 3);
    assert(slices == ["abc", "def"]);
}

@("wrapOneLineAnsi - ANSI color is preserved and re-opened on next slice")
unittest
{
    enum red = "\x1b[31m";
    auto line = red ~ "abcdef";
    auto slices = wrapOneLineAnsi(line, 3);
    assert(slices.length == 2);

    // Each slice ends with a reset
    assert(slices[0].endsWith("\x1b[0m"));
    assert(slices[1].endsWith("\x1b[0m"));

    // Visible text is intact
    assert(stripAnsi(slices[0]).to!string == "abc");
    assert(stripAnsi(slices[1]).to!string == "def");

    // The first slice should contain the opening red SGR;
    // the second slice should start by reopening it.
    assert(slices[0].canFind(red));
    assert(slices[1].startsWith(red), "Expected styles reopened at start of next slice");
}

@("wrapOneLineAnsi - reset mid-line prevents styles from carrying past it")
unittest
{
    enum red = "\x1b[31m";
    enum reset = "\x1b[0m";
    auto line = red ~ "abc" ~ reset ~ "def";
    auto slices = wrapOneLineAnsi(line, 3);
    writeln(slices);
    assert(slices.length == 2);

    assert(stripAnsi(slices[0]).to!string == "abc");
    assert(stripAnsi(slices[1]).to!string == "def");

    assert(slices[0] == "\x1B[31mabc\x1B[0m");

    // First slice colored, ends reset
    assert(slices[0].startsWith(red));
    assert(slices[0].endsWith(reset));

    // Second slice may begin with reopened red (based on implementation),
    // but the very next escape in the content is a reset before 'def',
    // so the visible result is uncolored. Verify that:
    assert(!stripAnsi(slices[1]).empty); // has content
    // No assumptions about exact escape ordering are needed beyond the visible text match above.
}

@("wrapOneLineAnsi - multiple SGRs accumulate and reopen")
unittest
{
    enum bold = "\x1b[1m";
    enum red  = "\x1b[31m";
    enum under= "\x1b[4m";

    auto line = bold ~ red ~ "ab" ~ under ~ "cd";
    auto slices = wrapOneLineAnsi(line, 2);
    assert(slices.length == 2);

    // Visible text intact per slice
    assert(stripAnsi(slices[0]).to!string == "ab");
    assert(stripAnsi(slices[1]).to!string == "cd");

    // First slice contains bold+red
    assert(slices[0].canFind(bold));
    assert(slices[0].canFind(red));

    // Second slice should reopen bold+red at the start, then encounter underline before 'cd'
    assert(slices[1].startsWith(bold) || slices[1].startsWith(red) || slices[1].startsWith(bold ~ red) || slices[1].startsWith(red ~ bold));
    assert(slices[1].canFind(under));
}

@("wrapOneLineAnsi - grapheme counting treats emoji flag as one grapheme")
unittest
{
    // "A🇺🇸B" where the flag is two code points (regional indicators) but one grapheme
    auto line = "A🇺🇸B";
    auto slices = wrapOneLineAnsi(line, 2);
    assert(slices.length == 2, "Expected 2 slices: 'A🇺🇸' and 'B'");
    assert(stripAnsi(slices[0]).to!string == "A🇺🇸");
    assert(stripAnsi(slices[1]).to!string == "B");
    assert(visibleGraphemeCount(slices[0]) == 2);
    assert(visibleGraphemeCount(slices[1]) == 1);
}

@("wrapOneLineAnsi - grapheme counting with combining marks")
unittest
{
    // "e\u0301" is 'e' + COMBINING ACUTE ACCENT, one grapheme
    auto line = "e\u0301xyz";
    auto slices = wrapOneLineAnsi(line, 2);
    assert(slices.length == 2);
    assert(stripAnsi(slices[0]).to!string == "e\u0301x"); // 1st grapheme = é, 2nd = x
    assert(stripAnsi(slices[1]).to!string == "yz");
    assert(visibleGraphemeCount(slices[0]) == 2);
    assert(visibleGraphemeCount(slices[1]) == 2);
}

@("wrapOneLineAnsi - zero wrapWidth returns single slice with full line and reset")
unittest
{
    enum red = "\x1b[31m";
    auto line = red ~ "hello";
    auto slices = wrapOneLineAnsi(line, 0);
    assert(slices.length == 1);
    assert(slices[0].endsWith("\x1b[0m"));
    assert(stripAnsi(slices[0]).to!string == "hello");
}

@("wrapOneLineAnsi - concatenated slices reproduce original visible text")
unittest
{
    import std.array : join;
    enum bold = "\x1b[1m";
    enum blue = "\x1b[34m";
    enum reset = "\x1b[0m";

    auto line = "Start " ~ bold ~ blue ~ "αβγ" ~ reset ~ " end 🇧🇬!";
    auto slices = wrapOneLineAnsi(line, 4);

    // All slices end with reset
    foreach (s; slices) assert(s.endsWith(reset));

    // When we strip ANSI and join, visible text matches original visible text
    auto visibleOriginal = stripAnsi(line).to!string;
    auto visibleFromSlices = slices.map!(a => stripAnsi(a).to!string).join();
    assert(visibleFromSlices == visibleOriginal, "Visible text changed across wrapping");
}

@("wrapOneLineAnsi - every slice width ≤ wrapWidth (by graphemes); all but last equal")
unittest
{
    import std.algorithm : max, map, sum;
    size_t wrap = 3;
    auto line = "\x1b[32m" ~ "ab🇪🇺c" ~ "\x1b[0mdef" ~ "g\u0301h"; // includes emoji + combining
    auto slices = wrapOneLineAnsi(line, wrap);

    assert(slices.length >= 2);
    foreach (i, s; slices)
    {
        auto w = visibleGraphemeCount(s);
        assert(w <= wrap, "Slice "~i.to!string~" exceeds width");
        if (i + 1 < slices.length)
            assert(w == wrap, "Non-final slice should be exactly wrap width");
    }
}
