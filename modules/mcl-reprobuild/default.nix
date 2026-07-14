{ inputs, ... }:
let
  # A reusable module that installs the reprobuild `repro` build CLI onto a
  # host, mirroring the sibling `mcl-repro-cache-client` module (which installs
  # the binary-cache *client*). This one installs the actual build tool.
  #
  # Two module classes are exported from ONE shared option schema:
  #   * flake.modules.nixos.mcl-reprobuild        — installs `repro` on the
  #     system PATH (`environment.systemPackages`). Wired into the infra fleet
  #     so servers get the build CLI.
  #   * flake.modules.homeManager.mcl-reprobuild  — installs `repro` on the
  #     user PATH (`home.packages`). Wired into ~/dotfiles for workstations.
  #
  # This module installs the NATIVE nix-built `repro` package
  # (`inputs.reprobuild.packages.<system>.reprobuild`, mainProgram "repro",
  # dynamically linked). NixOS / home-manager hosts have the nix store, so the
  # native package is correct. The self-contained `repro-portable` bundle is for
  # NON-nix hosts (e.g. the Debian runner image) and is NOT installed here.

  # The reprobuild `repro` CLI, resolved against nixos-modules' OWN flake inputs
  # (`inputs.reprobuild.packages.<system>`) per the consuming host's system, so
  # a consuming flake (infra, ~/dotfiles) does NOT need a `reprobuild` input of
  # its own. Indexed directly rather than via `withSystem` on purpose:
  # `withSystem` reads `config.allSystems`, which — when this module is one of
  # several classes forced through `top.config.flake` inside a `perSystem`
  # check — would create a perSystem→flake→perSystem eval cycle. Direct input
  # indexing has no such dependency on the flake's own perSystem.
  defaultPackageFor = system: inputs.reprobuild.packages.${system}.reprobuild;

  # Shared option schema, parameterised only by the concrete lib/pkgs of
  # whichever module class instantiates it.
  mkOptions =
    { lib, pkgs }:
    let
      inherit (lib) mkEnableOption mkOption types;
    in
    {
      enable = mkEnableOption "the reprobuild `repro` build CLI on PATH";

      package = mkOption {
        type = types.package;
        default = defaultPackageFor pkgs.stdenv.hostPlatform.system;
        defaultText = lib.literalMD "the reprobuild flake's `reprobuild` (native `repro`) package";
        description = "Package providing the `repro` build CLI.";
      };
    };
in
{
  # ── System-wide (NixOS) ──────────────────────────────────────────────────────
  flake.modules.nixos.mcl-reprobuild =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.reprobuild;
    in
    {
      options.programs.reprobuild = mkOptions { inherit lib pkgs; };

      config = lib.mkIf cfg.enable {
        # hiPrio: the full `reprobuild` package and the sibling
        # `repro-binary-cache-client` (installed by mcl-repro-cache-client) both
        # ship lib/librepro_monitor_shim.so, so buildEnv errors on the collision
        # when both modules are enabled on one host. Give reprobuild priority so
        # its copy wins the merge instead of aborting the profile build.
        environment.systemPackages = [ (lib.hiPrio cfg.package) ];
      };
    };

  # ── Per-user (home-manager) ──────────────────────────────────────────────────
  flake.modules.homeManager.mcl-reprobuild =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.programs.reprobuild;
    in
    {
      options.programs.reprobuild = mkOptions { inherit lib pkgs; };

      config = lib.mkIf cfg.enable {
        # hiPrio — see the NixOS class above: avoids the buildEnv collision on
        # librepro_monitor_shim.so with the repro-binary-cache-client package.
        home.packages = [ (lib.hiPrio cfg.package) ];
      };
    };
}
