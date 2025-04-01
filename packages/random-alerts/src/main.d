import core.thread : Thread;
import std.datetime : Duration, Clock, seconds, TimeOfDay;
import std.format : format;
import std.getopt : getopt, getOptConfig = config, arraySep;
import std.json : JSONValue, parseJSON, JSONOptions;
import std.logger : infof, errorf, tracef, LogLevel;
import std.random : uniform;
import std.exception : enforce;

import utils.json : toJSON;

struct Params
{
    Duration minWaitTime;
    Duration maxWaitTime;
    Duration alertDuration;
    string[] urls;
    TimeOfDay startTime;
    TimeOfDay endTime;
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
    string[] urls;
    string startTime = "00:00:00";
    string endTime = "23:59:59";
    uint minWaitTimeInSeconds = 3600;  // 1 hour
    uint maxWaitTimeInSeconds = 14400; // 4 hours
    uint alertDurationInSeconds = 3600;  // 1 hour

    try
    {
        arraySep = ",";
        args.getopt(
            getOptConfig.required, "urls", &urls,
            "start-time", &startTime,
            "end-time", &endTime,
            "min-wait-time", &minWaitTimeInSeconds,
            "max-wait-time", &maxWaitTimeInSeconds,
            "alert-duration", &alertDurationInSeconds,
            "log-level", &logLevel,
        );

        enforce(minWaitTimeInSeconds <= maxWaitTimeInSeconds, "Make sure that `max-wait-time` is greater than `min-wait-time`.");

        setLogLevel(logLevel);


        executeAtRandomIntervals(
            Params(
                urls: urls,
                startTime: TimeOfDay.fromISOExtString(startTime),
                endTime: TimeOfDay.fromISOExtString(endTime),
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
        auto currentTimeTOD = cast(TimeOfDay)currentTime;
        Duration randomDuration = getRandomDuration(minWaitTime, maxWaitTime);
        auto randomTime = currentTime + randomDuration;

        tracef("The operating time is: [%s .. %s]", startTime, endTime);
        tracef("The next alarm will be activated in %s", randomTime);

        Thread.sleep(randomDuration); // sleep till the request is ready to be posted.

        if (currentTimeTOD >= startTime && currentTimeTOD <= endTime)
        {
            foreach (url; urls)
            {
                infof("Posting alert on %s...", url);
                postAlert(url, alertDuration);
                infof("Alert posted successfully.");
            }
        }
        else
        {
            infof("This service is outside working hours. The operating time is: [%s .. %s]", startTime, endTime);
        }

        Duration remainingTime = maxWaitTime - randomDuration;

        tracef("The current interval's end will be at %s", (currentTime + remainingTime));
        Thread.sleep(remainingTime); // sleep till the cycle is over.
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

JSONValue postJson(T)(string url, in T value)
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
