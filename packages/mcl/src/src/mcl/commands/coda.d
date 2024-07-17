module mcl.commands.coda;

import mcl.utils.coda;
import mcl.utils.env : optional, parseEnv;
import std.stdio;
import std.array : split;
import std.algorithm : filter;
import std.process : environment;
import std.range;



export void coda()
{
    const params = parseEnv!Params;
    // Get the Coda API token from environment variable
    string apiToken = params.codaApiToken;

    if (apiToken.empty) {
        writeln("Error: CODA_API_TOKEN is not set.");
        return;
    }

    // Initialize Coda API client
    CodaApiClient coda = CodaApiClient(apiToken);

    // Define the document and table ID
    string documentId = "d77XANJj1jZ";
    string tableId = "grid-suGP6";

    try {
        // Fetch all rows from the table
        auto rows = coda.listRows(documentId, tableId);

        // Filter rows where the "Assignee" column contains "Franz Fischbach"
        //auto filteredRows = filter!(row => row.values["Assignee"].get!(string) == "Franz Fischbach")(rows);

        // Print the content of each filtered row
        foreach (row; rows) {
            writeln("Row ID: ", row.id);
            foreach (key, value; row.values) {
                writeln(key, ": ", value);
            }
            writeln();
        }
    } catch (Exception e) {
        writeln("An error occurred: ", e.msg);
    }
}

// Define the Params structure if needed
struct Params
{
    string codaApiToken;
    void setup()
    {
    }
}
