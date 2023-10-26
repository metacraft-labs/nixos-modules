{lib}: let
  inherit (lib) pipe mapAttrs mapAttrs' filterAttrs nameValuePair;
  inherit (lib.strings) replaceStrings lowerChars upperChars;
in rec {
  nixOptionNameToEnvVarName = str:
    replaceStrings (lowerChars ++ ["-"]) (upperChars ++ ["_"]) str;

  toEnvVariables = args:
    pipe args [
      (mapAttrs (k: v:
        if builtins.isString v
        then v
        else builtins.toJSON v))
      (filterAttrs (k: v: (v != "null") && (v != "") && (v != null)))
      (mapAttrs' (k: v: nameValuePair (nixOptionNameToEnvVarName k) v))
    ];
}
