module mcl.utils.fetch;

import std.stdio : stderr;
import std.json : JSONValue;

JSONValue fetchJson(string url, string authToken) {
    import std.json : parseJSON;
    import std.net.curl : HTTP, get;
    auto client = HTTP();
    client.addRequestHeader("Authorization", "Bearer " ~ authToken);
    stderr.writefln("GET %s", url);
    auto response = get(url, client);
    return parseJSON(response);
}
