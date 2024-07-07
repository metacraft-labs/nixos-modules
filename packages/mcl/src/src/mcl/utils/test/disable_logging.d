module packages.mcl.src.src.mcl.utils.test.unittests;

version (unittest)
{
    shared static this()
    {
        import std.logger : sharedLog, LogLevel, NullLogger;
        sharedLog = cast(shared NullLogger) new NullLogger(LogLevel.all);
    }
}
