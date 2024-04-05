module mcl.utils.string;
import mcl.utils.test;
import std.conv: to;
import std.exception: assertThrown;

string lowerCaseFirst(string r) {
    import std.range: save, popFront, chain, front, only;
    import std.uni: toLower;
    string rest = r.save;
    rest.popFront();
    return chain(r.front.toLower.only, rest).to!string;
}

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

string kebabCaseToCamelCase(string kebabCase) {
    import std.algorithm : map;
    import std.string : capitalize;
    import std.array : join, split;

    return kebabCase
        .split("-")
        .map!capitalize
        .join.to!string.
        lowerCaseFirst;
}

@("camelCaseToCapitalCase")
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

struct StringRepresentation { string repr; }

string enumToString(T)(in T value) if (is (T == enum))
{
    import std.traits: EnumMembers, hasUDA, getUDAs;
    import std.logger: LogLevel, log;
    switch (value)
    {
        static foreach(enumMember; EnumMembers!T)
        {
            case enumMember:
            {
                static if (!hasUDA!(enumMember, StringRepresentation))
                {
                    LogLevel.info.log("Enum doesn't have StringRepresentation: `" ~ enumMember.to!string ~  "`");
                    return enumMember.to!string;
                }
                else {
                    return getUDAs!(enumMember, StringRepresentation)[0].repr;
                }
            }
        }
        default:
            assert(0, "Not supported case: " ~ value.to!string);
    }
}

@("enumToString")
unittest {
    enum TestEnum { a, b, c }
    enum TestEnumWithRepr {
        @StringRepresentation("a")
        a,
        @StringRepresentation("b")
        b,
        @StringRepresentation("c")
        c
    }

    //Not necessary to test this case, because it is covered by the static assert
    // assertThrown(enumToString(TestEnum.a), "Unsupported enum member: `TestEnum.a`");
    // assertThrown(enumToString(TestEnum.b), "Unsupported enum member: `TestEnum.b`");
    // assertThrown(enumToString(TestEnum.c), "Unsupported enum member: `TestEnum.c`");

    assert(enumToString(TestEnumWithRepr.a) == "a");
    assert(enumToString(TestEnumWithRepr.b) == "b");
    assert(enumToString(TestEnumWithRepr.c) == "c");
}
