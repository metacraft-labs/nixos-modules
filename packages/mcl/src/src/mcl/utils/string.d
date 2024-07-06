module mcl.utils.string;

import mcl.utils.test;
import std.conv : to;
import std.exception : assertThrown;

string lowerCaseFirst(string r)
{
    import std.range : save, popFront, chain, front, only;
    import std.uni : toLower;

    string rest = r.save;
    rest.popFront();
    return chain(r.front.toLower.only, rest).to!string;
}

string camelCaseToCapitalCase(string camelCase)
{
    import std.algorithm : splitWhen, map, joiner;
    import std.conv : to;
    import std.uni : isLower, isUpper, asUpperCase;

    return camelCase
        .splitWhen!((a, b) => isLower(a) && isUpper(b))
        .map!asUpperCase
        .joiner("_")
        .to!string;
}

@("camelCaseToCapitalCase")
unittest
{
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

string kebabCaseToCamelCase(string kebabCase)
{
    import std.algorithm : map;
    import std.string : capitalize;
    import std.array : join, split;

    return kebabCase
        .split("-")
        .map!capitalize
        .join
        .to!string
        .lowerCaseFirst;
}

@("kebabCaseToCamelCase")
unittest
{
    assert(kebabCaseToCamelCase("kebab-case") == "kebabCase");
    assert(kebabCaseToCamelCase("kebab-case-") == "kebabCase");
    assert(kebabCaseToCamelCase("kebab-case--") == "kebabCase");
    assert(kebabCaseToCamelCase("kebab-case--a") == "kebabCaseA");
    assert(kebabCaseToCamelCase("kebab-case--a-") == "kebabCaseA");

    assert(kebabCaseToCamelCase(
            "once-upon-a-midnight-dreary-while-i-pondered-weak-and-weary" ~
            "-over-many-a-quaint-and-curious-volume-of-forgotten-lore" ~
            "-while-i-nodded-nearly-napping-suddenly-there-came-a-tapping" ~
            "-as-of-someone-gently-rapping-rapping-at-my-chamber-door" ~
            "-tis-some-visitor-i-muttered-tapping-at-my-chamber-door" ~
            "-only-this-and-nothing-more") == "onceUponAMidnightDrearyWhileIPonderedWeakAndWeary" ~
            "OverManyAQuaintAndCuriousVolumeOfForgottenLore" ~ "WhileINoddedNearlyNappingSuddenlyThereCameATapping" ~
            "AsOfSomeoneGentlyRappingRappingAtMyChamberDoor" ~
            "TisSomeVisitorIMutteredTappingAtMyChamberDoor" ~
            "OnlyThisAndNothingMore");

}

struct StringRepresentation
{
    string repr;
}

string enumToString(E)(in E value) if (is(E == enum))
{
    import std.traits : EnumMembers, hasUDA, getUDAs;

    final switch (value)
    {
        static foreach (enumMember; EnumMembers!E)
        {
            case enumMember:
            {
                static if (!hasUDA!(enumMember, StringRepresentation))
                {
                    debug pragma(msg,
                        "Enum memer doesn't have StringRepresentation: ",
                        enumMember
                    );
                    return enumMember.to!string;
                }
                else
                    return getUDAs!(enumMember, StringRepresentation)[0].repr;
            }
        }
    }
}

@("enumToString")
unittest
{
    enum TestEnum
    {
        a1,
        b2,
        c3
    }

    assert(enumToString(TestEnum.a1) == "a1");
    assert(enumToString(TestEnum.b2) == "b2");
    assert(enumToString(TestEnum.c3) == "c3");

    enum TestEnumWithRepr
    {
        @StringRepresentation("field1") a,
        @StringRepresentation("field_2") b,
        @StringRepresentation("field-3") c
    }

    assert(enumToString(TestEnumWithRepr.a) == "field1");
    assert(enumToString(TestEnumWithRepr.b) == "field_2");
    assert(enumToString(TestEnumWithRepr.c) == "field-3");
}
