{
  lib,
  inputs,
  ...
}:
{
  perSystem =
    {
      inputs',
      pkgs,
      ...
    }:
    let
      inherit (lib) optionalAttrs versionAtLeast callPackageWith;
      inherit (pkgs) system;
      inherit (pkgs.hostPlatform) isLinux isx86;
      inherit (inputs) crane;

      cardano-node_flake = builtins.getFlake "github:input-output-hk/cardano-node/f0b4ac897dcbefba9fa0d247b204a24543cf55f6";
    in
    rec {
      legacyPackages = rec {
        inputs = {
          nixpkgs = rec {
            inherit (pkgs) cachix;
            nix =
              let
                nixStable = pkgs.nixVersions.stable;
              in
              assert versionAtLeast nixStable.version "2.24.10";
              nixStable;
            nix-eval-jobs = pkgs.nix-eval-jobs.override { inherit nix; };
            nix-fast-build = pkgs.nix-fast-build.override { inherit nix-eval-jobs; };
          };
          agenix = inputs'.agenix.packages;
          devenv = inputs'.devenv.packages;
          disko = inputs'.disko.packages;
          dlang-nix = inputs'.dlang-nix.packages;
          ethereum-nix = inputs'.ethereum-nix.packages;
          fenix = inputs'.fenix.packages;
          git-hooks-nix = inputs'.git-hooks-nix.packages;
          microvm = inputs'.microvm.packages;
          nix-fast-build = inputs'.nix-fast-build.packages;
          nixos-anywhere = inputs'.nixos-anywhere.packages;
          terranix = inputs'.terranix.packages;
          treefmt-nix = inputs'.treefmt-nix.packages;
        };

        rust-stable =
          with inputs'.fenix.packages;
          with stable;
          combine [
            cargo
            clippy
            rust-analyzer
            rust-src
            rustc
            rustfmt
            targets.wasm32-unknown-unknown.stable.rust-std
            targets.wasm32-wasip1.stable.rust-std
            targets.wasm32-wasip2.stable.rust-std
          ];

        rust-latest =
          with inputs'.fenix.packages;
          with latest;
          combine [
            cargo
            clippy
            rust-analyzer
            rust-src
            rustc
            rustfmt
            targets.wasm32-unknown-unknown.latest.rust-std
            targets.wasm32-wasip1.latest.rust-std
            targets.wasm32-wasip2.latest.rust-std
          ];

        craneLib = crane.mkLib pkgs;
        craneLib-fenix-stable = craneLib.overrideToolchain rust-stable;
        craneLib-fenix-latest = craneLib.overrideToolchain rust-latest;

        rustPlatformStable = pkgs.makeRustPlatform {
          rustc = rust-stable;
          cargo = rust-stable;
        };
        rustPlatformNightly = pkgs.makeRustPlatform {
          rustc = rust-latest;
          cargo = rust-latest;
        };

        inherit (cardano-node_flake.outputs.packages.${system}) cardano-node cardano-cli;

        metacraft-labs = packages;

        inherit (inputs'.nix2container.packages) nix2container;

        # noir = inputs'.noir.packages; # noir flake is not in inputs
        ethereum_nix = inputs'.ethereum_nix.packages;

        all = pkgs.symlinkJoin {
          name = "all";
          paths = builtins.attrValues packages;
        };
      };

      packages =
        let
          inherit (pkgs)
            lib
            darwin
            hostPlatform
            symlinkJoin
            fetchFromGitHub
            ;
          inherit (legacyPackages)
            rustPlatformStable
            craneLib
            craneLib-fenix-stable
            craneLib-fenix-latest
            cardano-node
            cardano-cli
            ;
          python3Packages = pkgs.python3Packages;

          callPackage = callPackageWith (pkgs // { rustPlatform = rustPlatformStable; });
          darwinPkgs = {
            inherit (darwin.apple_sdk.frameworks)
              CoreFoundation
              Foundation
              Security
              SystemConfiguration
              ;
          };
          # RapidSnark
          ffiasm-src = callPackage ./ffiasm-src/default.nix { };
          zqfield = callPackage ./ffiasm/zqfield.nix {
            inherit ffiasm-src;
          };
          # Pairing Groups on BN-254, aka alt_bn128
          # Source:
          # https://zips.z.cash/protocol/protocol.pdf (section 5.4.9.1)
          # See also:
          # https://eips.ethereum.org/EIPS/eip-196
          # https://eips.ethereum.org/EIPS/eip-197
          # https://hackmd.io/@aztec-network/ByzgNxBfd
          # https://hackmd.io/@jpw/bn254
          zqfield-bn254 = symlinkJoin {
            name = "zqfield-bn254";
            paths = [
              (zqfield {
                primeNumber = "21888242871839275222246405745257275088696311157297823662689037894645226208583";
                name = "Fq";
              })
              (zqfield {
                primeNumber = "21888242871839275222246405745257275088548364400416034343698204186575808495617";
                name = "Fr";
              })
            ];
          };
          ffiasm = callPackage ./ffiasm/default.nix {
            inherit ffiasm-src zqfield-bn254;
          };
          rapidsnark = callPackage ./rapidsnark/default.nix {
            inherit ffiasm zqfield-bn254;
          };

          # Elrond / MultiversX
          # copied from https://github.com/NixOS/nixpkgs/blob/8df7949791250b580220eb266e72e77211bedad9/pkgs/development/python-modules/cryptography/default.nix
          cattrs22-2 = pkgs.python3Packages.cattrs.overrideAttrs (
            finalAttrs: previousAttrs: {
              version = "22.2.0";

              src = fetchFromGitHub {
                owner = "python-attrs";
                repo = "cattrs";
                rev = "v22.2.0";
                hash = "sha256-Qnrq/mIA/t0mur6IAen4vTmMIhILWS6v5nuf+Via2hA=";
              };

              patches = [ ];
            }
          );

          corepack-shims = callPackage ./corepack-shims/default.nix { };

          elrond-go = callPackage ./elrond-go/default.nix { };
          elrond-proxy-go = callPackage ./elrond-proxy-go/default.nix { };

          graphql = callPackage ./graphql/default.nix { inherit cardano-cli cardano-node; };
          cardano = callPackage ./cardano/default.nix { inherit cardano-cli cardano-node graphql; };

          polkadot-generic = callPackage ./polkadot/default.nix {
            craneLib = craneLib-fenix-stable;
            inherit (darwin) libiconv;
            inherit (darwinPkgs)
              CoreFoundation
              Security
              SystemConfiguration
              ;
          };
          polkadot = polkadot-generic { };
          polkadot-fast = polkadot-generic { enableFastRuntime = true; };

          fetchGitHubReleaseAsset =
            {
              owner,
              repo,
              tag,
              asset,
              hash,
            }:
            pkgs.fetchzip {
              url = "https://github.com/${owner}/${repo}/releases/download/${tag}/${asset}";
              inherit hash;
              stripRoot = false;
            };

          installSourceAndCargo = rust-toolchain: rec {
            # In certain cases, this phase replaces rust toolchain references with /nix/store/eee...
            doNotRemoveReferencesToRustToolchain = true;

            installPhaseCommand = ''
              mkdir -p "$out"/bin
              # Install source code
              cp -r /build/source/. "$out"
              # Install cargo commands
              ln -s "${rust-toolchain}"/bin/* "$out"/bin/
              # Install binaries
              for result in target/release/*
              do
                [ "''${result:15:5}" != 'crane' -a -f "$result" -a -x "$result" ] \
                  && ln -s "$out/$result" "$out"/bin/
              done
            '';
          };

          args-zkVM = {
            rustFromToolchainFile = inputs'.fenix.packages.fromToolchainFile;
            fenix = inputs'.fenix.packages;
            inherit craneLib;
            inherit installSourceAndCargo;
          };

          args-zkVM-rust = {
            inherit fetchGitHubReleaseAsset;
          };
        in
        rec {
          lido-withdrawals-automation = callPackage ./lido-withdrawals-automation { };
          pyroscope = callPackage ./pyroscope { };
          random-alerts = callPackage ./random-alerts { };

          blst = callPackage ./blst { };

          avalanche-cli = callPackage ./avalanche-cli/default.nix {
            inherit blst;
          };

          bnb-beacon-node = callPackage ./bnb-beacon-node { };

          gaiad = callPackage ./gaiad { };
          cosmos-theta-testnet = callPackage ./cosmos-theta-testnet { inherit gaiad; };

          circom = callPackage ./circom/default.nix { craneLib = craneLib-fenix-stable; };
          circ = callPackage ./circ/default.nix { craneLib = craneLib-fenix-stable; };

          emscripten = pkgs.emscripten.overrideAttrs (_old: {
            postInstall = ''
              pushd $TMPDIR
              echo 'int __main_argc_argv( int a, int b ) { return 42; }' >test.c
              for MEM in "-s ALLOW_MEMORY_GROWTH" ""; do
                for LTO in -flto ""; do
                  # FIXME: change to the following, once binaryen is updated to
                  # >= v119 in Nixpkgs:
                  # for OPT in "-O2" "-O3" "-Oz" "-Os"; do
                  for OPT in "-O2"; do
                    $out/bin/emcc $MEM $LTO $OPT -s WASM=1 -s STANDALONE_WASM test.c
                  done
                done
              done
            '';
          });

          circom_runtime = callPackage ./circom_runtime/default.nix { };

          # Polkadot
          inherit polkadot polkadot-fast;

          inherit corepack-shims;
        }
        // optionalAttrs (system == "x86_64-linux" || system == "aarch64-darwin") {
          grafana-agent = import ./grafana-agent { inherit inputs'; };
          secret = import ./secret { inherit inputs' pkgs; };
        }
        // optionalAttrs isLinux rec {
          folder-size-metrics = callPackage ./folder-size-metrics { };

          kurtosis = callPackage ./kurtosis/default.nix { };

          wasmd = callPackage ./wasmd/default.nix { };

          # Solana
          solana-validator = callPackage ./solana-validator { };

          # inherit elrond-go elrond-proxy-go; # Require buildGo117Module

          # EOS / Antelope
          eos-vm = callPackage ./eos-vm/default.nix { };
          cdt = callPackage ./cdt/default.nix { };

          zkwasm = callPackage ./zkwasm/default.nix args-zkVM;
          jolt-guest-rust = callPackage ./jolt-guest-rust/default.nix args-zkVM-rust;
          jolt = callPackage ./jolt/default.nix (args-zkVM // { inherit jolt-guest-rust; });
          zkm-rust = callPackage ./zkm-rust/default.nix args-zkVM-rust;
          zkm = callPackage ./zkm/default.nix (args-zkVM // { inherit zkm-rust; });
          nexus = callPackage ./nexus/default.nix args-zkVM;
          sp1-rust = callPackage ./sp1-rust/default.nix args-zkVM-rust;
          sp1 = callPackage ./sp1/default.nix (args-zkVM // { inherit sp1-rust; });
          risc0-rust = callPackage ./risc0-rust/default.nix args-zkVM-rust;
          risc0 = callPackage ./risc0/default.nix (args-zkVM // { inherit risc0-rust; });
        }
        // optionalAttrs (system == "x86_64-linux") rec {
          mcl = callPackage ./mcl {
            buildDubPackage = inputs'.dlang-nix.legacyPackages.buildDubPackage.override {
              ldc = inputs'.dlang-nix.packages."ldc-binary-1_34_0";
            };
            inherit (legacyPackages.inputs.nixpkgs) cachix nix nix-eval-jobs;
          };

          pistache = callPackage ./pistache/default.nix { };
          inherit zqfield-bn254;
          rapidsnark-server = callPackage ./rapidsnark-server/default.nix {
            inherit
              ffiasm
              zqfield-bn254
              rapidsnark
              pistache
              ;
          };
        }
        // lib.optionalAttrs isx86 rec {
          inherit
            zqfield-bn254
            ffiasm
            ffiasm-src
            rapidsnark
            ;

          inherit cardano graphql;
        };
    };
}
