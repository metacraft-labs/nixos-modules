module mcl.commands.add_task;

import std;
import mcl.utils.log : prompt;
import mcl.utils.json : toJSON, fromJSON;
import mcl.utils.env : optional, parseEnv;
import mcl.utils.coda : CodaApiClient, RowValues, CodaCell;


export void add_task(string[] args)
{
    TaskManager taskManager = new TaskManager();
    taskManager.tryLoadConfig("mcl_config.json");
    
    // writeln("config: ", taskManager.config);
    // writeln(args);

    foreach(i, arg; args.enumerate(0)) {
        // writeln("  arg ", i, " ", arg);
        if (i < 2) {
            continue; // ignore mcl and `add_task` command args
        }
        else if (arg == "--help")
        {
            writeAddTaskHelp();
            return;
        }
        else if (i == 2)
        {
            taskManager.params.taskName = arg;
        }
        else
        {
            taskManager.processArg(arg);
        }
    }
    // writeln("original params struct: ", taskManager.params);
    taskManager.resolveParams();
    taskManager.addTaskToCoda();
}

export void writeAddTaskHelp() {
    writeln("        mcl add_task <task-title> [<username/priority/status/milestone/estimate/tshirt-size> ..]");
    writeln("            <username> is `@<name>` (might be a shorter name if registered in mcl_config.json)");
    writeln("            <priority> is highest / high / normal / low");
    writeln("            <status> is backlog / ready (for ready to start) / progress (for in progress) / done / blocker / paused / cancelled");
    writeln("            <milestone> is project-specific, but can be auto-recognized based on shorter names in mcl_config.json");
    writeln("            <estimate> is time(days) estimate, needs explicit `--estimate=..` for now");
    writeln("            <tshirt-size> is S / M / L / XL");
    writeln("");
    writeln("            for all you can also pass explicit flag like `--priority=<value>");
    writeln("");
    writeln("        examples (with a hypothetical mcl_config.json):");
    writeln("            mcl add_task \"test task\" @Paul low progress beta M");
    writeln("            mcl add_task \"test task 2\" @Paul v1 L");
    writeln("            mcl add_task \"test task 3\" @John done normal M beta");
    writeln("            mcl add_task \"test task 4\" M backlog @John");
    writeln("            mcl add_task \"test task 5\"");
    writeln("            mcl add_task \"test task 6\" @Paul --priority=low backlog");
    writeln("            mcl add_task \"test task 7\" @Paul --priority=low --status=backlog");
}

struct TaskConfig {
    string codaApiToken;
    string[string] userNames;
    string defaultUserName;
    string defaultParentTicket;
    string defaultStatus;
    string defaultPriority;
    string defaultEstimate;
    string defaultTshirtSize;
    string defaultMilestone;
    string[string] milestoneShortNames;
}

class TaskManager {
    Params params;
    Params resolvedParams;
    TaskConfig config;

    void tryLoadConfig(string filename)  {
        import std.file : readText;
        import std.process: environment;
        import std.json: parseJSON, JSONValue;
        import std.stdio: stderr;
        try
        {
            string raw = readText(filename);
            JSONValue jsonConfig = parseJSON(raw);
            this.config = jsonConfig.fromJSON!TaskConfig;
        }
        catch(Throwable)
        {
            stderr.writeln("read file error: ignoring and using $CODA_API_TOKEN and empty other fields by default");
            this.config.codaApiToken = environment.get("CODA_API_TOKEN", "");
        }
    }

    string translateToUserName(string nameArg) {
        return this.config.userNames.get(nameArg, nameArg);
    }

    string translateMilestone(string name) {
        return this.config.milestoneShortNames.get(name, name);
    }

    // TODO: track cases of implicitly parsed args
    // (like "backlog" => status)
    // so in the end if we have
    // implicit args, we might prompt the user
    // maybe based on option in the config/ENV he can
    // opt-in/opt-out of this prompt
    Arg parseArg(string input) {
        // writeln("parseArg ", input);
        auto raw = input.toLower();
        
        if (raw == "highest" ||
                raw == "high" ||
                raw == "normal" ||
                raw == "low")
        {
            Arg result = { kind: "priority", value: raw };
            return result;
        }
        else if (raw.startsWith("--priority="))
        {
            // use `input`: with original casing!
            Arg result = { kind: "priority", value: input["--priority=".length..$] };
            return result;
        }
        else if (raw == "backlog")
        {
            Arg result = { kind: "status", value: "Backlog" };
            return result;
        }
        else if (raw == "ready" || raw == "ready to start")
        {
            Arg result = { kind: "status", value: "Ready to Start" };
            return result;
        }
        else if (raw == "progress" || raw == "in progress")
        {
            Arg result = { kind: "status", value: "In progress" };
            return result;
        }
        else if (raw == "review" || raw == "code review")
        {
            Arg result = { kind: "status", value: "Code review" };
            return result;
        }
        else if (raw == "done")
        {
            Arg result = { kind: "status", value: "Done" };
            return result;
        }
        else if (raw == "paused")
        {
            Arg result = { kind: "status", value: "Paused" };
            return result;
        }
        else if (raw == "cancelled")
        {
            Arg result = { kind: "status", value: "Cancelled" };
            return result;
        }
        else if (raw == "blocked")
        {
            Arg result = { kind: "status", value: "blocked" };
            return result;
        }
        else if (raw.startsWith("--status="))
        {
            // use `input`: with original casing!
            Arg result = { kind: "status", value: input["--status=".length..$] };
            return result;
        }
        else if (raw in this.config.milestoneShortNames)
        {
            auto milestone = this.translateMilestone(raw);
            Arg result = { kind: "milestone", value: milestone };
            return result;
        }
        else if (raw.startsWith("--milestone="))
        {
            // use `input`: with original casing!
            auto milestone = this.translateMilestone(input["--milestone=".length..$]);
            Arg result = { kind: "milestone", value: milestone };
            return result;
        }
        else if (raw == "s" ||
                    raw == "m" ||
                    raw == "l" ||
                    raw == "xl")
        {
            Arg result = { kind: "tshirt-size", value: raw.toUpper() };
            return result;
        }
        else if (raw.startsWith("--tshirt-size="))
        {
            Arg result = { kind: "tshirt-size", value: input["--tshirt-size=".length..$] };
            return result;
        }
        // TODO: eventually special detection of ints or `<prefix>int` (Peter's idea)
        //   as time estimates too
        else if (raw.startsWith("--estimate="))
        {
            // use `input`: with original casing!
            Arg result = { kind: "estimate", value: input["--estimate=".length..$] };
            return result;
        }
        else
        {
            throw new TaskArgException(format!"can't parse %s"(raw));
        }
    }

    void processArg(string raw)
    {
        if (raw[0] == '@')
        {
            this.params.userName = this.translateToUserName(raw[1..$]);
        }
        else
        {
            auto arg = this.parseArg(raw);
            switch (arg.kind) {
                case "priority":
                {
                    this.params.priority = arg.value;
                    break;
                }
                case "status":
                {
                    this.params.status = arg.value;
                    break;
                }
                case "milestone":
                {
                    this.params.milestone = arg.value;
                    break;
                }
                case "estimate":
                {
                    this.params.estimate = arg.value;
                    break;
                }
                case "tshirt-size":
                {
                    this.params.tshirtSize = arg.value;
                    break;
                }
                default:
                {
                    throw new TaskArgException(format!"unsupported arg kind %s"(arg.kind));
                }
            }
        }
    }

    string argOrConfigOrDefault(string arg, string configDefault, string globalDefault)
    {
        if (arg.length > 0)
        {
            return arg;
        }
        else if (configDefault.length > 0)
        {
            return configDefault;
        }
        else 
        {
            return globalDefault;
        }
    }

    void resolveParams() {
        // resolves each param:
        //   first tries in explicit command args (initial `.params`)
        //   then in default equivalents from the config
        //   finally either leaves empty or uses a general default

        this.resolvedParams.userName = this.argOrConfigOrDefault(this.params.userName, this.translateToUserName(this.config.defaultUserName), "");
        this.resolvedParams.taskName = this.params.taskName;
        this.resolvedParams.parentTicket = this.argOrConfigOrDefault(this.params.parentTicket, this.config.defaultParentTicket, "");
        this.resolvedParams.status = this.argOrConfigOrDefault(this.params.status, this.config.defaultStatus, "Backlog");
        this.resolvedParams.priority = this.argOrConfigOrDefault(this.params.priority, this.config.defaultPriority, "normal");
        this.resolvedParams.estimate = this.argOrConfigOrDefault(this.params.estimate, this.config.defaultEstimate, "");
        this.resolvedParams.tshirtSize = this.argOrConfigOrDefault(this.params.tshirtSize, this.config.defaultTshirtSize, "M");
        this.resolvedParams.milestone = this.argOrConfigOrDefault(this.params.milestone, this.translateMilestone(this.config.defaultMilestone), "");
    }

    void addTaskToCoda()
    {
        writeln("resolved params: ", this.resolvedParams);
        writeln("preparing to send to coda");

        auto coda = CodaApiClient(this.config.codaApiToken);
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
        auto tshirt_size_column_id = "c-6_I4159qaL";
        auto milestone_column_id = "c-yIihZAmgKN";

        // if we need to add another column, find it's id from here:
        // foreach (column; columns)
        // {
        //     writeln(column);
        // }        
        
        RowValues[] rows = [
            RowValues([
                CodaCell(summary_column_id, params.taskName),
                CodaCell(parent_ticket_column_id, this.resolvedParams.parentTicket),
                CodaCell(assignee_column_id, this.resolvedParams.userName),
                CodaCell(status_column_id, this.resolvedParams.status),
                CodaCell(priority_column_id, this.resolvedParams.priority),
                CodaCell(time_estimate_column_id, params.estimate),
                CodaCell(tshirt_size_column_id, params.tshirtSize),
                CodaCell(milestone_column_id, params.milestone),
            ])
        ];

        // writeln("sending ", rows);

        auto resp = coda.insertRows(task_db_document_id, tables[0].id, rows);
        assert(resp.length > 0);
        // writeln("response: ", resp);
    }
}

class TaskArgException : Exception
{
    this(string msg, string file = __FILE__, size_t line = __LINE__) {
        super(msg, file, line);
    }
}

struct Params
{
    string parentTicket;
    string taskName;
    string userName;
    string status;
    string priority;
    string milestone;
    string estimate;
    string tshirtSize;

    
    void setup()
    {
    }
}

// TODO enum kind
struct Arg {
    string kind;
    string value;
}
