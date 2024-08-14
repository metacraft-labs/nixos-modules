module mcl.utils.tui;

string bold(const char[] s) => cast(string)("\033[1m" ~ s ~ "\033[0m");
