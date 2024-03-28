module mcl.utils.string;
import std.traits: EnumMembers, hasUDA, getUDAs;
import std.conv: to;
string camelCaseToCapitalCase(string camelCase) {
    import std.algorithm : splitWhen, map, joiner;
    import std.conv : to;
    import std.uni : isLower, isUpper, asUpperCase;

    return camelCase
        .splitWhen!((a, b) => isLower(a) && isUpper(b))
        .map!asUpperCase
        .joiner("_")
        .to!string;
}

struct StringRepresentation { string repr; }

string enumToString(T)(in T value) if (is (T == enum))
{
    switch (value)
    {
        static foreach(enumMember; EnumMembers!T)
        {
            case enumMember:
            {
                static if (!hasUDA!(enumMember, StringRepresentation))
                {
                    static assert(0, "Unsupported enum member: `" ~ enumMember ~  "`");
                }
                return getUDAs!(enumMember, StringRepresentation)[0].repr;
            }
        }
        default:
            assert(0, "Not supported case: " ~ value.to!string);
    }
}

unittest {
    assert(camelCaseToCapitalCase("camelCase") == "CAMEL_CASE");

    assert(camelCaseToCapitalCase("") == "");
    assert(camelCaseToCapitalCase("_") == "_");
    assert(camelCaseToCapitalCase("a") == "A");
    assert(camelCaseToCapitalCase("ab") == "AB");
    assert(camelCaseToCapitalCase("aB") == "A_B");
    assert(camelCaseToCapitalCase("aBc") == "A_BC");
    assert(camelCaseToCapitalCase("aBC") == "A_BC");
    assert(camelCaseToCapitalCase("aBCD") == "A_BCD");
    assert(camelCaseToCapitalCase("aBcD") == "A_BC_D");

    assert(camelCaseToCapitalCase("rpcUrl") == "RPC_URL");
    assert(camelCaseToCapitalCase("parsedJSON") == "PARSED_JSON");
    assert(camelCaseToCapitalCase("fromXmlToJson") == "FROM_XML_TO_JSON");
    assert(camelCaseToCapitalCase("fromXML2JSON") == "FROM_XML2JSON");
}
