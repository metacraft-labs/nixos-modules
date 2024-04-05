module mcl.utils.test;
import std.logger;

shared static this()
{
    version (unittest)
    {
        sharedLog = cast(shared NullLogger) new NullLogger(LogLevel.all);
    }

}
