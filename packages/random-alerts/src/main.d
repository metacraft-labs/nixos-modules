import core.thread : Thread;
import std.datetime : Duration, Clock, seconds;
import std.format : format;
import std.getopt : getopt, getOptConfig = config;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.logger : infof, errorf, tracef, LogLevel;
import std.random : uniform;

import utils.json : toJSON;

struct Params
{
    Duration minWaitTime;
    Duration maxWaitTime;
    Duration alertDuration;
    string url;
}

struct Alert
{
    string[string] labels;
    Annotation annotations;
    string startsAt;
    string endsAt;
    string generatorURL;

    struct Annotation
    {
        string alert_type;
        string title;
        string summary;
    }
}

int main(string[] args)
{
    LogLevel logLevel = LogLevel.info;
    string url;
    int minWaitTimeInSeconds = 3600;  // 1 hour
    int maxWaitTimeInSeconds = 14400; // 4 hours
    int alertDurationInSeconds = 3600;  // 1 hour

    try
    {
        args.getopt(
            getOptConfig.required, "url", &url,
            "min-wait-time", &minWaitTimeInSeconds,
            "max-wait-time", &maxWaitTimeInSeconds,
            "alert-duration", &alertDurationInSeconds,
            "log-level", &logLevel,
        );

        setLogLevel(logLevel);

        executeAtRandomIntervals(
            Params(
                url: url,
                minWaitTime: minWaitTimeInSeconds.seconds(),
                maxWaitTime: maxWaitTimeInSeconds.seconds(),
                alertDuration: alertDurationInSeconds.seconds(),
            )
        );
    }
    catch (Exception e)
    {
        errorf("Exception: %s", e.message);
        return 1;
    }
    return 0;
}

auto getRandomDuration(Duration min, Duration max) =>
    uniform(min.total!"seconds", max.total!"seconds").seconds;

void executeAtRandomIntervals(Params params)
{
    with(params) while (true)
    {
        auto currentTime = Clock.currTime();
        Duration randomDuration = getRandomDuration(minWaitTime, maxWaitTime);
        auto randomTime = currentTime + randomDuration;
        auto waitDuration = randomTime - currentTime;

        tracef("Wait before alert: ", waitDuration);

        if (waitDuration > 0.seconds) {
            Thread.sleep(waitDuration);
        }
        infof("Posting alert... ");
        postAlert(url, alertDuration);
        infof("Alert posted successfully.");

        Duration remainingTime = maxWaitTime - randomDuration;

        tracef("Will sleep: ", remainingTime);
        Thread.sleep(remainingTime);
    }
}

void postAlert(string alertManagerEndpoint, Duration alertDuration)
{
    string url = alertManagerEndpoint ~ "/api/v2/alerts";

    postJson(url, [
        Alert(
            startsAt: Clock.currTime.toUTC.toISOExtString(0),
            endsAt: (Clock.currTime + alertDuration).toUTC.toISOExtString(0),
            generatorURL: "http://localhost:9090",
            labels: [
                "alertname": "Random alert",
                "severity": "critical",
                "environment": "staging",
                "job": "test-monitoring",
            ],
            annotations: Alert.Annotation(
                alert_type: "critical",
                title: "Write report",
                summary: "The alert was triggered at '%s'".format(Clock.currTime.toUTC)
            )
        )
    ]);
}

JSONValue postJson(T)(string url, T value)
{
    import std.net.curl : HTTP, post, HTTPStatusException;

    auto jsonRequest = value
        .toJSON
        .toPrettyString(JSONOptions.doNotEscapeSlashes);

    tracef("Sending request to '%s':\n%s", url, jsonRequest);

    auto http = HTTP();
    http.addRequestHeader("Content-Type", "application/json");

    auto response = post(url, jsonRequest, http);
    return response.parseJSON;
}

void setLogLevel(LogLevel l)
{
    import std.logger : globalLogLevel, sharedLog;
    globalLogLevel = l;
    (cast()sharedLog()).logLevel = l;
}
