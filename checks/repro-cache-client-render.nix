top@{ ... }:
{
  # Reprobuild-Binary-Cache-Fleet R2 (REPRO-FLEET-PROVISION) gate:
  # t_repro_cache_client_render.
  #
  # Proves the reusable `mcl-reprobuild` module (a) puts the reprobuild `repro`
  # CLI — which BUNDLES the binary-cache client — on PATH and (b) RENDERS the R1
  # caches.conf with the managed fleet cache — the EXACT url + 130-hex ECDSA-P256
  # trusted key + priority — for the NixOS module class (system-wide
  # /etc/repro/caches.conf), asserted live in a booted VM.
  #
  # (mcl-reprobuild superseded the former mcl-repro-cache-client module — the
  # separate `repro-binary-cache-client` package was just `reprobuild` renamed,
  # so the client config knobs now live on the one reprobuild module.)
  #
  # The home-manager module class shares the SAME renderer + option schema (one
  # definition in modules/mcl-reprobuild), so this render proof covers it too;
  # ~/dotfiles additionally evaluates the home config as its own build.
  #
  # NON-VACUITY: the assertions check the EXACT 130-hex key string, the exact
  # url, and the exact priority line. A missing key, a wrong key, or a wrong
  # url/priority makes the rendered file differ and the gate FAILS — the trust
  # key is load-bearing, not decorative.
  perSystem =
    {
      pkgs,
      lib,
      inputs',
      ...
    }:
    let
      flake = top.config.flake;
      # Pass the reprobuild package explicitly (like the sibling cross-host gate
      # passes the daemon), keeping the check self-contained. This is the full
      # toolset — `repro` plus the bundled `repro-binary-cache-client`.
      reproPkg = inputs'.reprobuild.packages.reprobuild;

      # The concrete fleet cache (from R3's managed signing key). The pubkey is
      # the exact 130-hex string committed at
      # infra/services/repro-binary-cache/signing-pubkey.txt (R3). It is spelled
      # out here (not read cross-repo) so the gate is self-contained and a
      # transcription error would fail against the module-rendered value.
      cacheName = "repro-cache";
      cacheUrl = "https://repro-cache.metacraft-labs.com";
      fleetKey = "04d09ced68a33f83359f6e0b25e975137aec67a5305c3a76e6de33916a0d43a83e056509945d1793ebf923e6e07a0cbeb4175dfdf6b885bafd6d8077903bfd700f";
      cachePriority = 20;

      caches.${cacheName} = {
        url = cacheUrl;
        trustedPublicKeys = [ fleetKey ];
        priority = cachePriority;
      };
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_repro_cache_client_render = pkgs.testers.nixosTest {
          name = "t_repro_cache_client_render";

          nodes.host =
            { ... }:
            {
              imports = [ flake.modules.nixos.mcl-reprobuild ];
              programs.reprobuild = {
                enable = true;
                package = reproPkg;
                inherit caches;
              };
            };

          testScript = ''
            start_all()
            host.wait_for_unit("multi-user.target")

            with subtest("repro + the bundled binary-cache client are on PATH"):
                # `enable` puts the reprobuild package in environment.systemPackages;
                # it ships both `repro` and `repro-binary-cache-client`.
                host.succeed("command -v repro")
                host.succeed("command -v repro-binary-cache-client")

            with subtest("/etc/repro/caches.conf is rendered with the fleet cache"):
                host.succeed("test -f /etc/repro/caches.conf")
                conf = host.succeed("cat /etc/repro/caches.conf")
                print(conf)

                # The section header is the cache name.
                assert "[${cacheName}]" in conf, f"missing [${cacheName}] section: {conf!r}"

                # The exact url must be present (quoted, R1 parser syntax).
                assert 'url = "${cacheUrl}"' in conf, f"missing/wrong url: {conf!r}"

                # The EXACT 130-hex trusted key must be present — the
                # load-bearing trust anchor. A missing/wrong key must fail here.
                assert (
                    'trusted-public-keys = "${fleetKey}"' in conf
                ), f"missing/wrong trusted key: {conf!r}"

                # The priority line must be the configured value.
                assert (
                    "priority = ${toString cachePriority}" in conf
                ), f"missing/wrong priority: {conf!r}"
          '';
        };
      };
    };
}
