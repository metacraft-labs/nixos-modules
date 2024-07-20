module mcl.utils.array;
import std.algorithm : all, uniq, sort;
import std.array : array;
import std.conv : to;
import std.traits : isArray, isSomeString;
import std.stdio : writeln;

T[] uniqIfSame(T)(T[] arr)
{
    if (arr.length == 0)
    {
        return arr;
    }
    else if (arr.all!(a => a == arr[0]))
    {
        return [arr[0]];
    }
    else
    {
        return arr;
    }

}

@("uniqIfSame")
unittest
{
    assert(uniqIfSame([1, 1, 1, 1]) == [1]);
    assert(uniqIfSame([1, 2, 3, 4]) == [1, 2, 3, 4]);
    assert(uniqIfSame(["a", "a", "a", "a"]) == ["a"]);
    assert(uniqIfSame(["a", "b", "c", "d"]) == ["a", "b", "c", "d"]);
}

T uniqArrays(T)(T s)
{
    static if (isSomeString!T)
    {
        return s;
    }
    else static if (isArray!T)
    {
        return s.sort.uniq.array.to!T;
    }
    else static if (is(T == struct))
    {
        static foreach (idx, field; T.tupleof)
        {
            s.tupleof[idx] = s.tupleof[idx].uniqArrays;
        }
        return s;
    }
    else
    {
        return s;
    }
}

@("uniqArrays")
unittest
{
    assert(uniqArrays([1, 2, 3, 4, 1, 2, 3, 4]) == [1, 2, 3, 4]);
    assert(uniqArrays("aabbccdd") == "aabbccdd");
    assert(uniqArrays(5) == 5);
    struct TestStruct
    {
        int[] a;
        string b;
    }

    assert(uniqArrays(TestStruct([1, 2, 3, 4, 1, 2, 3, 4], "aabbccdd")) == TestStruct([
            1, 2, 3, 4
        ], "aabbccdd"));
}
