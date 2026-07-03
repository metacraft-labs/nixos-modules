{ inputs, withSystem, ... }:
{
  # Windows-Runner-Binary-Cache-Deploy M1 — host reprobuild's binary-cache
  # HTTP daemon (`apps/repro-binary-cache`) as a NixOS systemd service, the
  # way `mcl.attic-cache-host` hosts atticd. The daemon binds 0.0.0.0:7878 by
  # default, keeps its durable store under `--root`, and serves GET /healthz,
  # GET /cache-info, GET /manifests/<hex>, GET /payloads/<hex>, POST /publish.
  #
  # This module owns only the generic hosting machinery (package, hardened
  # long-running unit, durable StateDirectory, optional firewall opening). It
  # deliberately does NOT gate the bind address on NetBird: the bind address is
  # an option so the infra layer (a later milestone) can restrict it to the
  # overlay/LAN interface the same way the attic host layers its network ACL.
  flake.modules.nixos.mcl-repro-binary-cache =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.mcl-repro-binary-cache;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        ;

      # Default to the reprobuild flake's `repro-binary-cache` package built for
      # this host's system. Consumers/tests may override `package`.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { inputs', ... }: inputs'.reprobuild.packages.repro-binary-cache
      );
    in
    {
      options.services.mcl-repro-binary-cache = {
        enable = mkEnableOption "the reprobuild binary-cache HTTP server (repro-binary-cache daemon)";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalMD "the reprobuild flake's `repro-binary-cache` package";
          description = "Package providing the `repro-binary-cache` daemon binary.";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/repro-binary-cache";
          description = ''
            Durable on-disk store root passed to the daemon as `--root`. Holds
            the CAS payloads, manifests, index, and the persistent producer
            ECDSA-P256 keypair. Provisioned as a systemd StateDirectory.
          '';
        };

        storeDir = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Value advertised in `GET /cache-info` as StoreDir (`--store-dir`).
            Null lets the daemon default it to `<stateDir>/store`.
          '';
        };

        listenAddress = mkOption {
          type = types.str;
          default = "0.0.0.0";
          description = ''
            Interface the daemon binds. Defaults to all interfaces; the infra
            layer restricts this to the NetBird/LAN interface in production.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 7878;
          description = "TCP port the daemon listens on.";
        };

        softCapBytes = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = null;
          description = ''
            Optional soft eviction cap (REPRO_BINARY_CACHE_SOFT_CAP_BYTES).
            Null keeps the daemon's compiled default.
          '';
        };

        hardCapBytes = mkOption {
          type = types.nullOr types.ints.unsigned;
          default = null;
          description = ''
            Optional hard eviction cap (REPRO_BINARY_CACHE_HARD_CAP_BYTES).
            Null keeps the daemon's compiled default.
          '';
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = "Open `port` in the host firewall for the listen address.";
        };

        # Windows-Runner-Binary-Cache-Deploy M7 prereq (c) — opt-in HTTPS.
        #
        # When BOTH tlsCertFile and tlsKeyFile are set, the daemon is passed
        # `--tls-cert`/`--tls-key` and serves over TLS (the `-d:ssl` server
        # accept loop in server.nim). Both null (the default) keeps the plain
        # HTTP behaviour byte-identical to M1/M2. The files are handed to the
        # DynamicUser service via systemd LoadCredential, so they may live in
        # a root-only path (e.g. an agenix secret) yet still be readable by
        # the sandboxed unit at %d/<name>.
        tlsCertFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            PEM certificate for HTTPS, passed to the daemon as `--tls-cert`.
            Must be set together with `tlsKeyFile`. Null (default) ⇒ plain
            HTTP, behaviour unchanged. Loaded via systemd LoadCredential so
            it need not be world-readable.
          '';
        };

        tlsKeyFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            PEM private key for the HTTPS certificate, passed as `--tls-key`.
            Must be set together with `tlsCertFile`. Loaded via systemd
            LoadCredential so the private key never needs to be world-readable.
          '';
        };

        allowedSignersFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Publish-authorization allowlist, passed to the daemon as
            `--allowed-signers`. One 130-char hex ECDSA-P256 producer pubkey
            per non-blank/#-line (the cache's trust-anchor format). When set,
            POST /publish is ENFORCED: a manifest whose producer pubkey is not
            listed is rejected HTTP 403 with nothing stored. Null (default) ⇒
            permissive publish (v1 single-tenant default, unchanged). Loaded
            via systemd LoadCredential.
          '';
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = (cfg.tlsCertFile == null) == (cfg.tlsKeyFile == null);
            message =
              "services.mcl-repro-binary-cache: tlsCertFile and tlsKeyFile must "
              + "be set together (both null for plain HTTP, or both a path for HTTPS).";
          }
        ];

        environment.systemPackages = [ cfg.package ];

        networking.firewall = mkIf cfg.openFirewall {
          allowedTCPPorts = [ cfg.port ];
        };

        systemd.services.mcl-repro-binary-cache = {
          description = "Reprobuild binary-cache HTTP server";
          documentation = [ "https://github.com/metacraft-labs/reprobuild" ];
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "simple";
            ExecStart = lib.escapeShellArgs (
              [
                (lib.getExe cfg.package)
                "--root=%S/repro-binary-cache"
                "--listen=${cfg.listenAddress}:${toString cfg.port}"
              ]
              ++ lib.optional (cfg.storeDir != null) "--store-dir=${cfg.storeDir}"
              # M7 prereq (c): HTTPS + publish-authorization allowlist. The
              # cert/key/signers files are LoadCredential-provisioned under
              # $CREDENTIALS_DIRECTORY (%d) so the DynamicUser + ProtectSystem=
              # strict sandbox can read them without them being world-readable.
              ++ lib.optionals (cfg.tlsCertFile != null) [
                "--tls-cert=%d/tls-cert"
                "--tls-key=%d/tls-key"
              ]
              ++ lib.optional (cfg.allowedSignersFile != null) "--allowed-signers=%d/allowed-signers"
            );
            Restart = "on-failure";
            RestartSec = "5s";

            # Durable store: systemd creates + owns /var/lib/repro-binary-cache
            # for the DynamicUser and exposes it as %S/repro-binary-cache.
            DynamicUser = true;
            StateDirectory = "repro-binary-cache";
            StateDirectoryMode = "0700";

            # M7 prereq (c): stage the TLS cert/key + allowed-signers file into
            # the per-service credentials store (%d = $CREDENTIALS_DIRECTORY),
            # readable by the sandboxed DynamicUser even under ProtectSystem=
            # strict. Only wired when the corresponding option is set.
            LoadCredential =
              lib.optionals (cfg.tlsCertFile != null) [
                "tls-cert:${cfg.tlsCertFile}"
                "tls-key:${cfg.tlsKeyFile}"
              ]
              ++ lib.optional (cfg.allowedSignersFile != null) "allowed-signers:${cfg.allowedSignersFile}";

            Environment =
              lib.optional (
                cfg.softCapBytes != null
              ) "REPRO_BINARY_CACHE_SOFT_CAP_BYTES=${toString cfg.softCapBytes}"
              ++ lib.optional (
                cfg.hardCapBytes != null
              ) "REPRO_BINARY_CACHE_HARD_CAP_BYTES=${toString cfg.hardCapBytes}";

            # Hardening — mirror the posture of the atticd/attic host unit.
            NoNewPrivileges = true;
            ProtectSystem = "strict";
            ProtectHome = true;
            PrivateTmp = true;
            PrivateDevices = true;
            ProtectKernelTunables = true;
            ProtectKernelModules = true;
            ProtectKernelLogs = true;
            ProtectControlGroups = true;
            ProtectClock = true;
            ProtectHostname = true;
            ProtectProc = "invisible";
            ProcSubset = "pid";
            RestrictNamespaces = true;
            RestrictRealtime = true;
            RestrictSUIDSGID = true;
            LockPersonality = true;
            MemoryDenyWriteExecute = true;
            RemoveIPC = true;
            RestrictAddressFamilies = [
              "AF_INET"
              "AF_INET6"
              "AF_UNIX"
            ];
            SystemCallArchitectures = "native";
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
              "~@resources"
            ];
            CapabilityBoundingSet = [ "" ];
            AmbientCapabilities = [ "" ];
            UMask = "0077";
          };
        };
      };
    };
}
