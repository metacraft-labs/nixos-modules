module mcl.utils.json;
import mcl.utils.test;
import mcl.utils.string;
import std.traits : isNumeric;
import std.json : JSONValue;

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
