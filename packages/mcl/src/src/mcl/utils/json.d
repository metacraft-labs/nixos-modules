module mcl.utils.json;
import mcl.utils.test;
import mcl.utils.string;
import std.traits : isNumeric, isArray, isSomeChar, ForeachType, isBoolean, isAssociativeArray;
import std.json : JSONValue, JSONOptions, JSONType;
import std.conv : to;
import std.string : strip;
import std.range : front;
import std.stdio : writeln;
import std.algorithm : map;
import std.array : join, array, replace, split;
import std.datetime : SysTime;
import std.sumtype : SumType, isSumType;
import core.stdc.string : strlen;

string getStrOrDefault(JSONValue value, string defaultValue = "")
{
    return value.isNull ? defaultValue : value.str;
}

string jsonValueToString(in JSONValue value)
{
    return value.toString(JSONOptions.doNotEscapeSlashes).strip("\"");
}

bool tryDeserializeJson(T)(in JSONValue value, out T result)
{
    try
    {
        result = value.fromJSON!T;
        return true;
    }
    catch (Exception e)
    {
        return false;
    }
}

T fromJSON(T)(in JSONValue value)
{
    T result;
    if (value.isNull)
        result = T.init;

    static if (is(T == JSONValue))
        result = value;
    else static if (is(T == bool) || is(T == string) || isSomeChar!T || isNumeric!T || is(T == enum))
        result = jsonValueToString(value).to!T;
    else static if (isSumType!T)
    {
        bool sumTypeDecoded = false;
        static foreach (SumTypeVariant; T.Types)
        {
            {
                SumTypeVariant sumTypeResult;
                if (tryDeserializeJson!SumTypeVariant(value, sumTypeResult))
                {
                    sumTypeDecoded = true;
                    result = sumTypeResult;
                }
            }
        }
        if (!sumTypeDecoded)
            throw new Exception("Failed to deserialize JSON value");
    }
    else static if (isArray!T)
    {
        static if (isBoolean!(ForeachType!T))
        {
            if (value.type == JSONType.string && isBoolean!(ForeachType!T))
                result = value.str.map!(a => a == '1').array;
        }
        if (value.type != JSONType.array)
            result = [value.fromJSON!(ForeachType!T)];
        else
            result = value.array.map!(a => a.fromJSON!(ForeachType!T)).array;

    }
    else static if (is(T == SysTime))
    {
        result = SysTime.fromISOExtString(jsonValueToString(value));
    }
    else static if (is(T == struct))
    {
        static foreach (idx, field; T.tupleof)
        {
            if ((__traits(identifier, field).replace("_", "") in value.object) && !value[__traits(identifier, field)
                    .replace("_", "")].isNull)
            {
                result.tupleof[idx] = value[__traits(identifier, field)
                    .replace("_", "")].fromJSON!(typeof(field));
            }
        }
    }
    else static if (isAssociativeArray!T)
    {
        foreach (key, val; value.object)
        {
            if (key in result)
                result[key] = val.fromJSON!(typeof(result[key]));
        }
    }
    else
        static assert(false, "Unsupported type: `", T, "` ", isSumType!T);
    return result;

}

@("fromJSON")
unittest
{
    auto x = fromJSON!(SumType!(int, string))(JSONValue("1"));
    auto y = fromJSON!(SumType!(int, string))(JSONValue(1));
}

JSONValue toJSON(T)(in T value, bool simplify = false)
{
    JSONValue result;
    static if (is(T == enum))
        result = JSONValue(value.enumToString);
    else static if (is(T == bool) || is(T == string) || isSomeChar!T || isNumeric!T)
        result = JSONValue(value);
    else static if ((isArray!T && isSomeChar!(ForeachType!T)))
        result = JSONValue(value.idup[0 .. (strlen(value.ptr) - 1)]);
    else static if (isArray!T)
    {
        if (simplify && value.length == 1)
            result = value.front.toJSON(simplify);
        else if (simplify && isBoolean!(ForeachType!T))
        {
            static if (isBoolean!(ForeachType!T))
                result = JSONValue((value.map!(a => a ? '1' : '0').array).to!string);
            else
                assert(0);
        }
        else
        {
            JSONValue[] arrayResult;
            foreach (elem; value)
                arrayResult ~= elem.toJSON(simplify);
            result = JSONValue(arrayResult);
        }
    }
    else static if (is(T == SysTime))
        result = JSONValue(value.toISOExtString());
    else static if (is(T == struct))
    {
        JSONValue[string] structResult;
        auto name = "";
        static foreach (idx, field; T.tupleof)
        {
            name = __traits(identifier, field).strip("_");
            structResult[name] = value.tupleof[idx].toJSON(simplify);
        }
        result = JSONValue(structResult);
    }
    else
        static assert(false, "Unsupported type: `" ~ __traits(identifier, T) ~ "`");

    return result;

}

version (unittest)
{
    enum TestEnum
    {
        @StringRepresentation("supercalifragilisticexpialidocious") a,
        b,
        c
    }

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
