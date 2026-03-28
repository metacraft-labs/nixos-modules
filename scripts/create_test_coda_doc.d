#!/usr/bin/env dub
/+ dub.sdl:
    name "create_test_coda_doc"
    dependency "mcl" path="../packages/mcl"
+/

module create_test_coda_doc;

import std.stdio : writeln, writefln;
import std.process : environment;

import mcl.utils.coda : CodaApiClient, InitialPage;

void main()
{
    auto apiToken = environment.get("CODA_API_TOKEN");
    if (apiToken is null)
    {
        writeln("Error: CODA_API_TOKEN environment variable is not set");
        return;
    }

    auto coda = CodaApiClient(apiToken);

    writeln("Creating test document...");

    auto initialPage = InitialPage(
        name: "Test Page",
        subtitle: "Automated test document for mcl unit tests",
        iconName: "doc:blank",
        pageContent: InitialPage.PageContent(
            type: "canvas",
            canvasContent: InitialPage.PageContent.CanvasContent(
                format: "html",
                content: "<p>This document is used for automated testing.</p>",
            ),
        ),
    );

    auto doc = coda.createDocument(title: "MCL Test Document", initialPage: initialPage);

    writeln("Document created successfully!");
    writefln!"  ID:   %s"(doc.id);
    writefln!"  Name: %s"(doc.name);
    writefln!"  URL:  %s"(doc.browserLink);
    writeln();
    writeln("=== Manual Setup Required ===");
    writeln();
    writeln("Open the document URL above and add a table with at least one");
    writeln("text column (e.g. \"Name\"). This is needed because the Coda API");
    writeln("does not support creating tables programmatically.");
    writeln();
    writeln("Then add the following to your .env file:");
    writeln();
    writefln!"  CODA_TEST_DOC_ID=%s"(doc.id);
    writeln();
    writeln("Then source it before running tests:");
    writeln();
    writeln("  source .env");
    writeln("  dub --root ./packages/mcl/ test -- -i coda");
}
