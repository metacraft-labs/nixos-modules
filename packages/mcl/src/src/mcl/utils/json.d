module mcl.utils.json;
import mcl.utils.test;
import mcl.utils.string;
import std.traits: isNumeric, isArray, isSomeChar, ForeachType, isBoolean, isAssociativeArray;
import std.json: parseJSON, JSONValue, JSONOptions, JSONType;
import std.conv: to;
import std.string: strip;
import std.range: front;
import std.algorithm: map;
import std.array: join, array, replace, split;
import std.datetime: SysTime;
import std.sumtype: SumType, isSumType;
import core.stdc.string: strlen;

bool tryDeserializeJson(T)(in JSONValue value, out T result)
{
    try {
        result = value.fromJSON!T;
        return true;
    } catch (Exception e) {
        return false;
    }
}

T fromJSON(T)(in JSONValue value) {
    if (value.isNull) {
        return T.init;
    }
    static if (is(T == JSONValue)) {
        return value;
    }
    else static if (is(T == bool) || is(T == string) || isSomeChar!T || isNumeric!T || is(T == enum)) {
        return value.get!T;
    }
    else static if (isSumType!T) {
        static foreach (SumTypeVariant; T.Types)
        {{
            SumTypeVariant result;
            if (tryDeserializeJson!SumTypeVariant(value, result)) {
                return T(result);
            }
        }}

        throw new Exception("Failed to deserialize JSON value");
    }
    else static if (isArray!T) {
        static if ( isBoolean!(ForeachType!T)) {
            if (value.type == JSONType.string && isBoolean!(ForeachType!T)) {
                return value.str.map!(a => a == '1').array;
            }
        }

        if (value.type != JSONType.array) {
            return [value.fromJSON!(ForeachType!T)];
        }

        return value.array.map!(a => a.fromJSON!(ForeachType!T)).array;
    }
    else static if (is(T == SysTime)) {
        return SysTime.fromISOExtString(value.toString(JSONOptions.doNotEscapeSlashes).strip("\""));
    }
    else static if (is(T == struct)) {
        T result;
        static foreach (idx, field; T.tupleof) {
            if ((__traits(identifier, field).replace("_", "") in value.object) && !value[__traits(identifier, field).replace("_", "")].isNull) {
                result.tupleof[idx] = value[__traits(identifier, field).replace("_", "")].fromJSON!(typeof(field));
            }
        }
        return result;
    }
    else static if (is(immutable T == immutable V[K], V, K)) {
        V[K] result;
        foreach (key, val; value.object)
            result[key] = val.fromJSON!V;
        return result;
    }
    else {
        static assert(false, "Unsupported type: `", T,  "` ", isSumType!T);
    }
}

@("fromJSON.AA")
unittest {
    {
        struct Node {
            string name;
            ulong size;
            Node[string] children;
        }

        auto json = parseJSON(`{
            "name": "root",
            "size": 42,
            "children": {
                "child1": {
                    "name": "child1",
                    "size": 1,
                    "children": {}
                },
                "child2": {
                    "name": "child2",
                    "size": 2,
                    "children": {
                        "child3": {
                            "name": "child3",
                            "size": 3,
                            "children": {}
                        }
                    }
                }
            }
        }`);

        assert(json.fromJSON!Node == Node("root", 42, [
            "child1": Node("child1", 1, null),
            "child2": Node("child2", 2, [
                "child3": Node("child3", 3, null)
            ])
        ]));
    }

    {
        alias Type = SumType!(
            int,
            bool[string]
        );

        auto json = parseJSON(`{
            "1": 1,
            "2": { "a": true }
        }`);

        assert(json.fromJSON!(Type[string]) == [
            "1": Type(1),
            "2": Type([ "a": true ])
        ]);
    }

    {
        alias Type = SumType!(
            int,
            bool[string]
        );

        auto json = parseJSON(`[1, { "a": true } ]`);

        assert(json.fromJSON!(Type[]) == [
            Type(1),
            Type([ "a": true ])
        ]);
    }

    {
        auto json = parseJSON(`{
            "1": "a",
            "2": 3,
            "3": [ 1, { "x": true } ]
        }`);

        // alias Type = SumType!(
        //     string,
        //     int,
        //     SumType!(
        //         int,
        //         bool[string]
        //     )
        // )[string];

        alias InnerType = SumType!(
            int,
            bool[string]
        );

        alias OuterType = SumType!(
            string,
            int,
            InnerType[]
        );

        alias Type = OuterType[string];

        Type expectedValue = [
            "1": OuterType("a"),
            "2": OuterType(3),
            "3": OuterType([ InnerType(1), InnerType([ "x": true ]) ])
        ];

        assert(json.fromJSON!Type == expectedValue);
    }
}

@("fromJSON.SumType")
unittest {
    alias NumOrString = SumType!(int, string);
    assert(42.JSONValue.fromJSON!NumOrString == NumOrString(42));
    assert("test".JSONValue.fromJSON!NumOrString == NumOrString("test"));
}

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

version(unittest)
{
    enum TestEnum
    {
        @StringRepresentation("supercalifragilisticexpialidocious")
        a,
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
    assert(1.toJSON == JSONValue(1));
    assert(true.toJSON == JSONValue(true));
    assert("test".toJSON == JSONValue("test"));
    assert([1, 2, 3].toJSON == JSONValue([1, 2, 3]));
    assert(["a", "b", "c"].toJSON == JSONValue(["a", "b", "c"]));
    assert([TestEnum.a, TestEnum.b, TestEnum.c].toJSON == JSONValue(["supercalifragilisticexpialidocious", "b", "c"]));
    TestStruct testStruct = { 1, "test", true };
    assert(testStruct.toJSON == JSONValue(["a": JSONValue(1), "b": JSONValue("test"), "c": JSONValue(true)]));
    TestStruct2 testStruct2 = { 1, testStruct };
    assert(testStruct2.toJSON == JSONValue(["a": JSONValue(1), "b": JSONValue(["a": JSONValue(1), "b": JSONValue("test"), "c": JSONValue(true)])]));
    TestStruct3 testStruct3 = { 1, testStruct2 };
    assert(testStruct3.toJSON == JSONValue(["a": JSONValue(1), "b": JSONValue(["a": JSONValue(1), "b": JSONValue(["a": JSONValue(1), "b": JSONValue("test"), "c": JSONValue(true)])])]));
}

