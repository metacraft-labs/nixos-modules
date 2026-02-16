#!/usr/bin/env dub
/+ dub.sdl:
    name "test_coda"
    dependency "mcl" path="."
+/

module test_coda;

import std.stdio : writeln, writefln;
import mcl.commands.invoices.coda : printTablesAndColumns;

void main(string[] args)
{
    if (args.length < 2)
    {
        writeln("Usage: ./test_coda.d <docId> [pageId]");
        writeln();
        writeln("Introspects a Coda document to list tables and columns.");
        writeln();
        writeln("Arguments:");
        writeln("  docId   - Coda document ID (required)");
        writeln("  pageId  - Optional page/canvas ID to filter tables");
        writeln();
        writeln("Example:");
        writeln("  ./test_coda.d SIcXMyTJrL");
        writeln("  ./test_coda.d SIcXMyTJrL canvas-OJyzDZriCI");
        return;
    }

    auto docId = args[1];
    auto pageId = args.length > 2 ? args[2] : null;

    writeln("=== Coda Document Introspection ===\n");

    printTablesAndColumns(docId, pageId);

    writeln("=== Done ===");
}
