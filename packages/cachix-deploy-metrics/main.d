import prometheus.registry : Registry;
import prometheus.gauge : Gauge;

import core.thread : Thread;
import core.time : dur;
import std.conv : to;
import std.process : environment;
import std.exception : ErrnoException;
import std.file : readText;
import std.format : format;
import argparse; // Andrey Zherikov's argparse (UDA-based)
import std.json : JSONType, JSONValue, parseJSON;
import std.logger : LogLevel, logf;
import std.string : strip;
import std.datetime : SysTime, Clock;
import vibe.core.args : setCommandLineArgs;
import vibe.d: HTTPServerSettings, URLRouter, listenHTTP, runApplication, HTTPServerRequest, HTTPServerResponse;
import std.net.curl : HTTP, get;

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
    logf(LogLevel.trace, "GET %s", url);
    auto conn = HTTP();
    conn.connectTimeout = dur!"seconds"(10);
    conn.operationTimeout = dur!"seconds"(20);
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
        logf(LogLevel.trace, "Agent %s startedOn=%s finishedOn=%s index=%s status=%s", agentName, started, finished, idx, (status.length ? status : ""));
    } catch (Exception e) {
        logf(LogLevel.error, "Error fetching metrics for agent '%s' (%s): %s", agentName, url, e.msg);
    }
}

void scrapeLoop(string workspace, string authToken, string[] agents, int scrapeIntervalSec) {
    while (true) {
        foreach (agentName; agents) {
            fetchAgentMetrics(workspace, authToken, agentName);
        }
        Thread.sleep(dur!"seconds"(scrapeIntervalSec));
    }
}

int main(string[] args) {
    struct CliArgs {
        @(NamedArgument(["port"])
            .Description("Port to listen on (default: 9160)"))
        int port = 9160;

        @(NamedArgument(["listen-address"])
            .Description("Address to bind (default: 127.0.0.1)"))
        string listenAddress = "127.0.0.1";

        @(NamedArgument(["scrape-interval"])
            .Description("Scrape interval in seconds (default: 10)"))
        int scrapeInterval = 10;

        @(NamedArgument(["auth-token-path"])
            .Description("Path to Cachix auth token (required if CACHIX_AUTH_TOKEN is unset)"))
        string tokenPath;

        @(NamedArgument(["workspace"])
            .Description("Cachix workspace name (required)")
            .Required())
        string workspace;

        @(NamedArgument(["agent-names", "a"])
            .Description("Agent names (repeatable)")
            .Required())
        string[] agents;
    }

    CliArgs opts;
    auto res = CLI!(Config.init, CliArgs).parseArgs(opts, args.length > 1 ? args[1 .. $] : []);
    if (!res) return res.resultCode;

    if (args.length > 0) setCommandLineArgs([args[0]]);

    string authToken = environment.get("CACHIX_AUTH_TOKEN");
    try {
        if (!authToken) authToken = readText(opts.tokenPath).strip();
    } catch (Exception e) {
        logf(LogLevel.error, "Token file '%s' not found or unreadable.", opts.tokenPath);
        return 2;
    }

    gWorkspace = opts.workspace;
    promInit();
    foreach (agentName; opts.agents) {
        foreach (s; CACHIX_DEPLOY_STATES) {
            promSetStatus(agentName, s, long.min);
        }
    }

    auto settings = new HTTPServerSettings;
    settings.port = cast(ushort)opts.port;
    bool listenSpecified = opts.listenAddress.length != 0;
    if (listenSpecified) settings.bindAddresses = [opts.listenAddress];

    auto router = new URLRouter;
    router.get("/metrics", (HTTPServerRequest req, HTTPServerResponse res) {
        string buf;
        foreach (m; Registry.global.metrics) {
            auto snap = m.collect();
            buf ~= snap.encode();
        }
        res.writeBody(cast(ubyte[])buf, "text/plain; version=0.0.4; charset=utf-8");
    });

    if (opts.agents.length) {
        auto t = new Thread({ scrapeLoop(opts.workspace, authToken, opts.agents, opts.scrapeInterval); });
        t.isDaemon = true;
        t.start();
    } else {
        logf(LogLevel.warning, "No --agent-names provided; only /metrics with static counters will be served.");
    }

    listenHTTP(settings, router);
    runApplication;
    return 0;
}
