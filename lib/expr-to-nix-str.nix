rec {
  toNixString =
    expr:
    if builtins.isList expr then
      "[" + builtins.concatStringsSep " " (builtins.map toNixString expr) + "]"
    else if builtins.isAttrs expr then
      "{ "
      + builtins.concatStringsSep " " (
        builtins.map (name: name + " = " + toNixString (expr.${name}) + ";") (builtins.attrNames expr)
      )
      + " }"
    else if expr == null then
      "null"
    else if builtins.isString expr then
      "\"" + expr + "\""
    else if builtins.isBool expr then
      (if expr then "true" else "false")
    else
      builtins.toString expr;
}
