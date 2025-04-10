module mcl.utils.array;
import std.algorithm : all, uniq, sort;
import std.array : array;
import std.conv : to;
import std.traits : isArray, isSomeString;
import std.stdio : writeln;

T[] uniqIfSame(T)(T[] arr)
{
    if (arr.length == 0)
        return arr;
    else if (arr.all!(a => a == arr[0]))
        return [arr[0]];
    else
        return arr;

}

@("uniqIfSame")
unittest
{
    assert(uniqIfSame([1, 1, 1, 1]) == [1],
        "uniqIfSame should return [1] for [1, 1, 1, 1], but got " ~ uniqIfSame([1, 1, 1, 1]).to!string);
    assert(uniqIfSame([1, 2, 3, 4]) == [1, 2, 3, 4],
        "uniqIfSame should return [1, 2, 3, 4] for [1, 2, 3, 4], but got " ~ uniqIfSame([1, 2, 3, 4]).to!string);
    assert(uniqIfSame(["a", "a", "a", "a"]) == ["a"],
        "uniqIfSame should return [\"a\"] for [\"a\", \"a\", \"a\", \"a\"], but got " ~ uniqIfSame(["a", "a", "a", "a"]).to!string);
    assert(uniqIfSame(["a", "b", "c", "d"]) == ["a", "b", "c", "d"],
        "uniqIfSame should return [\"a\", \"b\", \"c\", \"d\"] for [\"a\", \"b\", \"c\", \"d\"], but got " ~ uniqIfSame(["a", "b", "c", "d"]).to!string);
}

T uniqArrays(T)(T s)
{
    static if (isArray!T && !isSomeString!T)
        s = s.sort.uniq.array.to!T;
    else static if (is(T == struct))
        static foreach (idx, field; T.tupleof)
            s.tupleof[idx] = s.tupleof[idx].uniqArrays;

    return s;
}

@("uniqArrays")
unittest
{
    assert(uniqArrays([1, 2, 3, 4, 1, 2, 3, 4]) == [1, 2, 3, 4],
        "uniqArrays should return [1, 2, 3, 4] for [1, 2, 3, 4, 1, 2, 3, 4], but got " ~ uniqArrays([1, 2, 3, 4, 1, 2, 3, 4]).to!string);
    assert(uniqArrays("aabbccdd") == "aabbccdd",
        "uniqArrays should return \"aabbccdd\" for \"aabbccdd\", but got " ~ uniqArrays("aabbccdd").to!string);
    assert(uniqArrays(5) == 5, "uniqArrays should return 5 for 5, but got " ~ uniqArrays(5).to!string);
    struct TestStruct
    {
        int[] a;
        string b;
    }

    assert(uniqArrays(TestStruct([1, 2, 3, 4, 1, 2, 3, 4], "aabbccdd")) == TestStruct([1, 2, 3, 4], "aabbccdd"),
        "uniqArrays should return TestStruct([1, 2, 3, 4], \"aabbccdd\") for TestStruct([1, 2, 3, 4, 1, 2, 3, 4], \"aabbccdd\"), but got " ~ uniqArrays(TestStruct([1, 2, 3, 4, 1, 2, 3, 4], "aabbccdd")).to!string);
}
