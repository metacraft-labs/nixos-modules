module mcl.utils.env;
import mcl.utils.test;

import std.stdio : writeln;

struct Optional
{
}

auto optional() => Optional();

enum isOptional(alias field) = imported!`std.traits`.hasUDA!(field, Optional);

class MissingEnvVarsException : Exception
{
    import std.exception : basicExceptionCtors;

    mixin basicExceptionCtors;
}

T parseEnv(T)()
{
    import std.conv : to;
    import std.exception : enforce;
    import std.format : fmt = format;
    import std.process : environment;
    import std.traits : Fields;

    import mcl.utils.string : camelCaseToCapitalCase;

    T result;
    string[] missingEnvVars = [];

    static foreach (idx, field; T.tupleof)
    {
        {
            string envVarName = field.stringof.camelCaseToCapitalCase;
            if (auto envVar = environment.get(envVarName))
                result.tupleof[idx] = envVar.to!(typeof(field));
            else if (!isOptional!field)
                missingEnvVars ~= envVarName;
        }
    }

    enforce!MissingEnvVarsException(
        missingEnvVars.length == 0,
        "missing environment variables:\n%(* %s\n%)".fmt(missingEnvVars)
    );

    result.setup();

    return result;
}

version (unittest)
{
    struct Config
    {
        @optional() string opt;
        int a;
        string b;
        float c = 1.0;

        void setup()
        {
        }
    }
}

@("parseEnv")
unittest
{
    import std.process : environment;
    import std.exception : assertThrown;

    environment["A"] = "1";
    environment["B"] = "2";
    environment["C"] = "1.0";

    auto config = parseEnv!Config;

    assert(config.a == 1);
    assert(config.b == "2");
    assert(config.c == 1.0);
    assert(config.opt is null);

    environment["OPT"] = "3";
    config = parseEnv!Config;
    assert(config.opt == "3");

    environment.remove("A");
    assertThrown(config = parseEnv!Config, "missing environment variables:\nA\n");
}
