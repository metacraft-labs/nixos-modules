import core.thread : Thread;
import core.time : seconds;

import std.conv : to;
import std.datetime : SysTime, Clock;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.logger : errorf, logf, tracef, warningf, LogLevel;
import std.net.curl : HTTP, get;
import std.string : strip;

import vibe.core.args : setCommandLineArgs;
import vibe.d: HTTPServerSettings,
    URLRouter,
    listenHTTP,
    runApplication,
    HTTPServerRequest,
    HTTPServerResponse;

import prometheus.counter : Counter;
import prometheus.gauge : Gauge;
import prometheus.registry : Registry;

import argparse : CLI,
    Command,
    ArgumentGroup,
    NamedArgument,
    Description,
    EnvFallback,
    MutuallyExclusive,
    Required;

@(Command("cachix-deploy-metric")
.Description(
"A Prometheus exporter for Cachix Deploy agent metrics. It scrapes agent
status, deployment times, and indices from the Cachix API and exposes them via
an HTTP endpoint."))
struct CachixDeployMetrics
{
    @(ArgumentGroup("Server configuration"))
    {
        @(NamedArgument.Description("Port to listen on").EnvFallback("PORT"))
        ushort port = 9160;

        @(NamedArgument(["listen-address"]).Description("Address to bind").EnvFallback("HOST"))
        string listenAddress = "127.0.0.1";
    }

    @(NamedArgument(["scrape-interval"]).Description("Scrape interval in seconds"))
    int scrapeInterval = 10;

    @NamedArgument(["log-level"])
    LogLevel logLevel = LogLevel.info;

    @(ArgumentGroup("Cachix configuration"))
    {
        @(MutuallyExclusive.Required())
        {
            @(NamedArgument(["auth-token"])
                .Description("Cachix auth token")
                .EnvFallback("CACHIX_AUTH_TOKEN")
            )
            string cachixAuthToken;

            @(NamedArgument(["auth-token-path"])
                .Description("Path to Cachix auth token")
                .EnvFallback("CACHIX_AUTH_TOKEN_PATH")
            )
            string cachixAuthTokenPath;
        }

        @(NamedArgument(["workspace"])
            .Description("Cachix workspace name (required)")
            .Required()
        )
        string workspace;

        @(NamedArgument(["agent-names", "a"])
            .Description("Agent names (one or more)")
            .Required()
        )
        string[] agents;
    }
}

mixin CLI!CachixDeployMetrics.main!((args)
{
    import std.logger : globalLogLevel, sharedLog;
    globalLogLevel = args.logLevel;
    (cast()sharedLog()).logLevel = args.logLevel;

    try
    {
        if (!args.cachixAuthToken.length)
        {
            logf("Cachix auth token was not specified directly. Reading token from: %s", args.cachixAuthTokenPath);
            args.cachixAuthToken = readText(args.cachixAuthTokenPath).strip();
        }
        if (!args.cachixAuthToken.length)
        {
            errorf("Token file '%s' was empty.", args.cachixAuthTokenPath);
            return 2;
        }
    }
    catch (Exception e)
    {
        errorf("Token file '%s' not found or unreadable.", args.cachixAuthTokenPath);
        return 2;
    }

    gWorkspace = args.workspace;
    promInit();
    foreach (agentName; args.agents) {
        foreach (s; CACHIX_DEPLOY_STATES) {
            promSetStatus(agentName, s, long.min);
        }
    }

    auto settings = new HTTPServerSettings;
    settings.port = args.port;
    if (args.listenAddress) settings.bindAddresses = [args.listenAddress];

    auto router = new URLRouter;
    router.get("/metrics", (HTTPServerRequest req, HTTPServerResponse res) {
        string buf;
        foreach (m; Registry.global.metrics) {
            auto snap = m.collect();
            buf ~= snap.encode();
        }
        res.writeBody(cast(ubyte[])buf, "text/plain; version=0.0.4; charset=utf-8");
    });

    if (args.agents.length) {
        auto t = new Thread({ scrapeLoop(args.workspace, args.cachixAuthToken, args.agents, args.scrapeInterval); });
        t.isDaemon = true;
        t.start();
    } else {
        warningf("No --agent-names provided; only /metrics with static counters will be served.");
    }

    listenHTTP(settings, router);
    runApplication;

    return 0;
});

const string[] CACHIX_DEPLOY_STATES = ["Pending", "InProgress", "Cancelled", "Failed", "Succeeded"];

__gshared Gauge statusGauge;
__gshared Gauge indexGauge;
__gshared Gauge startedGauge;
__gshared Gauge finishedGauge;
__gshared Gauge inProgressDurationGauge;
__gshared string gWorkspace;
const string[] FINISHED_KEYS = ["endedOn", "finishedOn", "completedOn"];

void promInit() {
    statusGauge = new Gauge("cachix_deploy_status", "Status of the last deploy", ["workspace", "agent", "status"]);
    statusGauge.register;
    indexGauge = new Gauge("cachix_deploy_counter", "Counter/index of deploys.", ["workspace", "agent"]);
    indexGauge.register;
    startedGauge = new Gauge("cachix_deploy_last_started_time", "Unix time when the last deploy started.", ["workspace", "agent"]);
    startedGauge.register;
    finishedGauge = new Gauge("cachix_deploy_last_finished_time", "Unix time when the last deploy finished (if any).", ["workspace", "agent"]);
    finishedGauge.register;
    inProgressDurationGauge = new Gauge("cachix_deploy_in_progress_duration_seconds", "Seconds elapsed for the current in-progress deploy.", ["workspace", "agent"]);
    inProgressDurationGauge.register;
}

void promSetStatus(string agentName, string status, long indexVal) {
    auto ws = gWorkspace;
    foreach (s; CACHIX_DEPLOY_STATES) {
        statusGauge.set(s == status ? 1.0 : 0.0, [ws, agentName, s]);
    }
    if (indexVal != long.min) {
        indexGauge.set(cast(double) indexVal, [ws, agentName]);
    }
}

JSONValue httpGetJson(string url, string authToken) {
    tracef("GET %s", url);
    auto conn = HTTP();
    conn.connectTimeout = 10.seconds;
    conn.operationTimeout = 20.seconds;
    conn.addRequestHeader("Authorization", "Bearer " ~ authToken);
    auto bodyArr = get!(HTTP, char)(url, conn);
    auto body = bodyArr.idup;
    return parseJSON(body);
}

private:
bool tryIsoToUnix(string iso, out double outVal) {
    try {
        auto t = SysTime.fromISOExtString(iso);
        outVal = cast(double) t.toUnixTime();
        return true;
    } catch (Exception) {
        return false;
    }
}

void promSetTimes(string agentName, string startedOn, string finishedOn) {
    auto ws = gWorkspace;
    double v;
    if (startedOn.length && tryIsoToUnix(startedOn, v)) {
        startedGauge.set(v, [ws, agentName]);
    }
    if (finishedOn.length && tryIsoToUnix(finishedOn, v)) {
        finishedGauge.set(v, [ws, agentName]);
    }
}

void promSetInProgressDuration(string agentName, string status, string startedOn) {
    auto ws = gWorkspace;
    if (status == "InProgress") {
        double startUnix;
        if (startedOn.length && tryIsoToUnix(startedOn, startUnix)) {
            auto nowUnix = cast(double) Clock.currTime().toUnixTime();
            auto diff = nowUnix - startUnix;
            if (diff < 0) diff = 0;
            inProgressDurationGauge.set(diff, [ws, agentName]);
            return;
        }
    }
    inProgressDurationGauge.set(0, [ws, agentName]);
}

void fetchAgentMetrics(string workspace, string authToken, string agentName) {
    auto url = format("%s/api/v1/deploy/agent/%s/%s", "https://app.cachix.org", workspace, agentName);
    try {
        auto data = httpGetJson(url, authToken);
        JSONValue last;
        if (data.type == JSONType.object && "lastDeployment" in data.object) {
            last = data["lastDeployment"];
        }

        string status;
        long indexVal = long.min;
        string startedOn;
        string finishedOn;

        if (last.type == JSONType.object) {
            if ("status" in last.object && last["status"].type == JSONType.string) {
                status = last["status"].str;
            }
            if ("index" in last.object && (last["index"].type == JSONType.integer || last["index"].type == JSONType.uinteger)) {
                indexVal = last["index"].integer;
            }
            if ("startedOn" in last.object && last["startedOn"].type == JSONType.string) {
                startedOn = last["startedOn"].str;
            }
            foreach (k; FINISHED_KEYS) {
                if (k in last.object && last[k].type == JSONType.string) {
                    finishedOn = last[k].str;
                    break;
                }
            }
        }

        promSetStatus(agentName, status, indexVal);
        promSetTimes(agentName, startedOn, finishedOn);
        promSetInProgressDuration(agentName, status, startedOn);

        auto started = startedOn.length ? startedOn : "";
        auto finished = finishedOn.length ? finishedOn : "";
        auto idx = (indexVal == long.min) ? "" : to!string(indexVal);
        tracef("Agent %s startedOn=%s finishedOn=%s index=%s status=%s", agentName, started, finished, idx, (status.length ? status : ""));
    } catch (Exception e) {
        errorf("Error fetching metrics for agent '%s' (%s): %s", agentName, url, e.msg);
    }
}

void scrapeLoop(string workspace, string authToken, string[] agents, int scrapeIntervalSec) {
    while (true) {
        foreach (agentName; agents) {
            fetchAgentMetrics(workspace, authToken, agentName);
        }
        Thread.sleep(scrapeIntervalSec.seconds);
    }
}
