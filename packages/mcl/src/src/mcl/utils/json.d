module mcl.utils.json;
import mcl.utils.string;
import std.traits: isNumeric;
import std.json: JSONValue;

JSONValue toJSON(T)(in T value)
{
    static if (is(T == enum))
    {
        return JSONValue(value.enumToString);
    }
    else static if (is(T == bool) || is(T == string) || isNumeric!T)
        return JSONValue(value);
    else static if (is(T == U[], U))
    {
        JSONValue[] result;
        foreach (elem; value)
            result ~= elem.toJSON;
        return JSONValue(result);
    }
    else static if (is(T == struct))
    {
        JSONValue[string] result;
        static foreach (idx, field; T.tupleof)
            result[__traits(identifier, field)] = value.tupleof[idx].toJSON;
        return JSONValue(result);
    }
    else
        static assert(false, "Unsupported type: `" ~ T ~ "`");
}

