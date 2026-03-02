module mcl.utils.coda.client;

import std.net.curl : HTTP, httpGet = get, httpPost = post, httpDelete = del, httpPatch = patch, httpPut = put, HTTPStatusException;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.format : format;
import std.traits : isArray;
import std.exception : assertThrown;
import std.process : environment;
import core.thread : Thread;
import core.time : seconds, msecs;

import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.coda.types;

version (unittest)
{
    import std.uuid : randomUUID;

    string testDocId() { return environment.get("CODA_TEST_DOC_ID", ""); }

    /// Generate a unique test marker to identify rows created by this test instance
    string testMarker() { return randomUUID().toString(); }
}

struct CodaApiClient
{
    string apiToken;
    string baseEndpoint = "https://coda.io/apis/v1";

    Document getDocument(string documentId)
    {
        string url = "/docs/%s".format(documentId);
        return get!Document(url);
    }

    @("coda.getDocument")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.getDocument(testDocId());
        assert(resp.id == testDocId());
    }

    Document[] listDocuments()
    {
        string url = "/docs";
        return get!(Document[])(url);
    }

    @("coda.listDocuments")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.listDocuments();
        assert(resp.length > 0);
    }

    Document createDocument(string title, string sourceDoc = "", string timezone = "Europe/Sofia", string folderID = "", InitialPage initialPage = InitialPage.init)
    {
        string url = "/docs";
        JSONValue req = JSONValue(
            [
                "title": JSONValue(title),
                "initialPage": initialPage.toJSON,
                "timezone": JSONValue(timezone)
            ]);
        if (sourceDoc != "")
            req["sourceDoc"] = JSONValue(sourceDoc);
        if (folderID != "")
            req["folderId"] = JSONValue(folderID);

        if (req["initialPage"].object["imageUrl"].str == "")
            req["initialPage"].object.remove("imageUrl");
        if (req["initialPage"].object["parentPageId"].str == "")
            req["initialPage"].object.remove("parentPageId");

        return post!Document(url, req);
    }

    void deleteDocument(string documentId)
    {
        string url = "/docs/%s".format(documentId);
        del!Document(url);
    }

    @("coda.createDocument/deleteDocument")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto initialPage = InitialPage(
            name: "Test Page",
            subtitle: "Test Subtitle",
            iconName: "doc:blank",
            pageContent: InitialPage.PageContent(
                type: "canvas",
                canvasContent: InitialPage.PageContent.CanvasContent(
                    format: "html",
                    content: "<p><b>This</b> is rich text</p>",
                ),
            ),
        );
        auto resp = coda.createDocument(title: "Test Document", initialPage: initialPage);
        assert(resp.name == "Test Document");
        coda.deleteDocument(resp.id);
        assertThrown!(HTTPStatusException)(coda.getDocument(resp.id));
    }

    Document patchDocument(string documentId, string title = "", string iconName = "")
    {
        JSONValue req = JSONValue();
        if (title != "")
            req["title"] = JSONValue(title);
        if (iconName != "")
            req["icon"] = JSONValue(iconName);

        string url = "/docs/%s".format(documentId);
        return patch!Document(url, req);
    }

    @("coda.patchDocument")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto initialPage = InitialPage(
            name: "Test Page",
            subtitle: "Test Subtitle",
            iconName: "doc:blank",
            pageContent: InitialPage.PageContent(
                type: "canvas",
                canvasContent: InitialPage.PageContent.CanvasContent(
                    format: "html",
                    content: "<p><b>This</b> is rich text</p>",
                ),
            ),
        );
        auto resp = coda.createDocument(title: "Test Document", initialPage: initialPage);
        coda.patchDocument(resp.id, title: "Patched Document");
        auto patched = coda.getDocument(resp.id);
        assert(patched.name == "Patched Document");
        coda.deleteDocument(patched.id);
    }

    Table[] listTables(string documentId)
    {
        string url = "/docs/%s/tables".format(documentId);
        return get!(Table[])(url);
    }

    @("coda.listTables")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.listTables(testDocId());
        assert(resp.length > 0);
    }

    Table getTable(string documentId, string tableId)
    {
        string url = "/docs/%s/tables/%s".format(documentId, tableId);
        return get!Table(url);
    }

    @("coda.getTable")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables(testDocId());
        auto resp = coda.getTable(testDocId(), tables[0].id);
        assert(resp.id == tables[0].id);
    }

    Column[] listColumns(string documentId, string tableId)
    {
        string url = "/docs/%s/tables/%s/columns".format(documentId, tableId);
        return get!(Column[])(url);
    }

    @("coda.listColumns")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables(testDocId());
        auto resp = coda.listColumns(testDocId(), tables[0].id);
        assert(resp.length > 0);
    }

    Column getColumn(string documentId, string tableId, string columnId)
    {
        string url = "/docs/%s/tables/%s/columns/%s".format(documentId, tableId, columnId);
        return get!Column(url);
    }

    @("coda.getColumn")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables(testDocId());
        auto columns = coda.listColumns(testDocId(), tables[0].id);
        auto resp = coda.getColumn(testDocId(), tables[0].id, columns[0].id);
        assert(resp.id == columns[0].id);
    }

    Row[] listRows(string documentId, string tableId)
    {
        string url = "/docs/%s/tables/%s/rows".format(documentId, tableId);
        return get!(Row[])(url);
    }

    @("coda.listRows")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto marker = testMarker();
        auto tables = coda.listTables(testDocId());
        auto columns = coda.listColumns(testDocId(), tables[0].id);
        // Insert a row with unique marker so we can identify it
        auto inserted = coda.insertRows(testDocId(), tables[0].id, [
            RowValues([CodaCell(columns[0].id, "ListRows " ~ marker)])
        ]);
        auto resp = coda.listRows(testDocId(), tables[0].id);
        assert(resp.length > 0);
        coda.deleteRow(testDocId(), tables[0].id, inserted[0]);
    }

    string[] insertRows(string documentId, string tableId, RowValues[] rows, string[] keyColumns = [])
    {
        string url = "/docs/%s/tables/%s/rows".format(documentId, tableId);
        JSONValue req = JSONValue(
            [
                "rows": rows.toJSON
            ]);
        if (keyColumns.length)
            req["keyColumns"] = JSONValue(keyColumns.toJSON);
        return post!InsertRowsReturn(url, req).addedRowIds;
    }

    // Can't be implemented because of the lack of support for a body in DELETE requests
    // void deleteRows(string documentId, string tableId, string[] rowIds)
    // {
    //     string url = "/docs/%s/tables/%s/rows".format(documentId, tableId);
    //     JSONValue req = JSONValue(
    //         [
    //             "rowIds": JSONValue(rowIds)
    //         ]);
    //     del!Row(url, req);
    // }

    void deleteRow(string documentId, string tableId, string rowId)
    {
        string url = "/docs/%s/tables/%s/rows/%s".format(documentId, tableId, rowId);
        del!Row(url);
    }

    @("coda.insertRows/deleteRow")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto marker = testMarker();
        auto tables = coda.listTables(testDocId());
        auto columns = coda.listColumns(testDocId(), tables[0].id);
        RowValues[] rows = [
            RowValues([
                CodaCell(columns[0].id, "InsertDelete " ~ marker),
            ])
        ];
        auto resp = coda.insertRows(testDocId(), tables[0].id, rows);
        assert(resp.length > 0);
        coda.deleteRow(testDocId(), tables[0].id, resp[0]);
        Thread.sleep(5.seconds); // Coda eventual consistency for deletion
        assertThrown!(HTTPStatusException)(coda.getRow(testDocId(), tables[0].id, resp[0]));
    }

    Row getRow(string documentId, string tableId, string rowId)
    {
        string url = "/docs/%s/tables/%s/rows/%s".format(documentId, tableId, rowId);
        return get!Row(url);
    }

    @("coda.getRow")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables(testDocId());
        auto columns = coda.listColumns(testDocId(), tables[0].id);
        // Insert a row so we have something to get
        auto inserted = coda.insertRows(testDocId(), tables[0].id, [
            RowValues([CodaCell(columns[0].id, "GetRow " ~ testMarker())])
        ]);
        Thread.sleep(5.seconds); // Coda eventual consistency
        // Use listRows to get a valid row ID (Coda's insertRows returns temporary IDs)
        auto allRows = coda.listRows(testDocId(), tables[0].id);
        assert(allRows.length >= 1, "Expected at least one row after insert");
        auto resp = coda.getRow(testDocId(), tables[0].id, allRows[$ - 1].id);
        assert(resp.id == allRows[$ - 1].id);
        coda.deleteRow(testDocId(), tables[0].id, inserted[0]);
    }

    string updateRow(string documentId, string tableId, string rowId, RowValues row, string[] keyColumns = [])
    {
        string url = "/docs/%s/tables/%s/rows/%s".format(documentId, tableId, rowId);
        JSONValue req = JSONValue(
            [
                "row": row.toJSON
            ]);
        return put!UpdateRowReturn(url, req).id;
    }

    @("coda.updateRow")
    unittest
    {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto tables = coda.listTables(testDocId());
        auto columns = coda.listColumns(testDocId(), tables[0].id);
        auto colId = columns[0].id;
        auto marker = testMarker();
        auto inserted = coda.insertRows(testDocId(), tables[0].id, [
            RowValues([CodaCell(colId, "UpdateRow " ~ marker)])
        ]);
        Thread.sleep(5.seconds); // Coda eventual consistency
        // Use listRows to get a valid row ID (Coda's insertRows returns temporary IDs)
        auto allRows = coda.listRows(testDocId(), tables[0].id);
        assert(allRows.length >= 1, "Expected at least one row after insert");
        auto rowId = allRows[$ - 1].id;
        auto newRow = RowValues([CodaCell(colId, "Updated " ~ marker)]);

        auto updated = coda.updateRow(testDocId(), tables[0].id, rowId, newRow);

        assert(updated == rowId);
        coda.deleteRow(testDocId(), tables[0].id, inserted[0]);
    }

    void upsertRow(string docId, string tableId, RowValues values, string[] keyColumns = ["name"]) {
        insertRows(docId, tableId, [values], keyColumns);
    }

    void upsertRows(string docId, string tableId, RowValues[] values, string[] keyColumns = ["name"]) {
        insertRows(docId, tableId, values, keyColumns);
    }

    PushButtonResponse pushButton(string documentId, string tableId, string rowId, string columnId) {
        string url = "/docs/%s/tables/%s/rows/%s/buttons/%s".format(documentId, tableId, rowId, columnId);
        return post!PushButtonResponse(url);
    }

    // Note: pushButton requires a doc with a button column, which cannot
    // be created via the API. To test manually, set CODA_TEST_BUTTON_COLUMN
    // and CODA_TEST_BUTTON_ROW environment variables pointing to a button
    // column and a row in the test document's first table.

    Category[] listCategories()
    {
        string url = "/categories";
        return get!(Category[])(url);
    }

    @("coda.listCategories")
    unittest {
        auto apiToken = environment.get("CODA_API_TOKEN");
        auto coda = CodaApiClient(apiToken);
        auto resp = coda.listCategories();
        assert(resp.length > 0);
    }

    void triggerAutomation(string documentId, string automationId, JSONValue req)
    {
        string url = "/docs/%s/hooks/automation/%s".format(documentId, automationId);
        post!JSONValue(url, req);
    }

    // Note: triggerAutomation requires a doc with an automation rule,
    // which cannot be created via the API. To test manually, set
    // CODA_TEST_AUTOMATION_ID environment variable.

    static foreach (method; [HTTP.Method.get, HTTP.Method.post, HTTP.Method.del, HTTP.Method.patch, HTTP.Method.put])
    {
        mixin(q{
            Response %s(Response)(string endpoint, JSONValue req = JSONValue(null),
                bool retry = true, int maxRetries = 10)
            {
                if (retry) {
                    foreach (i; 0 .. maxRetries) {
                        try {
                            return httpRequest!(method, Response)(endpoint, req);
                        }
                        catch (HTTPStatusException e) {
                            if (e.status != 429 && e.status < 500)
                                throw e;
                            if (e.status == 429)
                                Thread.sleep(6.seconds);  // Rate limit window is 6-10s
                            else
                                Thread.sleep(1.seconds * (1 << i));  // Exponential backoff for 5xx
                        }
                    }
                }
                return httpRequest!(method, Response)(endpoint, req);
            }
        }.format(method));

    }

    Response httpRequest(HTTP.Method method, Response)(string endpoint,
        JSONValue req = JSONValue(null))
    {
        import std.string : indexOf;

        JSONValue resp = httpRequest!(method)(endpoint, req);

        static if (isArray!Response)
        {
            // Accumulate paginated results
            auto items = "items" in resp
                ? resp["items"].fromJSON!Response
                : resp.fromJSON!Response;

            while (auto nextToken = "nextPageToken" in resp)
            {
                auto separator = endpoint.indexOf('?') == -1 ? "?" : "&";
                auto nextEndpoint = endpoint ~ separator ~ "pageToken=" ~ nextToken.str;
                resp = httpRequest!(method)(nextEndpoint, req);
                items ~= "items" in resp
                    ? resp["items"].fromJSON!Response
                    : resp.fromJSON!Response;
            }

            return items;
        }
        else static if (is(Response == JSONValue))
            return resp;
        else
            return resp.fromJSON!Response;
    }

    JSONValue httpRequest(HTTP.Method method)(
        string endpoint,
        JSONValue req = JSONValue(null))
    {
        import std.string : indexOf;

        auto http = HTTP();
        http.addRequestHeader("Content-Type", "application/json");
        http.addRequestHeader("Authorization", "Bearer " ~ this.apiToken);

        auto url = baseEndpoint ~ endpoint;

        static if (method == HTTP.Method.get)
        {
            auto resp = httpGet(url, http);
            return parseJSON(resp);
        }
        else static if (method == HTTP.Method.post)
        {
            auto reqBody = req.toString(JSONOptions.doNotEscapeSlashes);
            reqBody = (reqBody == "null") ? "" : reqBody;
            auto resp = httpPost(url, reqBody, http);
            return parseJSON(resp);
        }
        else static if (method == HTTP.Method.put)
        {
            auto reqBody = req.toString(JSONOptions.doNotEscapeSlashes);
            reqBody = (reqBody == "null") ? "" : reqBody;
            auto resp = httpPut(url, reqBody, http);
            return parseJSON(resp);
        }
        else static if (method == HTTP.Method.del)
        {
            httpDelete(url, http);
            return parseJSON("{}");
        }
        else static if (method == HTTP.Method.patch)
        {
            auto reqBody = req.toString(JSONOptions.doNotEscapeSlashes);
            reqBody = (reqBody == "null") ? "" : reqBody;
            auto resp = httpPatch(url, reqBody, http);
            return parseJSON(resp);
        }
        else
            static assert(0, "Please implement " ~ method);
    }
}
