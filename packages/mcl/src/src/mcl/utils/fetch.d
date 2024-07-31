module mcl.utils.fetch;
import mcl.utils.test;

import std.json : JSONValue;
import std.format : fmt = format;

JSONValue fetchJson(string url, string authToken = "")
{
    import std.json : parseJSON;
    import std.net.curl : HTTP, get;
    import std.logger : log, LogLevel;

    auto client = HTTP();
    if (authToken != "")
    {
        client.addRequestHeader("Authorization", "Bearer " ~ authToken);
    }

    LogLevel.info.log("GET %s", url);

    auto response = get(url, client);
    return parseJSON(response);
}

@("fetchJson")
unittest
{
    auto json = fetchJson("https://v2.jokeapi.dev/joke/Programming?type=single&idRange=40");
    string actualCategory = json["category"].str;
    assert(actualCategory == "Programming", "Expected category to be 'Programming', but got '%s'".fmt(actualCategory));

    string actualType = json["type"].str;
    assert(actualType == "single", "Expected type to be 'single', but got '%s'".fmt(actualType));

    string actualJoke = json["joke"].str;
    assert(actualJoke == "Debugging: Removing the needles from the haystack.", "Expected joke to be 'Debugging: Removing the needles from the haystack.', but got '%s'".fmt(actualJoke));
}
