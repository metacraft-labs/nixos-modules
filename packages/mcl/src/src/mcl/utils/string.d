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

enum size_t getMaxEnumMemberNameLength(E) = ()
{
    import std.traits : EnumMembers;

    size_t max = 0;
    foreach (member; [EnumMembers!E])
    {
        const name = member.enumToString();
        max = name.length > max ? name.length : max;
    }

    return max;
}();

@("getMaxEnumMemberNameLength")
unittest
{
    enum EnumLen
    {
        @StringRepresentation("a1") a,
        @StringRepresentation("b12") b,
        @StringRepresentation("c123") c
    }

    static assert(getMaxEnumMemberNameLength!EnumLen == 4);
}

struct MaxWidth
{
    ushort value;
}

void writeRecordAsTable(bool ansiColors = true, T, Writer)(in T obj, auto ref Writer w)
{
    import std.format : formattedWrite;
    import std.traits : hasUDA, getUDAs;

    const gray = ansiColors ? "\x1b[90m" : "";
    const bold = ansiColors ? "\x1b[1m" : "";
    const normal = ansiColors ? "\x1b[0m" : "";

    w.formattedWrite("│");
    static foreach (idx, field; T.tupleof)
    {{
        // If the field is an enum, get the maximum length of the enum member names
        static if (is(typeof(field) == enum))
            const width = getMaxEnumMemberNameLength!(typeof(field));

        // If the field is a bool, set the width to "false".length
        else static if (is(typeof(field) : bool))
            const width = 5;

        // If the field has a UDA MaxWidth, set the width to the value of the UDA
        else static if (hasUDA!(field, MaxWidth))
            const width = getUDAs!(field, MaxWidth)[0].value;

        else
            const width = 0;

        w.formattedWrite(
            " %s%s%s: %s%*-s%s │",
            gray, __traits(identifier, field), normal,
            bold, width, obj.tupleof[idx], normal
        );
    }}
    w.formattedWrite("\n");
}

@("writeRecordAsTable")
unittest
{
    import std.array : appender;

    struct TestStruct
    {
        int num;
        @MaxWidth(4) int otherNum;
        bool bool1;
        bool bool2;
        @MaxWidth(10) string someString;
    }

    const t = TestStruct(1, 20, true, false, "test");
    auto result = appender!string;
    t.writeRecordAsTable!false(result);
    assert(result.data == "│ num: 1 │ otherNum: 20   │ bool1: true  │ bool2: false │ someString: test       │\n");
}
