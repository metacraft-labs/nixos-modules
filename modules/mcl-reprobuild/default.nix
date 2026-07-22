{ inputs, ... }:
let
  # A reusable module that installs the reprobuild `repro` build CLI onto a host
  # AND renders the R1 binary-cache client trust config (`caches.conf`) from
  # declarative options — so the whole fleet (servers + workstations + CI
  # runners) can both BUILD with `repro` and SUBSTITUTE from the managed cache,
  # the same way Nix+Attic substituters/trusted-public-keys are provisioned.
  #
  # This SUPERSEDES the former `mcl-repro-cache-client` module. That module
  # installed a SEPARATE `repro-binary-cache-client` package which was just
  # `reprobuild.overrideAttrs { pname = …; }` — the identical toolset renamed,
  # so it duplicated the full closure and collided with this module on
  # `lib/librepro_monitor_shim.so`. That standalone package was retired: the
  # client toolset now ships as the `repro cache` subcommand group INSIDE the
  # `reprobuild` package (Binary-Caches.md §"Client CLI Surface"), so there is
  # one package here and the cache-client behaviour is purely the rendered
  # `caches.conf` config.
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

  # The reprobuild `repro` CLI (the full toolset — `repro`, with the binary-
  # cache client folded in as its `repro cache` subcommand, etc.), resolved
  # against nixos-modules' OWN flake
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

        # Ephemeral-State-Leases L4 (§4.1): the daemon-hosted lease registry
        # + wall-clock reaper. Two scopes, two units:
        #   * a per-user `repro daemon serve` (systemd.user) owning the user
        #     lease scope (`~/.cache/repro/state`);
        #   * a system `repro daemon serve --system` owning the system lease
        #     scope (`/var/lib/repro/state`).
        # Both loop the L1 on-disk store, so leases + the reap schedule
        # survive a restart by construction.
        enableUserDaemon = mkEnableOption ''
          the per-user reprobuild daemon (`repro daemon serve`) as a
          `systemd.user` service. Beyond build/watch routing it hosts the
          USER-scope ephemeral-state lease registry + the wall-clock reaper
          (Ephemeral-State-Leases §4): it renews leases sent by `repro`
          reconciles and reaps idle leased state under `~/.cache/repro/state`.
          Requires `enable`
        '';

        enableSystemLeaseReaper = mkEnableOption ''
          the SYSTEM-scope reprobuild lease reaper (`repro daemon serve
          --system`) as a system service. It owns the system lease scope:
          the wall-clock reaper for fleet/CI-shared leased ephemeral state
          under `systemLeaseStateDir/state` (Ephemeral-State-Leases §4.1).
          Requires `enable`
        '';

        systemLeaseStateDir = mkOption {
          type = types.str;
          default = "/var/lib/repro";
          description = ''
            The system lease reaper's state root PARENT. The reaper serves the
            `state/` subdirectory under it (the `$REPRO_SYSTEM_STATE_DIR`
            convention `repro` uses to derive `systemLeaseStoreRoot`), so the
            on-disk store is `''${systemLeaseStateDir}/state`. Provisioned via
            `StateDirectory`, so it survives reaper restarts.
          '';
        };

        enableShellHook = mkEnableOption ''
          the direnv-like `repro shell hook` shell integration. Injects the
          on-`cd` reprobuild dev-env activation hook into interactive bash,
          zsh, and fish (the shells these modules manage; pwsh/nushell are
          out of scope here and handled by reprobuild's Windows home profile).
          The hook is a cheap upward walk for `reprobuild.nim` / `repro.nim` /
          `.repro/dev-env.lock` that no-ops in trees with no reprobuild
          dev-env, so it is safe to enable fleet-wide even where no `repro.nim`
          exists yet. Requires `enable`; the hook shells out to `repro` from
          this module's `package`
        '';

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
        # Direnv-like on-`cd` dev-env activation, injected system-wide into the
        # shells NixOS manages. bash/zsh source via `eval`, fish via `| source`
        # (the sourcing idioms `repro shell hook <shell>` documents). A no-op
        # walk where there is no reprobuild dev-env.
        programs.bash.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook bash)"
        '';
        programs.zsh.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook zsh)"
        '';
        programs.fish.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          ${cfg.package}/bin/repro shell hook fish | source
        '';

        # Ephemeral-State-Leases L4 (§4.1) — the SYSTEM-scope lease reaper.
        # `repro daemon serve --system` binds the system lease scope + reaps
        # idle leased ephemeral state under `''${systemLeaseStateDir}/state`
        # on its wall-clock tick. Type=simple long-running unit;
        # `StateDirectory` provisions the durable store so leases + the reap
        # schedule survive a restart (the store is the source of truth, not
        # daemon memory). `--state-root` points it explicitly at the
        # StateDirectory subdir, and the endpoint/state-dir live under
        # `/run`+`/var/lib` so it never collides with a per-user daemon.
        systemd.services.repro-lease-reaper = lib.mkIf cfg.enableSystemLeaseReaper {
          description = "Reprobuild system-scope ephemeral-state lease reaper";
          wantedBy = [ "multi-user.target" ];
          after = [ "network.target" ];
          serviceConfig = {
            Type = "simple";
            ExecStart = lib.concatStringsSep " " [
              "${cfg.package}/bin/repro"
              "daemon"
              "serve"
              "--foreground"
              "--system"
              "--endpoint"
              "/run/repro/repro-system-daemon.sock"
              "--state-dir"
              "/var/lib/repro/daemon"
              "--state-root"
              "${cfg.systemLeaseStateDir}/state"
            ];
            Restart = "on-failure";
            RestartSec = 5;
            RuntimeDirectory = "repro";
            # `state` is the lease store; `daemon` is the daemon's own
            # runtime state-dir (logs/status/lock). Both under /var/lib/repro.
            StateDirectory = "repro repro/state repro/daemon";
            DynamicUser = false;
          };
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
        # Direnv-like on-`cd` dev-env activation, injected per-user into the
        # shells home-manager manages. Uses each shell module's current init
        # option (bash `initExtra`, zsh `initContent`, fish
        # `interactiveShellInit`). A no-op walk where there is no reprobuild
        # dev-env, so it coexists with an already-active direnv hook.
        programs.bash.initExtra = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook bash)"
        '';
        programs.zsh.initContent = lib.mkIf cfg.enableShellHook ''
          eval "$(${cfg.package}/bin/repro shell hook zsh)"
        '';
        programs.fish.interactiveShellInit = lib.mkIf cfg.enableShellHook ''
          ${cfg.package}/bin/repro shell hook fish | source
        '';

        # Ephemeral-State-Leases L4 (§4.1) — the per-user daemon as a
        # `systemd.user` service. `repro daemon serve` hosts the USER-scope
        # lease registry + wall-clock reaper (renews leases sent by `repro`
        # reconciles, reaps idle leased state under `~/.cache/repro/state`).
        # Type=simple long-running; Restart keeps it resident so wall-clock
        # reaping is prompt. The store is on disk, so leases survive a restart
        # of this unit. The daemon self-discovers its per-user socket +
        # state-dir from `$XDG_*`, so no explicit endpoint is pinned here.
        systemd.user.services.repro-daemon = lib.mkIf cfg.enableUserDaemon {
          Unit = {
            Description = "Reprobuild per-user daemon (lease registry + reaper)";
            After = [ "default.target" ];
          };
          Install.WantedBy = [ "default.target" ];
          Service = {
            Type = "simple";
            ExecStart = "${cfg.package}/bin/repro daemon serve --foreground";
            Restart = "on-failure";
            RestartSec = 5;
          };
        };
      };
    };
}
