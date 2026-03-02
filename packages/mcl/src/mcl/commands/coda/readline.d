module mcl.commands.coda.readline;

import core.stdc.stdio : EOF;
import core.sys.posix.termios;
import core.sys.posix.unistd : read, STDIN_FILENO;
import std.algorithm : commonPrefix, filter, map, sort;
import std.array : array, join;
import std.stdio : stdout, write, writef, writeln;
import std.string : strip;
import std.uni : toLower;

// =============================================================================
// Completion Callback Type
// =============================================================================

/// Callback to get completions for current input
/// Params:
///   buffer = current input buffer (up to cursor)
///   cursor = cursor position
/// Returns: array of completion strings
alias CompletionCallback = string[] delegate(string buffer, size_t cursor);

// =============================================================================
// Simple Readline with History and Completion
// =============================================================================

struct Readline
{
    string[] history;
    size_t maxHistory = 100;
    CompletionCallback completionCallback;

    private termios origTermios;
    private bool rawMode = false;
    private bool lastWasTab = false;  // Track double-tab for showing all completions

    /// Read a line with history and completion support
    /// Returns null on EOF
    string readLine(string prompt)
    {
        write(prompt);
        stdout.flush();

        if (!enableRawMode())
            return readLineSimple();  // Fallback to simple mode

        scope(exit) disableRawMode();

        char[] buffer;
        size_t cursor = 0;
        int historyIdx = cast(int) history.length;
        string savedInput = "";

        while (true)
        {
            int c = readChar();
            if (c == EOF || c == -1)
            {
                writef("\n");
                return null;  // EOF
            }

            // Track if this is a Tab press after another Tab
            bool isTab = (c == 9);
            scope(exit) lastWasTab = isTab;

            if (c == '\r' || c == '\n')
            {
                writef("\n");
                auto line = cast(string) buffer.idup;
                if (line.strip.length > 0)
                    addToHistory(line);
                return line;
            }
            else if (c == 9)  // Tab - completion
            {
                if (completionCallback !is null)
                    handleCompletion(buffer, cursor, prompt, lastWasTab);
            }
            else if (c == 3)  // Ctrl+C
            {
                writef("^C\n");
                buffer.length = 0;
                cursor = 0;
                write(prompt);
                stdout.flush();
            }
            else if (c == 4)  // Ctrl+D
            {
                if (buffer.length == 0)
                {
                    writef("\n");
                    return null;  // EOF on empty line
                }
            }
            else if (c == 127 || c == 8)  // Backspace
            {
                if (cursor > 0)
                {
                    // Remove character before cursor
                    for (size_t i = cursor - 1; i < buffer.length - 1; i++)
                        buffer[i] = buffer[i + 1];
                    buffer.length--;
                    cursor--;
                    refreshLine(prompt, buffer, cursor);
                }
            }
            else if (c == 27)  // Escape sequence
            {
                int c2 = readChar();
                if (c2 == '[')
                {
                    int c3 = readChar();
                    if (c3 == 'A')  // Up arrow
                    {
                        if (historyIdx > 0)
                        {
                            if (historyIdx == history.length)
                                savedInput = cast(string) buffer.idup;
                            historyIdx--;
                            buffer = history[historyIdx].dup;
                            cursor = buffer.length;
                            refreshLine(prompt, buffer, cursor);
                        }
                    }
                    else if (c3 == 'B')  // Down arrow
                    {
                        if (historyIdx < history.length)
                        {
                            historyIdx++;
                            if (historyIdx == history.length)
                                buffer = savedInput.dup;
                            else
                                buffer = history[historyIdx].dup;
                            cursor = buffer.length;
                            refreshLine(prompt, buffer, cursor);
                        }
                    }
                    else if (c3 == 'C')  // Right arrow
                    {
                        if (cursor < buffer.length)
                        {
                            cursor++;
                            writef("\x1b[C");
                            stdout.flush();
                        }
                    }
                    else if (c3 == 'D')  // Left arrow
                    {
                        if (cursor > 0)
                        {
                            cursor--;
                            writef("\x1b[D");
                            stdout.flush();
                        }
                    }
                    else if (c3 == '3')  // Delete key (ESC[3~)
                    {
                        readChar();  // consume '~'
                        if (cursor < buffer.length)
                        {
                            for (size_t i = cursor; i < buffer.length - 1; i++)
                                buffer[i] = buffer[i + 1];
                            buffer.length--;
                            refreshLine(prompt, buffer, cursor);
                        }
                    }
                    else if (c3 == 'H')  // Home
                    {
                        cursor = 0;
                        refreshLine(prompt, buffer, cursor);
                    }
                    else if (c3 == 'F')  // End
                    {
                        cursor = buffer.length;
                        refreshLine(prompt, buffer, cursor);
                    }
                }
            }
            else if (c >= 32 && c < 127)  // Printable character
            {
                // Insert character at cursor
                buffer.length++;
                for (size_t i = buffer.length - 1; i > cursor; i--)
                    buffer[i] = buffer[i - 1];
                buffer[cursor] = cast(char) c;
                cursor++;
                refreshLine(prompt, buffer, cursor);
            }
        }
    }

    /// Add a command to history
    void addToHistory(string cmd)
    {
        auto stripped = cmd.strip;
        if (stripped.length == 0)
            return;
        // Don't add duplicates
        if (history.length > 0 && history[$ - 1] == stripped)
            return;
        history ~= stripped;
        if (history.length > maxHistory)
            history = history[1 .. $];
    }

private:
    /// Handle tab completion
    void handleCompletion(ref char[] buffer, ref size_t cursor, string prompt, bool showAll)
    {
        auto input = cast(string) buffer[0 .. cursor].idup;
        auto completions = completionCallback(input, cursor);

        if (completions.length == 0)
        {
            // No completions - beep
            writef("\x07");
            stdout.flush();
            return;
        }

        if (completions.length == 1)
        {
            // Single completion - insert it
            auto completion = completions[0];
            auto toInsert = getCompletionSuffix(input, completion);

            // Insert the completion suffix
            foreach (ch; toInsert)
            {
                buffer.length++;
                for (size_t i = buffer.length - 1; i > cursor; i--)
                    buffer[i] = buffer[i - 1];
                buffer[cursor] = ch;
                cursor++;
            }

            // Add space after completion if at end of word
            if (cursor == buffer.length)
            {
                buffer.length++;
                buffer[cursor] = ' ';
                cursor++;
            }

            refreshLine(prompt, buffer, cursor);
        }
        else
        {
            // Multiple completions
            // Find common prefix among completions
            auto prefix = findCommonPrefix(completions);
            auto toInsert = getCompletionSuffix(input, prefix);

            if (toInsert.length > 0)
            {
                // Insert common prefix
                foreach (ch; toInsert)
                {
                    buffer.length++;
                    for (size_t i = buffer.length - 1; i > cursor; i--)
                        buffer[i] = buffer[i - 1];
                    buffer[cursor] = ch;
                    cursor++;
                }
                refreshLine(prompt, buffer, cursor);
            }
            else if (showAll)
            {
                // Show all completions on second Tab
                writeln();
                displayCompletions(completions);
                write(prompt);
                write(cast(string) buffer);
                // Move cursor back if needed
                if (cursor < buffer.length)
                    writef("\x1b[%dD", buffer.length - cursor);
                stdout.flush();
            }
            else
            {
                // First Tab with no common prefix - beep
                writef("\x07");
                stdout.flush();
            }
        }
    }

    /// Get the suffix to insert for a completion
    string getCompletionSuffix(string input, string completion)
    {
        // Find the word being completed (last token)
        auto lastSpace = input.length;
        foreach_reverse (i, c; input)
        {
            if (c == ' ')
            {
                lastSpace = i + 1;
                break;
            }
            if (i == 0)
                lastSpace = 0;
        }

        auto currentWord = input[lastSpace .. $];

        // Return the part of completion after the current word
        if (completion.length > currentWord.length &&
            completion[0 .. currentWord.length].toLower == currentWord.toLower)
        {
            return completion[currentWord.length .. $];
        }

        // If input ends with space, return full completion
        if (input.length > 0 && input[$ - 1] == ' ')
            return completion;

        return "";
    }

    /// Find common prefix among strings
    string findCommonPrefix(string[] strings)
    {
        if (strings.length == 0)
            return "";
        if (strings.length == 1)
            return strings[0];

        auto sorted = strings.dup.sort();
        auto first = sorted[0];
        auto last = sorted[$ - 1];

        size_t i = 0;
        while (i < first.length && i < last.length && first[i] == last[i])
            i++;

        return first[0 .. i];
    }

    /// Display completions in columns
    void displayCompletions(string[] completions)
    {
        import std.algorithm : maxElement;

        auto maxLen = completions.map!(c => c.length).maxElement + 2;
        auto termWidth = 80;  // Assume 80 columns
        auto cols = termWidth / maxLen;
        if (cols < 1) cols = 1;

        foreach (i, completion; completions)
        {
            writef("%-*s", maxLen, completion);
            if ((i + 1) % cols == 0 || i == completions.length - 1)
                writeln();
        }
    }

    /// Enable raw terminal mode
    bool enableRawMode()
    {
        if (rawMode)
            return true;

        if (tcgetattr(STDIN_FILENO, &origTermios) == -1)
            return false;

        termios raw = origTermios;
        raw.c_lflag &= ~(ECHO | ICANON | ISIG | IEXTEN);
        raw.c_iflag &= ~(IXON | ICRNL);
        raw.c_cc[VMIN] = 1;
        raw.c_cc[VTIME] = 0;

        if (tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw) == -1)
            return false;

        rawMode = true;
        return true;
    }

    /// Disable raw terminal mode
    void disableRawMode()
    {
        if (rawMode)
        {
            tcsetattr(STDIN_FILENO, TCSAFLUSH, &origTermios);
            rawMode = false;
        }
    }

    /// Read a single character
    int readChar()
    {
        char c;
        if (read(STDIN_FILENO, &c, 1) != 1)
            return -1;
        return c;
    }

    /// Refresh the line display
    void refreshLine(string prompt, char[] buffer, size_t cursor)
    {
        // Move to start of line, clear, redraw
        writef("\r\x1b[K%s%s", prompt, cast(string) buffer);
        // Move cursor to correct position
        if (cursor < buffer.length)
            writef("\x1b[%dD", buffer.length - cursor);
        stdout.flush();
    }

    /// Simple readline fallback (no history)
    string readLineSimple()
    {
        import std.stdio : stdin;
        auto line = stdin.readln();
        return line is null ? null : line.strip;
    }
}
