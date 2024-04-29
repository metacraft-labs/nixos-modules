module mcl.utils.array;
import std.algorithm : all;

T[] uniqIfSame(T)(T[] arr)
{
    if (arr.all!(a => a == arr[0])) {
        return [arr[0]];
    }
    return arr;

}
