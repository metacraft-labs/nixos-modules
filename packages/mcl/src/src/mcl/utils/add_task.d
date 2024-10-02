module mcl.commands.add_task;

import std;
import mcl.utils.log : prompt;
import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.env : optional, parseEnv;
import mcl.utils.coda : CodaApiClient, RowValues, CodaCell;

void addTask()
{
    auto apiToken = environment.get("CODA_API_TOKEN");
    auto coda = CodaApiClient(apiToken);
    auto documents = coda.listDocuments();
    auto task_db_document_id = "6vM0kjfQP6";
    auto tables = coda.listTables(task_db_document_id);
    auto taskDbRows = coda.listRows(task_db_document_id, tables[0].id);
    auto columns = coda.listColumns(task_db_document_id, tables[0].id);
    auto summary_column_id = "c-JVJN4NvAgS";
    auto parent_ticket_column_id = "c-5qcLVwbpKP";
    auto assignee_column_id = "c-UN6X8s-5Oo";
    auto status_column_id = "c-o7Utgsgdrl";
    auto priority_column_id = "c-qWRh4X8QSm";
    auto time_estimate_column_id = "c-ciqYsdyENp";
    auto milestone_column_id = "c-yIihZAmgKN";

    // if we need to add another column, find it's id from here:
    // foreach (column; columns)
    // {
    //     writeln(column);
    // }
    
    // writeln(params);
    RowValues[] rows = [
        RowValues([
            CodaCell(summary_column_id, params.taskName),
            CodaCell(parent_ticket_column_id, params.parentTicket),
            CodaCell(assignee_column_id, params.userName),
            CodaCell(status_column_id, params.status),
            CodaCell(priority_column_id, params.priority),
            CodaCell(time_estimate_column_id, params.estimate),
            CodaCell(milestone_column_id, params.milestone),
        ])
    ];

    auto resp = coda.insertRows(task_db_document_id, tables[0].id, rows);
    assert(resp.length > 0);
    writeln("response: ", resp);
}

Params params;

export void add_task()
{
    params = parseEnv!Params;
    addTask();
}
struct Params
{
    string parentTicket;
    string taskName;
    string userName;
    @optional() string status = "Backlog";
    @optional() string priority = "normal";
    @optional() string milestone;
    @optional() string estimate;

    void setup()
    {
    }
}
