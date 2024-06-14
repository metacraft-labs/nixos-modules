module packages.mcl.src.src.mcl.utils.test.unittests;
import std.logger;

shared static this()
{
    version (unittest)
    {
        sharedLog = cast(shared NullLogger) new NullLogger(LogLevel.all);
    }

}
