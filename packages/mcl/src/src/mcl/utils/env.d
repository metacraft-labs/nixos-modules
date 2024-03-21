module mcl.utils.env;

struct Optional {}
auto optional() => Optional();

enum isOptional(alias field) = imported!`std.traits`.hasUDA!(field, Optional);

class MissingEnvVarsException : Exception {
    import std.exception : basicExceptionCtors;
    mixin basicExceptionCtors;
}

T parseEnv(T)() {
    import std.conv : to;
    import std.exception : enforce;
    import std.format : fmt = format;
    import std.process : environment;
    import std.traits : Fields;

    import mcl.utils.string : camelCaseToCapitalCase;

    T result;
    string[] missingEnvVars = [];

    static foreach (idx, field; T.tupleof)
    {{
        string envVarName = field.stringof.camelCaseToCapitalCase;
        if (auto envVar = environment.get(envVarName))
            result.tupleof[idx] = envVar.to!(typeof(field));
        else if (!isOptional!field)
            missingEnvVars ~= envVarName;
    }}

    enforce!MissingEnvVarsException(
        missingEnvVars.length == 0,
        "missing environment variables:\n%(* %s\n%)".fmt(missingEnvVars)
    );

    result.setup();

    return result;
}
