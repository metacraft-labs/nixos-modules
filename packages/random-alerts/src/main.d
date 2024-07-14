import std;
import core.thread;
import prometheus.counter;
import prometheus.registry;
import prometheus.gauge;

import prometheus.vibe;

import vibe.d;


void main()
{
    auto alertsArray = alertsArrayGenerator(6);
    auto timeZone = PosixTimeZone.getTimeZone("Europe/Sofia");
    auto tid = spawn(&prometheusService);
    Thread.sleep(5.seconds);
    writeln("Prometheus service is running in the background.");

    Gauge c = new Gauge("example_gauge", "A gauge that increases to 1 for 10 seconds and then decreases to 0", []);
    c.register;

    while(true)
    {

        auto today = cast()Clock.currTime.toISOExtString;
        auto timeInSofia = cast(TimeOfDay)SysTime.fromISOExtString(
            today, timeZone
        );
        writefln("Time in Sofia/Bulgaria: %s", timeInSofia);
        newline.writeln;

        // auto beforeAtAndAfter = partition3(alertsArray, timeInSofia);
        // beforeAtAndAfter.writeln;

        foreach(time; alertsArray) // .find!(a => a > timeInSofia))
        {
            Duration timeToWait = time - timeInSofia;
            if (timeToWait.total!"seconds" < 0) {
                timeToWait += 24.hours;
            }

            writefln("Next alert: %s", time);
            writefln("Time to wait until next alert: %s", timeToWait);
            newline.writeln;

            // Thread.sleep(timeToWait);
            writeln(c);
            Thread.sleep(5.seconds);
            c.set(0);
            Thread.sleep(5.seconds);
            c.set(1);
        }
    }
}

TimeOfDay[] alertsArrayGenerator(int charts)
{
    TimeOfDay[] randomIntervalArray;
    Duration shiftEqualIntervals = 1.days / charts;
    long shiftEqualIntervalsInSeconds = shiftEqualIntervals.total!"seconds";
    TimeOfDay dayStart = TimeOfDay(0, 0, 0);

    foreach(interval; 0..charts)
    {
        TimeOfDay intervalStart = dayStart + interval * shiftEqualIntervals;
    	long randomSecondsInterval = uniform(0, shiftEqualIntervalsInSeconds);
        TimeOfDay randomTimeInterval = intervalStart + randomSecondsInterval.seconds;
        randomIntervalArray ~= randomTimeInterval;
    }
    return randomIntervalArray;
}

void prometheusService()
{
    auto settings = new HTTPServerSettings;
    settings.bindAddresses = ["127.0.0.1"];
    settings.port = 8989;

    auto router = new URLRouter;
    router.get("/metrics", handleMetrics(Registry.global));

    listenHTTP(settings, router);
    runApplication;
}

