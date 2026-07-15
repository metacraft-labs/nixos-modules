{ inputs, ... }:
let
  # A reusable module that installs the reprobuild `repro` build CLI onto a host
  # AND renders the R1 binary-cache client trust config (`caches.conf`) from
  # declarative options — so the whole fleet (servers + workstations + CI
  # runners) can both BUILD with `repro` and SUBSTITUTE from the managed cache,
  # the same way Nix+Attic substituters/trusted-public-keys are provisioned.
  #
  # This SUPERSEDES the former `mcl-repro-cache-client` module. That module
  # installed a SEPARATE `repro-binary-cache-client` package which is just
  # `reprobuild.overrideAttrs { pname = …; }` — the identical toolset renamed,
  # so it duplicated the full closure and collided with this module on
  # `lib/librepro_monitor_shim.so`. The client binary (`repro-binary-cache-client`)
  # already ships INSIDE the `reprobuild` package, so there is one package here
  # and the cache-client behaviour is purely the rendered `caches.conf` config.
  #
  # Two module classes are exported from ONE definition (shared option schema +
  # renderer):
  #   * flake.modules.nixos.mcl-reprobuild        — installs `repro` on the
  #     system PATH (`environment.systemPackages`) + system-wide
  #     `/etc/repro/caches.conf`. Wired into the infra fleet via
  #     `default-server-config` so every server gets it.
  #   * flake.modules.homeManager.mcl-reprobuild  — installs `repro` on the user
  #     PATH (`home.packages`) + per-user `~/.config/repro/caches.conf`. Wired
  #     into ~/dotfiles for workstations.
  #
  # The R1 client (caches_config.nim) reads INI: system /etc/repro/caches.conf
  # first, then ~/.config/repro/caches.conf (user OVERRIDES/EXTENDS by name).
  # R1 is DEFAULT-UNTRUSTED: a cache is substituted from ONLY when its config
  # entry lists a trusted-public-key. Rendering the fleet key here is what turns
  # substitution ON — the load-bearing bit.

  # The reprobuild `repro` CLI (the full toolset — includes `repro`,
  # `repro-binary-cache-client`, etc.), resolved against nixos-modules' OWN flake
  # inputs (`inputs.reprobuild.packages.<system>`) per the consuming host's
  # system, so a consuming flake (infra, ~/dotfiles) does NOT need a `reprobuild`
  # input of its own. Indexed directly rather than via `withSystem` on purpose:
  # `withSystem` reads `config.allSystems`, which — when this module is one of
  # several classes forced through `top.config.flake` inside a `perSystem`
  # check — would create a perSystem→flake→perSystem eval cycle. Direct input
  # indexing has no such dependency on the flake's own perSystem.
  defaultPackageFor = system: inputs.reprobuild.packages.${system}.reprobuild;

  # Shared option schema + caches.conf renderer, parameterised only by the
  # concrete lib/pkgs of whichever module class instantiates it.
  mkShared =
    { lib, pkgs }:
    let
      inherit (lib)
        mkEnableOption
        mkOption
        types
        ;

      cacheType = types.submodule (
        { name, ... }:
        {
          options = {
            name = mkOption {
              type = types.str;
              default = name;
              description = ''
                Cache name — the `[section]` header in caches.conf and the key
                the user file overrides the system file by.
              '';
            };
            url = mkOption {
              type = types.str;
              example = "https://repro-cache.metacraft-labs.com";
              description = "HTTP(S) base URL of the reprobuild binary cache.";
            };
            trustedPublicKeys = mkOption {
              type = types.listOf types.str;
              default = [ ];
              description = ''
                130-hex-char (65-byte uncompressed ECDSA-P256) producer public
                keys trusted for this cache. R1 is default-untrusted: an entry
                with NO trusted key is never substituted from, so this list is
                what ENABLES substitution.
              '';
            };
            priority = mkOption {
              type = types.int;
              default = 30;
              description = "Substitution priority (lower wins, Nix convention).";
            };
          };
        }
      );

      # Render one `[cache]` section. Values are quoted, matching the R1
      # parser's canonical accepted syntax (std/parsecfg; see the R1 unit test
      # t_r1_caches_config.nim, whose fixtures use `url = "…"` /
      # `trusted-public-keys = "…"` / `priority = 20`). Trusted keys are joined
      # with `, ` (the parser splits on comma and/or whitespace).
      renderCache = c: ''
        [${c.name}]
        url = "${c.url}"
        trusted-public-keys = "${lib.concatStringsSep ", " c.trustedPublicKeys}"
        priority = ${toString c.priority}
      '';

      mkOptions = {
        enable = mkEnableOption "the reprobuild `repro` build CLI on PATH + rendered caches.conf";

        package = mkOption {
          type = types.package;
          default = defaultPackageFor pkgs.stdenv.hostPlatform.system;
          defaultText = lib.literalMD "the reprobuild flake's `reprobuild` (native `repro`) package";
          description = "Package providing the `repro` build CLI (and the bundled cache-client tools).";
        };

        caches = mkOption {
          type = types.attrsOf cacheType;
          default = { };
          description = ''
            Binary caches to render into caches.conf. Each entry becomes one
            `[name]` section with `url`, `trusted-public-keys`, `priority`.
            Leave empty to install `repro` without provisioning any cache trust.
          '';
        };
      };

      # The rendered caches.conf text for a given `caches` attrset. Sections are
      # emitted in name order for a deterministic, diffable file.
      renderConfig =
        caches:
        let
          ordered = lib.sort (a: b: a.name < b.name) (lib.attrValues caches);
        in
        ''
          # Reprobuild binary-cache client trust config (caches.conf).
          # Rendered by nixos-modules mcl-reprobuild. Do not edit; change the
          # module options instead. R1 is default-untrusted: only a cache listing
          # a trusted-public-key here is substituted from.
        ''
        + lib.concatStringsSep "\n" (map renderCache ordered);
    in
    {
      inherit mkOptions renderConfig;
    };
in
{
  # ── System-wide (NixOS): repro on PATH + /etc/repro/caches.conf ───────────────
  flake.modules.nixos.mcl-reprobuild =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.reprobuild;
      shared = mkShared { inherit lib pkgs; };
    in
    {
      options.programs.reprobuild = shared.mkOptions;

      config = lib.mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];
        # System file the R1 client reads FIRST (the user file extends it). Only
        # written when caches are declared, so `enable` alone just installs repro.
        environment.etc."repro/caches.conf" = lib.mkIf (cfg.caches != { }) {
          text = shared.renderConfig cfg.caches;
        };
      };
    };

  # ── Per-user (home-manager): repro on PATH + ~/.config/repro/caches.conf ──────
  flake.modules.homeManager.mcl-reprobuild =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.reprobuild;
      shared = mkShared { inherit lib pkgs; };
    in
    {
      options.programs.reprobuild = shared.mkOptions;

      config = lib.mkIf cfg.enable {
        home.packages = [ cfg.package ];
        # XDG user file the R1 client reads AFTER the system file, overriding /
        # extending it by cache name (~/.config/repro/caches.conf).
        xdg.configFile."repro/caches.conf" = lib.mkIf (cfg.caches != { }) {
          text = shared.renderConfig cfg.caches;
        };
      };
    };
}
