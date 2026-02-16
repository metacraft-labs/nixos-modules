module mcl.utils.reflection;

import std.conv : to;
import std.traits : isAggregateType, FieldNameTuple;

/// Get a field value from an aggregate type by name, returned as string
string getField(T)(in T value, string fieldName)
if (isAggregateType!T)
{
    switch (fieldName)
    {
        static foreach (name; FieldNameTuple!T)
        {
            case name:
                return __traits(getMember, value, name).to!string;
        }
        default:
            throw new Exception("Unknown field '" ~ fieldName ~ "' for type " ~ T.stringof);
    }
}

/// Check if a field exists in an aggregate type
bool hasField(T)(string fieldName)
if (isAggregateType!T)
{
    static foreach (name; FieldNameTuple!T)
    {
        if (fieldName == name)
            return true;
    }
    return false;
}

@("getField")
unittest
{
    struct TestStruct
    {
        string name;
        int count;
        double value;
    }

    auto t = TestStruct("test", 42, 3.14);

    assert(getField(t, "name") == "test");
    assert(getField(t, "count") == "42");
    assert(getField(t, "value") == "3.14");

    import std.exception : assertThrown;
    assertThrown!Exception(getField(t, "unknown"));
}

@("hasField")
unittest
{
    struct TestStruct
    {
        string name;
        int count;
    }

    assert(hasField!TestStruct("name"));
    assert(hasField!TestStruct("count"));
    assert(!hasField!TestStruct("unknown"));
}
