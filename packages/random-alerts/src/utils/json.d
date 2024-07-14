module utils.json;

import std.traits: isNumeric, isArray, isSomeChar, ForeachType, isBoolean;
import std.json: JSONValue;
import std.conv: to;
import std.string: strip;
import std.range: front;
import std.algorithm: map;
import std.array: array;
import std.datetime: SysTime;
import core.stdc.string: strlen;

JSONValue toJSON(T)(in T value, bool simplify = false)
{
    static if (is(T == enum))
    {
        return JSONValue(value.enumToString);
    }
    else static if (is(T == bool) || is(T == string) || isSomeChar!T || isNumeric!T)
        return JSONValue(value);
    else static if ((isArray!T && isSomeChar!(ForeachType!T)) ) {
        return JSONValue(value.idup[0..(strlen(value.ptr)-1)]);
    }
    else static if (isArray!T)
    {
        if (simplify && value.length == 1)
            return value.front.toJSON(simplify);
        else if (simplify  && isBoolean!(ForeachType!T) ) {
            static if (isBoolean!(ForeachType!T)) {
                return JSONValue((value.map!(a => a ? '1' : '0').array).to!string);
            }
            else {assert(0);}
        }
        else {
            JSONValue[] result;
            foreach (elem; value)
                result ~= elem.toJSON(simplify);
            return JSONValue(result);
        }
    }
    else static if (is(T == SysTime)) {
        return JSONValue(value.toISOExtString());
    }
    else static if (is(T == struct))
    {
        JSONValue[string] result;
        auto name = "";
        static foreach (idx, field; T.tupleof)
        {
            name = __traits(identifier, field).strip("_");
            result[name] = value.tupleof[idx].toJSON(simplify);
        }
        return JSONValue(result);
    }
    else static if (is(T == K[V], K, V))
    {
        JSONValue[string] result;
        foreach (key, field; value)
        {
            result[key] = field.toJSON(simplify);
        }
        return JSONValue(result);
    }
    else
        static assert(false, "Unsupported type: `" ~ __traits(identifier, T) ~ "`");
}
