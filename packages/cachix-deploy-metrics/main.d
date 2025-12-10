import core.thread : Thread;
import core.time : seconds;

import std.conv : to;
import std.datetime : SysTime, Clock;
import std.file : readText;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.logger : errorf, logf, tracef, warningf, LogLevel;
import std.string : strip;

import vibe.core.args : setCommandLineArgs;
import vibe.core.core : setTimer;
import vibe.d: HTTPServerSettings,
    URLRouter,
    listenHTTP,
    runApplication,
    HTTPServerRequest,
    HTTPServerResponse;

import prometheus.counter : Counter;
import prometheus.gauge : Gauge;
import prometheus.registry : Registry;
import prometheus.vibe : handleMetrics;

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

        @(NamedArgument(["bind-addresses"]).Description("Addresses to bind (one or more)").EnvFallback("HOST"))
        string[] bindAddresses = ["127.0.0.1"];
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
    if (args.bindAddresses.length) settings.bindAddresses = args.bindAddresses;

    auto router = new URLRouter;

    router.get("/metrics", handleMetrics(Registry.global));

    // Fetch the metrics once at startup
    fetchAgentMetrics(args.workspace, args.cachixAuthToken, args.agents);

    setTimer(
        args.scrapeInterval.seconds,
        () => fetchAgentMetrics(args.workspace, args.cachixAuthToken, args.agents),
        true
    );

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

auto httpGetJson(string url, string authToken) {
    import vibe.http.common : HTTPMethod;
    import vibe.stream.operations : readAllUTF8;
    import vibe.http.client : requestHTTP, HTTPClientSettings;
    import mcl.utils.json : fromJSON;

    struct LastDepoyment {
        string status;
        int index;
        string startedOn;
        string finishedOn;
    }

    struct AgentMetrics {
        LastDepoyment lastDeployment;
    }

    tracef("GET %s", url);

    auto settings = new HTTPClientSettings;
    settings.connectTimeout = 10.seconds;
    settings.readTimeout = 20.seconds;

    auto res = requestHTTP(url, (scope req) {
        req.headers["Authorization"] = "Bearer " ~ authToken;
    }, settings);

    string body = res.bodyReader.readAllUTF8();
    return fromJSON!AgentMetrics(parseJSON(body));
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

void fetchAgentMetricsForHostname(string workspace, string authToken, string hostname) {
    auto url = format("%s/api/v1/deploy/agent/%s/%s", "https://app.cachix.org", workspace, hostname);
    try {
        auto jsonData = httpGetJson(url, authToken);
        auto last = jsonData.lastDeployment;

        promSetStatus(hostname, last.status, last.index);
        promSetTimes(hostname, last.startedOn, last.finishedOn);
        promSetInProgressDuration(hostname, last.status, last.startedOn);

        tracef(
            "Agent %s startedOn=%s finishedOn=%s index=%s status=%s",
            hostname,
            last.startedOn,
            last.finishedOn,
            last.index,
            last.status
        );
    } catch (Exception e) {
        errorf("Error fetching metrics for agent '%s' (%s): %s", hostname, url, e.msg);
    }
}

void fetchAgentMetrics(string workspace, string cachixAuthToken, string[] agents) {
    foreach (hostname; agents) {
        fetchAgentMetricsForHostname(workspace, cachixAuthToken, hostname);
    }
}
