{
  config,
  dirs,
  ...
}: {
  imports = [
    (import "${dirs.lib}/import-agenix.nix" "hello-agenix")
  ];
  environment.etc."hello-agenix".source =
    config.age.secrets."hello-agenix/test-secret".path;
}
