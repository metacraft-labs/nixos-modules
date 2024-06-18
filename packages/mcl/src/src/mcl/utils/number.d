module mcl.utils.number;
import std.traits : isNumeric;

string humanReadableSize(T)(T size) if (isNumeric!T)
{
    import std.conv : to;
    import std.math : log, floor, pow, round;
    import std.string : format;
    import std.stdio : writeln;

    auto sizes = [" B", " KB", " MB", " GB",
        " TB", " PB", " EB", " ZB", " YB"];

    for (size_t i = 1; i < sizes.length; i++) {
        if (size < pow(1024, i))
            return (round(cast(real)(size / pow(
                1024, i - 1)))).to!string ~ sizes[i - 1];
    }
    return size.to!string ~ "B";
}
