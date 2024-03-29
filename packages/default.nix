{...}: {
  perSystem = {
    inputs',
    pkgs,
    ...
  }: let
    inherit (pkgs.hostPlatform) isLinux isx86;
  in rec {
    packages =
      {
        lido-withdrawals-automation = pkgs.callPackage ./lido-withdrawals-automation {};
        pyroscope = pkgs.callPackage ./pyroscope {};
        grafana-agent = import ./grafana-agent {inherit inputs';};
        ci-matrix = pkgs.callPackage ./ci-matrix {};
      }
      // pkgs.lib.optionalAttrs isLinux {
        inherit (inputs'.validator-ejector.packages) validator-ejector;
      }
      // pkgs.lib.optionalAttrs (isLinux && isx86) {
        mcl = pkgs.callPackage ./mcl {
          inherit (inputs'.dlang-nix.packages) dub;
          dcompiler = inputs'.dlang-nix.packages.ldc;
        };
      };
    checks = packages;
  };
}
