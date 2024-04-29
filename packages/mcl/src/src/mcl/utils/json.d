module mcl.utils.json;
import mcl.utils.test;
import mcl.utils.string;
import std.traits: isNumeric, isArray, isSomeChar, ForeachType, isBoolean;
import std.json: JSONValue;
import std.conv: to;
import std.string: strip;
import std.range: front;
import std.stdio: writeln;
import std.algorithm: map;
import std.array: join, array;
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
        return JSONValue(value.idup[0..strlen(value.ptr)]);
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
    else
        static assert(false, "Unsupported type: `" ~ T ~ "`");
}

version (unittest)
{
    enum TestEnum
    {
        @StringRepresentation("supercalifragilisticexpialidocious") a,
        b,
        c
    }
            result[name] = value.tupleof[idx].toJSON(simplify);
    struct TestStruct
    {
        int a;
        string b;
        bool c;
    }

    struct TestStruct2
    {
        int a;
        TestStruct b;
    }

    struct TestStruct3
    {
        int a;
        TestStruct2 b;
    }
}

@("toJSON")
unittest
{
    import std.stdio : writeln;

    assert(1.toJSON == JSONValue(1));
    assert(true.toJSON == JSONValue(true));
    assert("test".toJSON == JSONValue("test"));
    assert([1, 2, 3].toJSON == JSONValue([1, 2, 3]));
    assert(["a", "b", "c"].toJSON == JSONValue(["a", "b", "c"]));
    assert([TestEnum.a, TestEnum.b, TestEnum.c].toJSON == JSONValue(
            ["supercalifragilisticexpialidocious", "b", "c"]));
    TestStruct testStruct = {1, "test", true};
    assert(testStruct.toJSON == JSONValue([
            "a": JSONValue(1),
            "b": JSONValue("test"),
            "c": JSONValue(true)
        ]));
    TestStruct2 testStruct2 = {1, testStruct};
    assert(testStruct2.toJSON == JSONValue([
            "a": JSONValue(1),
            "b": JSONValue([
                "a": JSONValue(1),
                "b": JSONValue("test"),
                "c": JSONValue(true)
            ])
        ]));
    TestStruct3 testStruct3 = {1, testStruct2};
    assert(testStruct3.toJSON == JSONValue([
            "a": JSONValue(1),
            "b": JSONValue([
                "a": JSONValue(1),
                "b": JSONValue([
                    "a": JSONValue(1),
                    "b": JSONValue("test"),
                    "c": JSONValue(true)
                ])
            ])
        ]));
}
