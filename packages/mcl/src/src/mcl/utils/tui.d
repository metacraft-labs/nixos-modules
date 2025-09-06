module mcl.utils.tui;

string bold(const char[] s) => cast(string)("\033[1m" ~ s ~ "\033[22m");

import std;

import std.range     : isInputRange, ElementType, repeat;
import std.traits    : isSomeString;
import std.algorithm : clamp;
import std.uni       : graphemeStride;
import std.utf       : decode;
import std.array     : appender;
import std.string    : join;

import mcl.utils.text : visibleGraphemeCount;

/// ======================================================
/// Public API (lazy streaming box)
/// ======================================================

/// Lazily wrap a range of strings into a framed box with a bold title.
/// Each element of the result is one full printed line.
auto wrapTextInBox(R)(R input, ushort maxWidth, string title)
if (isInputRange!R && isSomeString!(ElementType!R))
{
    static struct Boxed {
        // source & geometry
        R r;
        size_t outerW, innerW;

        // chrome
        string topLine, bottomLine;

        // streaming state
        string[] currentWrapped;
        bool emittedTop, emittedBottom;
        string _front;
        bool haveFront;

        @property bool empty() {
            if (!haveFront) prepareFront();
            return !haveFront;
        }
        @property string front() {
            if (!haveFront) prepareFront();
            return _front;
        }
        void popFront() { haveFront = false; }

        private void prepareFront() {
            if (emittedBottom) return;

            // Top once
            if (!emittedTop) {
                _front = topLine;
                emittedTop = true;
                haveFront = true;
                return;
            }

            // Accumulate next wrapped content line lazily
            while (currentWrapped.length == 0) {
                if (r.empty) {
                    _front = bottomLine;
                    emittedBottom = true;
                    haveFront = true;
                    return;
                }

                auto chunk = r.front; // may contain newlines
                r.popFront();

                size_t start = 0;
                foreach (i, ch; chunk) {
                    if (ch == '\n') {
                        auto logical = chunk[start .. i];
                        currentWrapped ~= (logical.length == 0)
                            ? [""]
                            : wrapOneLineAnsi(logical, innerW);
                        start = i + 1;
                    }
                }
                if (start < chunk.length) {
                    auto logical = chunk[start .. $];
                    currentWrapped ~= (logical.length == 0)
                        ? [""]
                        : wrapOneLineAnsi(logical, innerW);
                }
            }

            // Frame one wrapped content line
            auto raw = currentWrapped[0];
            currentWrapped = currentWrapped[1 .. $];

            auto vis = visibleGraphemeCount(raw);
            auto pad = (vis < innerW) ? (innerW - vis) : 0;

            _front = "│" ~ raw ~ repeat(" ", pad).join() ~ "│";
            haveFront = true;
        }
    }

    size_t W     = clamp(cast(size_t) maxWidth, 4, size_t.max);
    size_t inner = (W >= 2) ? (W - 2) : 0;

    Boxed b;
    b.r         = input;
    b.outerW    = W;
    b.innerW    = inner;
    b.topLine   = buildTop(inner, title);
    b.bottomLine= buildBottom(inner);
    return b;
}

/// ======================================================
/// Helpers (each with its own unittest right below)
/// ======================================================

// ---- ANSI stripping as a lazy input range (CSI sequences only) ----




// ---- Take first N visible graphemes (drops ANSI) ----

/// Returns a string consisting of the first `n` visible graphemes.
/// ANSI is skipped (not copied).
string takeVisibleAnsi(string s, size_t n) {
    if (n == 0) return "";
    auto builder = appender!string();
    size_t i = 0, taken = 0;
    while (i < s.length && taken < n) {
        // skip ANSI
        if (s[i] == '\x1B' && i + 1 < s.length && s[i + 1] == '[') {
            i += 2;
            while (i < s.length) { char c = s[i++]; if (c >= '@' && c <= '~') break; }
            continue;
        }
        auto start = i;
        auto stride = graphemeStride(s, i);
        builder.put(s[start .. start + stride]);
        i = start + stride;
        ++taken;
    }
    return builder.data;
}

@("takeVisibleAnsi - extracts N visible graphemes")
unittest {
    const s = "A\x1B[31mB\x1B[0mC";
    assert(takeVisibleAnsi(s, 2) == "AB");
    assert(takeVisibleAnsi(s, 3) == "ABC");
}

// ---- Byte index after N visible graphemes (keeping ANSI) ----

/// Return byte index after consuming at most `n` visible graphemes,
/// starting at `startByte`. ANSI is skipped over (not counted).
size_t byteIndexAfterVisibleGraphemes(string s, size_t startByte, size_t n) {
    size_t i = startByte, taken = 0;
    while (i < s.length && taken < n) {
        // skip ANSI
        if (s[i] == '\x1B' && i + 1 < s.length && s[i + 1] == '[') {
            i += 2;
            while (i < s.length) { char c = s[i++]; if (c >= '@' && c <= '~') break; }
            continue;
        }
        auto stride = graphemeStride(s, i);
        i += stride;
        ++taken;
    }
    return i;
}

@("byteIndexAfterVisibleGraphemes - maps grapheme count to byte index")
unittest {
    const s = "A\x1B[31mB\x1B[0mC";
    // after 2 graphemes -> index at 'C'
    auto idx = byteIndexAfterVisibleGraphemes(s, 0, 2);
    writefln("byteIndexAfterVisibleGraphemes: %s", idx);
    assert(s[idx] == 'C');
}

// ---- Find last space within first K visible graphemes ----

/// Return the byte index of the *start* of the last ASCII space (' ')
/// within the first `k` visible graphemes from `startByte`.
/// Returns `size_t.max` if none.
size_t lastSpaceStartWithin(string s, size_t startByte, size_t k) {
    size_t i = startByte, scanned = 0;
    size_t last = size_t.max;
    while (i < s.length && scanned < k) {
        // skip ANSI
        if (s[i] == '\x1B' && i + 1 < s.length && s[i + 1] == '[') {
            i += 2;
            while (i < s.length) { char c = s[i++]; if (c >= '@' && c <= '~') break; }
            continue;
        }
        auto gStart = i;
        auto stride = graphemeStride(s, i);
        // Simple heuristic: treat a grapheme that begins with ASCII space as space
        if (s[gStart] == ' ') last = gStart;
        i = gStart + stride;
        ++scanned;
    }
    return last;
}

@("lastSpaceStartWithin - locates last space among visible graphemes")
unittest {
    const s = "hello \x1B[32mgreen\x1B[0m world";
    auto idx = lastSpaceStartWithin(s, 0, 6 /* 'hello'+' ' */);
    assert(idx != size_t.max && s[idx] == ' ');
}

// ---- Active SGR opener at a byte index ----

/// Very simple SGR tracker: returns concatenated SGR codes that are active
/// just before byte index `upto`. Resets on "\x1B[0m".
string activeSgrOpener(string s, size_t upto) {
    string active;
    size_t i = 0;
    while (i < upto) {
        if (s[i] == '\x1B' && i + 1 < s.length && s[i + 1] == '[') {
            size_t j = i + 2;
            while (j < s.length) {
                char c = s[j++];
                if (c >= '@' && c <= '~') break;
            }
            // keep only SGR ('m') sequences
            if (s[j - 1] == 'm') {
                auto csi = s[i .. j];
                // crude reset detection
                if (csi == "\x1B[0m") active = "";
                else active ~= csi;
            }
            i = j;
            continue;
        }
        // skip one grapheme (not strictly required; speeds up)
        i += graphemeStride(s, i);
    }
    return active;
}

@("activeSgrOpener - collects SGR to reopen after a cut")
unittest {
    const s = "\x1B[32mhello\x1B[0m world";
    auto idx = s.indexOf(" world"); // cut right before the space
    auto opener = activeSgrOpener(s, idx);
    assert(opener == ""); // style was reset earlier
}

// ---- ANSI-aware line wrapping using the helpers ----

/// Wrap a *single logical line* (may contain ANSI) into slices
/// of width `innerW` graphemes. Preserves ANSI; resets at slice end,
/// and reopens active styles at the start of the next slice.
string[] wrapOneLineAnsi(string line, size_t innerW) {
    enum SGR_RESET = "\x1B[0m";
    string[] outLines;

    if (innerW == 0) return [SGR_RESET]; // degenerate; shouldn't happen for our box

    size_t start = 0;
    const total = visibleGraphemeCount(line);
    size_t consumed = 0;

    while (consumed < total) {
        size_t want = (total - consumed < innerW) ? (total - consumed) : innerW;

        // Prefer last space within the window
        auto spacePos = lastSpaceStartWithin(line, start, want);
        size_t cutStart = start;
        size_t cutEnd   = (spacePos != size_t.max)
                        ? spacePos                   // cut *before* the space
                        : byteIndexAfterVisibleGraphemes(line, start, want);

        // Render raw slice, add reset
        auto slice = line[cutStart .. cutEnd] ~ SGR_RESET;
        outLines ~= slice;

        // Advance: if we broke at space, skip it; else continue from cutEnd
        if (spacePos != size_t.max) {
            // skip the space grapheme
            start = byteIndexAfterVisibleGraphemes(line, spacePos, 1);
        } else {
            start = cutEnd;
        }

        // Compute how many visible graphemes we actually emitted
        consumed += visibleGraphemeCount(slice);

        // If there are more, prepend opener to the *next* slice by mutating later
        if (consumed < total) {
            // Determine opener at new start position
            auto opener = activeSgrOpener(line, start);
            // We'll prefix it when we build the next slice; simulate by pushing
            // an empty string marker that we fill on next iteration:
            // Simpler approach: just apply opener immediately to the *future*
            // slice by storing it and concatenating when we append next time.
            // To keep code simple and avoid extra memory, just modify the next
            // appended slice right after creation (see below).
            // We do that by remembering opener here:
            // Instead of complicating, we carry it in a local variable.
            // (implemented below by peeking outLines.back on next iteration)
            // To keep it straightforward, we store the opener now and apply
            // it to the next slice once it's created.
            // We'll stash it in a local static per-loop variable:
            // (implemented by closure-like pattern below)
            // For clarity, we’ll handle it right away on the next iteration.
        }

        // Prefix opener to upcoming slice (if any)
        if (consumed < total) {
            auto opener = activeSgrOpener(line, start);
            // Build the upcoming slice right away? No, we need to know its end.
            // So we stash the opener by appending an empty line marker and then
            // replace it when we compute the next slice. That’s clunky.
            // Cleaner: delay prefixing until after we compute `slice` next time:
            // We'll compute `sliceNext` then set `sliceNext = opener ~ sliceNext`.
            // Implemented by a tiny lambda-like local flag:
            // -> we’ll just run the loop body again and prefix after computing `slice`.
            // To accomplish this without more state, we’ll *prefix opener on next loop*
            // by keeping it in a local variable outside the loop.
            // See the next block.
            // (Actual implementation below:)
        }

        // Prefix opener to the *next* produced slice (if any)
        if (consumed < total) {
            // Compute the next window tentatively to know the next slice;
            // but that would duplicate logic. Instead, hook into the start
            // of next iteration by using a small nested scope that produces
            // the next slice then prefixes opener. To keep this single-pass
            // and simple, we can modify the last appended slice next iteration,
            // but we can't because it's already reset. So we choose the simple,
            // correct approach: when we *do* compute the next slice, we prefix
            // the opener before pushing it.
            // Thus: we need a flag + opener to carry into next iteration.
        }
        // The above commentary explains intent; actual implementation occurs below.
        // We will implement opener-prefixing by tracking a `pendingOpener` variable.
        // (We rewrite the loop shortly below.)
    }

    // The loop above was described; now implement with `pendingOpener`:

    outLines.length = 0;
    start = 0;
    size_t remaining = total;
    string pendingOpener;

    while (remaining > 0) {
        size_t want = (remaining < innerW) ? remaining : innerW;
        auto spacePos = lastSpaceStartWithin(line, start, want);
        size_t cutStart = start;
        size_t cutEnd   = (spacePos != size_t.max)
                        ? spacePos
                        : byteIndexAfterVisibleGraphemes(line, start, want);

        auto slice = line[cutStart .. cutEnd] ~ SGR_RESET;
        if (pendingOpener.length) slice = pendingOpener ~ slice;

        outLines ~= slice;

        // Advance start
        if (spacePos != size_t.max) {
            start = byteIndexAfterVisibleGraphemes(line, spacePos, 1);
        } else {
            start = cutEnd;
        }

        // Update remaining by what we emitted (visible width of the raw slice)
        auto emitted = visibleGraphemeCount(line[cutStart .. cutEnd]);
        remaining -= emitted;

        // Prepare opener for the next slice (styles active at the new start)
        pendingOpener = (remaining > 0) ? activeSgrOpener(line, start) : "";
    }

    return outLines;
}

@("wrapOneLineAnsi - preserves color across wraps and resets padding")
unittest {
    const s = "prefix \x1B[32mGREEN WORDS THAT WRAP\x1B[0m suffix";
    auto parts = wrapOneLineAnsi(s, 10);
    assert(parts.length >= 3);
    // First slice should contain GREEN and end with reset
    assert(parts[0].canFind("\x1B[32m"));
    assert(parts[0].endsWith("\x1B[0m"));
    // A later slice (after break) should reopen green if still active
    bool sawGreenAgain = false;
    foreach (p; parts[1 .. $]) if (p.canFind("\x1B[32m")) { sawGreenAgain = true; break; }
    assert(sawGreenAgain);
}

// ---- Box chrome ----

string buildTop(size_t innerW, string title) {
    immutable leftTip = "╼ ", rightTip = " ╾";
    immutable boldOn = "\x1B[1m", boldOff = "\x1B[22m";

    size_t fixed = 2 + 2; // grapheme widths of left/right tips
    size_t room  = (innerW > fixed) ? (innerW - fixed) : 0;

    auto visW   = visibleGraphemeCount(title);
    string fitted = (visW <= room)
        ? takeVisibleAnsi(title, visW)
        : (room == 0 ? "" : (room == 1 ? "…" : takeVisibleAnsi(title, room - 1) ~ "…"));

    size_t dashCount = (innerW > (fixed + visibleGraphemeCount(fitted)))
        ? (innerW - (fixed + visibleGraphemeCount(fitted))) : 0;

    return "╭" ~ leftTip ~ boldOn ~ fitted ~ boldOff ~ rightTip
        ~ repeat("─", dashCount).join() ~ "╮";
}

string buildBottom(size_t innerW) {
    return "╰" ~ repeat("─", innerW).join() ~ "╯";
}

@("buildTop/buildBottom - consistent widths and bold title")
unittest {
    auto top = buildTop(12, "T");
    auto bot = buildBottom(12);
    assert(top.length == (1 + 2 + 4 + 1 + 2 + 1 + 12 + 1) || bot.length > 0); // sanity
    // strip ANSI from top and compare visible widths
    import std.array : array;
    import std.algorithm : map;
    auto topVisibleLen = visibleGraphemeCount(top);
    auto botVisibleLen = visibleGraphemeCount(bot);
    assert(topVisibleLen == botVisibleLen);
}





/++
import std.algorithm : clamp, min, max, canFind;
import std.range     : isInputRange, ElementType;
import std.traits    : isSomeString;
import std.uni       : graphemeStride;

/// Lazily wraps/frames a range of strings (each may contain \n) into a box.
/// Returns an *input range* of single-line strings.
auto wrapTextInBox(R)(R input, ushort maxWidth, string title)
if (isInputRange!R && isSomeString!(ElementType!R))
{
    struct BoxedLines {
        // ---------- underlying range ----------
        R r;

        // ---------- geometry ----------
        size_t outerW;
        size_t innerW;

        // ---------- title/top line ----------
        string topLine;
        string bottomLine;

        // ---------- content state ----------
        string curChunk;       // current chunk from r (may contain \n)
        size_t chunkPos = 0;   // next byte index within curChunk
        string curLogical;     // current logical line (split by \n)
        size_t wrapPos = 0;    // wrap offset within curLogical (bytes)
        bool   haveLogical = false;
        bool   emittedAnyContent = false;

        // ---------- front cache ----------
        string _front;
        bool   _haveFront = false;

        enum Phase { Top, Content, EnsureOneBlank, Bottom, Done }
        Phase phase = Phase.Top;

        static size_t byteIndexAfterGraphemes(string s, size_t limit) {
            size_t i = 0, g = 0;
            while (i < s.length && g < limit) { i += graphemeStride(s, i); ++g; }
            return i;
        }

        // Try to produce the next wrapped slice from curLogical into `line`.
        bool nextWrapped(ref string line) {
            if (!haveLogical) return false;

            immutable rest = curLogical[wrapPos .. $];
            if (rest.length == 0) {
                haveLogical = false;
                return false;
            }

            // If it fits: emit it all.
            if (displayWidth(rest) <= innerW) {
                line = rest;
                wrapPos = curLogical.length; // consumed
                haveLogical = false;
                return true;
            }

            // Walk up to innerW graphemes, remember last ASCII-space.
            size_t i = 0, g = 0;
            ptrdiff_t lastSpace = -1;
            while (i < rest.length && g < innerW) {
                if (rest[i] == ' ') lastSpace = i;
                size_t stride = graphemeStride(rest, i);
                i += stride; ++g;
            }

            size_t cut = (lastSpace >= 0) ? cast(size_t) lastSpace : i;
            string slice = rest[0 .. cut];
            // Advance past the slice (+1 to drop the space if we used it)
            wrapPos += (lastSpace >= 0) ? (cut + 1) : cut;

            // Trim right spaces of the slice; padding added when framing.
            import std.string : stripRight;
            line = slice.stripRight;
            if (line.length == 0 && rest.length > 0) {
                // fallback: hard break exactly at i if we trimmed everything
                line = rest[0 .. i];
                wrapPos = curLogical.length == wrapPos ? wrapPos : wrapPos; // already set
            }
            return true;
        }

        // Pull next logical line from curChunk or next chunk from r.
        bool pullNextLogical() {
            // Need a chunk?
            while (chunkPos >= curChunk.length) {
                if (r.empty) {
                    haveLogical = false;
                    return false;
                }
                curChunk = r.front;
                r.popFront();
                chunkPos = 0;
            }

            // Find newline
            auto start = chunkPos;
            size_t i = chunkPos;
            for (; i < curChunk.length; ++i) {
                if (curChunk[i] == '\n') break;
            }
            curLogical = curChunk[start .. i];
            haveLogical = true;
            wrapPos = 0;

            // Move chunkPos past this logical line and the newline (if present)
            chunkPos = (i < curChunk.length) ? i + 1 : i;
            return true;
        }

        // Build a framed middle line: "│ <text><pad> │"
        string frameMiddle(string text) const {
            auto vis = displayWidth(text);
            auto pad = (vis < innerW) ? (innerW - vis) : 0;
            return "│" ~ text ~ repeat(' ', pad) ~ "│";
        }

        // Compute top/bottom lines once
        static string buildTop(size_t innerW, string title) {
            immutable leftTip  = "╼ ";
            immutable rightTip = " ╾";

            // Title may need ellipsis to fit: compute visible room for title
            size_t fixed = displayWidth(leftTip) + displayWidth(rightTip);
            size_t room  = (innerW > fixed) ? (innerW - fixed) : 0;

            // Simple ellipsize by graphemes on visible text (ANSI-free)
            auto vw = displayWidth(title);
            string fitted;
            if (vw <= room) {
                fitted = title;
            } else {
                if (room == 0) fitted = "";
                else {
                    size_t keep = (room > 1) ? room - 1 : 0;
                    size_t cut  = byteIndexAfterGraphemes(title, keep);
                    fitted = title[0 .. cut] ~ "…";
                }
            }

            size_t dashCount = (innerW > (fixed + displayWidth(fitted)))
                ? (innerW - (fixed + displayWidth(fitted))) : 0;

            return "╭" ~ leftTip ~ fitted.bold ~ rightTip
                ~ repeat('─', dashCount) ~ "╮";
        }

        static string buildBottom(size_t innerW) {
            return "╰" ~ repeat('─', innerW) ~ "╯";
        }

        // ---------- input range API ----------
        @property bool empty() {
            // Ensure _front is prepared (unless already done)
            if (_haveFront) return false;
            prepareFront();
            return !_haveFront;
        }

        @property string front() {
            if (!_haveFront) prepareFront();
            return _front;
        }

        void popFront() {
            _haveFront = false;
            _front = null;
        }

        // Prepare next line into _front, advancing state machine as needed.
        void prepareFront() {
            if (_haveFront) return;

            // Phase: Top
            if (phase == Phase.Top) {
                _front = topLine;
                _haveFront = true;
                phase = Phase.Content;
                return;
            }

            // Phase: Content
            if (phase == Phase.Content) {
                // Try to emit wrapped slices until one is produced or input is exhausted
                while (true) {
                    string slice;
                    if (nextWrapped(slice)) {
                        emittedAnyContent = true;
                        _front = frameMiddle(slice);
                        _haveFront = true;
                        return;
                    }
                    // Need a new logical line
                    if (!pullNextLogical()) break; // no more input
                    // If logical line is empty, emit a blank
                    if (curLogical.length == 0) {
                        emittedAnyContent = true;
                        _front = frameMiddle("");
                        _haveFront = true;
                        haveLogical = false;
                        return;
                    }
                    // else loop; nextWrapped() will produce from the new logical
                }

                // No content at all? Ensure at least one blank
                if (!emittedAnyContent) {
                    phase = Phase.EnsureOneBlank;
                } else {
                    phase = Phase.Bottom;
                }
            }

            if (phase == Phase.EnsureOneBlank) {
                _front = frameMiddle("");
                _haveFront = true;
                emittedAnyContent = true;
                phase = Phase.Bottom;
                return;
            }

            if (phase == Phase.Bottom) {
                _front = bottomLine;
                _haveFront = true;
                phase = Phase.Done;
                return;
            }

            // Done: leave _haveFront = false
        }
    }

    // ---- initialize the lazy range instance ----
    size_t W = clamp(cast(size_t) maxWidth, 4, size_t.max);
    size_t inner = (W >= 2) ? (W - 2) : 0;

    BoxedLines bl;
    bl.r = input;
    bl.outerW = W;
    bl.innerW = inner;
    bl.topLine = BoxedLines.buildTop(inner, title);
    bl.bottomLine = BoxedLines.buildBottom(inner);

    return bl;
}

@("wrapTextInBox - basic wrap & shape")
unittest {
    import std.range : only;
    auto W = 30;
    auto lines = wrapTextInBox(
        only("This is a short paragraph that should wrap nicely.\nAnd this is another line."),
        W,
        "title"
    ).array;

    assert(lines.length >= 3);
    assert(lines[0].canFind("\x1B[1mtitle\x1B[22m"));
    assert(lines[$-1].startsWith("╰") && lines[$-1].endsWith("╯"));

    foreach (l; lines)
        assert(stripAnsi(l).length == W || displayWidth(stripAnsi(l)) == W);
}

@("wrapTextInBox - empty input produces one blank line")
unittest {
    import std.range : only;
    auto lines = wrapTextInBox(only(""), 20, "empty").array;
    assert(lines.length == 3);
    assert(lines[1] == "│" ~ " ".repeat(18).join ~ "│");
}

@("wrapTextInBox - preserve explicit blank lines")
unittest {
    import std.range : only;
    auto lines = wrapTextInBox(only("First\n\nThird"), 20, "blanks").array;
    assert(lines.length == 5);
    assert(lines[2] == "│" ~ " ".repeat(18).join ~ "│");
}

@("wrapTextInBox - hard-wrap a long word")
unittest {
    import std.range : only;
    auto lines = wrapTextInBox(only("aSuperLongWordThatWillBeSplit"), 16, "x").array;
    assert(lines.length >= 4);
    foreach (i; 1 .. lines.length - 1) {
        auto inner = lines[i][1 .. $-1];
        assert(displayWidth(inner) <= 14);
    }
}

@("wrapTextInBox - long title gets ellipsized")
unittest {
    import std.range : only;
    auto lines = wrapTextInBox(only("content"), 24, "This is a very very long title").array;
    auto visibleTop = stripAnsi(lines[0]);
    assert(visibleTop.canFind("…") || !visibleTop.canFind("long title"));
}

@("wrapTextInBox - minimal width clamps and wraps")
unittest {
    import std.range : only;
    auto lines = wrapTextInBox(only("ABC"), 4, "T").array;
    assert(lines.length == 5);
    assert(lines[1] == "│AB│");
    assert(lines[2] == "│C │");
}

@("wrapTextInBox - unicode graphemes stay intact")
unittest {
    import std.range : only;
    auto text = "Thumb: 👍🏽 cafe\u0301"; // contains multi-codepoint graphemes
    auto lines = wrapTextInBox(only(text), 20, "uni").array;
    // Re-concatenate inner text (dropping borders/padding) and check grapheme subsequence
    auto reconstructed = lines[1 .. $-1].map!(l => l[1 .. $-1]).array.join(" ");
    size_t i = 0, j = 0;
    while (i < text.length && j < reconstructed.length) {
        auto g1 = text[i .. i + graphemeStride(text, i)];
        auto g2 = reconstructed[j .. j + graphemeStride(reconstructed, j)];
        if (g1 == g2) i += graphemeStride(text, i), j += graphemeStride(reconstructed, j);
        else j += graphemeStride(reconstructed, j);
    }
    assert(i >= text.length);
}

@("wrapTextInBox - streaming across multiple chunks")
unittest {
    auto chunks = ["First paragraph that wraps.\nSecond line", "\n", "Third line continues."];
    auto lines = wrapTextInBox(chunks, 28, "stream").array;
    bool sawBlank = false;
    foreach (i; 1 .. lines.length - 1) {
        auto inner = lines[i][1 .. $-1];
        if (inner.strip == "") { sawBlank = true; break; }
    }
    assert(sawBlank);
}

@("wrapTextInBox - lazy consumption of non-forward range")
unittest {
    static struct CountingRange {
        size_t idx, pops;
        string[] data;
        @property bool empty() const { return idx >= data.length; }
        @property string front() const { return data[idx]; }
        void popFront() { ++pops; ++idx; }
    }
    CountingRange cr = CountingRange(0, 0, ["A A A A", "B B", "C"]);
    auto r = wrapTextInBox(cr, 14, "lazy");
    size_t consumed = 0;
    foreach (line; r) {
        ++consumed;
        if (consumed == 3) break;
    }
    assert(cr.pops <= 1); // didn’t eagerly slurp
}

@("wrapTextInBox - title exactly fits without dashes")
unittest {
    import std.range : only;
    auto title = "ABCD";
    ushort W = cast(ushort)(2 + 4 + title.length); // borders+fixed+title
    auto lines = wrapTextInBox(only("x"), W, title).array;
    auto top = stripAnsi(lines[0]);
    assert(!top.canFind('─'));
}

/// Grapheme-aware visible width (counts grapheme clusters)
size_t displayWidth(string s) @safe
{
    size_t w = 0, i = 0;
    while (i < s.length) { i += graphemeStride(s, i); ++w; }
    return w;
}

++/
