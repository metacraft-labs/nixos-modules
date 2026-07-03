{ withSystem, ... }:
{
  # Ephemeral-Windows-Runners-GARM M0 — host cloudbase/garm (the GitHub Actions
  # Runner Manager control plane) as an opt-in NixOS systemd service, mirroring
  # the shape of `services.mcl-repro-binary-cache`: a package option, a
  # `config.toml` generator, a durable StateDirectory for the SQLite DB, and a
  # hardened long-running unit modelled on GARM's own `contrib/garm.service`.
  #
  # M0 scope is DELIBERATELY forge-less and provider-less: GARM boots fine with
  # empty `[[provider]]`/`[[github]]` sections (see cmd/garm/main.go — providers
  # and forges are loaded lazily and an empty set is valid). The provider is
  # wired in M1 (`garm-provider-vmharness`) and the forge/pool in M4. This
  # module therefore stays provider-agnostic; it only owns the generic hosting
  # machinery + a minimal, valid config that lets the daemon serve its API.
  #
  # SECRETS. GARM's config validation requires TWO strong secrets:
  #   * database.passphrase — exactly 32 chars, zxcvbn score 4; encrypts
  #     sensitive columns in the DB. It MUST be stable across restarts or all
  #     encrypted rows become unreadable.
  #   * jwt_auth.secret — non-empty, zxcvbn score 4; signs API/instance JWTs.
  # Neither may live in the world-readable Nix store. So the config.toml is
  # rendered at RUNTIME by an ExecStartPre hook that either (a) reads operator
  # supplied secrets staged via systemd LoadCredential, or (b) generates strong
  # random secrets on first boot and persists them under the StateDirectory
  # (mode 0700) so subsequent restarts reuse them. The store only ever holds a
  # placeholder template with NO secret material.
  flake.modules.nixos.garm =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.garm;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        optionalString
        ;

      # Default to this flake's `garm` package (garm daemon + garm-cli) built
      # for the host system. Consumers/tests may override `package`.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.garm
      );

      # Default to this flake's `garm-provider-vmharness` package (M1). Consumers
      # may override `providers.vmharness.package`.
      defaultVmharnessPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.garm-provider-vmharness
      );

      stateDir = cfg.stateDir;
      dbFile = "${stateDir}/garm.sqlite";
      renderedConfig = "${stateDir}/config.toml";

      vmh = cfg.providers.vmharness;

      # The provider's own config.toml (a DIFFERENT file from garm's config).
      # It holds NO secrets — only the virsh/vm-harness binary paths, the
      # libvirt URI/network, and the golden-image map — so it is safe in the
      # Nix store. Passed to the provider verbatim via GARM_PROVIDER_CONFIG_FILE.
      vmharnessConfigFile = pkgs.writeText "garm-provider-vmharness.toml" ''
        backend = "${vmh.backend}"
        virsh_path = "${vmh.virshPath}"
        vm_harness_path = "${vmh.vmHarnessPath}"
        libvirt_uri = "${vmh.libvirtURI}"
        network = "${vmh.network}"
      ''
      + lib.concatStrings (
        lib.mapAttrsToList (image: spec: ''

          [images."${image}"]
          source_image = "${spec.sourceImage}"
          os_name = "${spec.osName}"
          os_version = "${spec.osVersion}"
        '') vmh.images
      );

      # The `[[provider]]` block appended to garm's config when the vmharness
      # provider is enabled. External-provider keys per config/external.go:
      # provider_executable / config_file / interface_version.
      vmharnessProviderBlock = optionalString vmh.enable ''

        [[provider]]
        name = "${vmh.name}"
        provider_type = "external"
        description = "libvirt/KVM Windows ephemeral runners via vm-harness"

          [provider.external]
          provider_executable = "${lib.getExe vmh.package}"
          config_file = "${vmharnessConfigFile}"
          interface_version = "v0.1.1"
      '';

      # The config template written to the Nix store. Secret fields carry
      # sentinel tokens that the ExecStartPre hook replaces with real secrets
      # from files (never present in the store). Everything else is fully
      # resolved from the module options.
      #
      # Section order follows config/config.go: [default], [logging],
      # [metrics], [jwt_auth], [apiserver], [database]. Providers/forges are
      # intentionally absent (empty ⇒ forge-less M0 boot).
      configTemplate = pkgs.writeText "garm-config.toml.tmpl" ''
        [default]

        [logging]
        log_level = "${cfg.logLevel}"
        log_format = "text"

        [metrics]
        enable = ${lib.boolToString cfg.metrics.enable}
        disable_auth = ${lib.boolToString cfg.metrics.disableAuth}

        [jwt_auth]
        # Replaced at runtime with the real secret (never in the store).
        secret = "@JWT_SECRET@"
        time_to_live = "${cfg.jwtTimeToLive}"

        [apiserver]
        bind = "${cfg.apiServer.bind}"
        port = ${toString cfg.apiServer.port}
        use_tls = false

        [database]
        backend = "sqlite3"
        # Replaced at runtime with the real 32-char passphrase.
        passphrase = "@DB_PASSPHRASE@"

          [database.sqlite3]
          db_file = "${dbFile}"
      ''
      # M1: optionally append the vmharness external provider. Empty (the
      # default) keeps the forge-less/provider-less M0 boot intact.
      + vmharnessProviderBlock;

      # First-run/refresh renderer. Resolves the two secrets, then substitutes
      # them into the template to produce the runtime config under $STATE_DIR.
      #
      # Secret resolution per field:
      #   * If an operator secret file is configured, it is staged by
      #     LoadCredential at $CREDENTIALS_DIRECTORY/<name> and used verbatim
      #     (first line, whitespace-trimmed).
      #   * Otherwise a strong random secret is generated once and persisted at
      #     $STATE_DIR/<name>.secret (mode 0600) and reused thereafter.
      renderScript = pkgs.writeShellApplication {
        name = "garm-render-config";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.openssl
          pkgs.gnused
        ];
        text = ''
          set -euo pipefail

          state_dir="${stateDir}"
          cred_dir="''${CREDENTIALS_DIRECTORY:-}"

          resolve_secret() {
            # $1 = credential name (may be empty), $2 = persisted filename,
            # $3 = number of random bytes when generating.
            local cred_name="$1" persist="$2" nbytes="$3"
            local persist_path="$state_dir/$persist"
            if [ -n "$cred_name" ] && [ -n "$cred_dir" ] && [ -f "$cred_dir/$cred_name" ]; then
              # Operator-supplied secret (via LoadCredential). Trim whitespace.
              head -n1 "$cred_dir/$cred_name" | tr -d '[:space:]'
              return 0
            fi
            if [ ! -f "$persist_path" ]; then
              # Generate a strong random secret once and persist it.
              umask 077
              openssl rand -hex "$nbytes" > "$persist_path"
            fi
            head -n1 "$persist_path" | tr -d '[:space:]'
          }

          # DB passphrase must be EXACTLY 32 chars. 16 random bytes -> 32 hex.
          db_passphrase="$(resolve_secret "${cfg.dbPassphraseCredentialName}" db-passphrase.secret 16)"
          db_passphrase="''${db_passphrase:0:32}"
          # JWT secret: 32 random bytes -> 64 hex (strong).
          jwt_secret="$(resolve_secret "${cfg.jwtSecretCredentialName}" jwt-secret.secret 32)"

          umask 077
          tmp="$(mktemp "${renderedConfig}.XXXXXX")"
          sed \
            -e "s|@DB_PASSPHRASE@|$db_passphrase|" \
            -e "s|@JWT_SECRET@|$jwt_secret|" \
            "${configTemplate}" > "$tmp"
          mv -f "$tmp" "${renderedConfig}"
        '';
      };
    in
    {
      options.services.garm = {
        enable = mkEnableOption "the GARM (GitHub Actions Runner Manager) control-plane daemon";

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalMD "this flake's `garm` package (garm daemon + garm-cli)";
          description = "Package providing the `garm` daemon and `garm-cli` binaries.";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/var/lib/garm";
          description = ''
            Durable state root, provisioned as a systemd StateDirectory. Holds
            the SQLite database, the runtime-rendered `config.toml`, and (unless
            operator secrets are provided) the auto-generated DB passphrase and
            JWT secret. Must be stable: the DB passphrase persisted here
            encrypts data in the database.
          '';
        };

        controllerName = mkOption {
          type = types.str;
          default = "garm";
          description = ''
            Human-readable controller name. GARM assigns the controller its own
            UUID on first run (stored in the DB); this is only a label. Kept as
            an option for parity with the config schema and future use.
          '';
        };

        logLevel = mkOption {
          type = types.enum [
            "debug"
            "info"
            "warn"
            "error"
          ];
          default = "info";
          description = "GARM log level (`[logging].log_level`).";
        };

        jwtTimeToLive = mkOption {
          type = types.str;
          default = "24h";
          description = ''
            JWT token lifetime (`[jwt_auth].time_to_live`), a Go duration
            string. GARM clamps values below its 24h minimum up to 24h.
          '';
        };

        apiServer = {
          bind = mkOption {
            type = types.str;
            default = "0.0.0.0";
            description = ''
              IP address the API server binds (`[apiserver].bind`). Must be a
              valid IP literal. Defaults to all interfaces; the infra layer
              restricts this to an overlay/LAN interface in production.
            '';
          };
          port = mkOption {
            type = types.port;
            default = 9997;
            description = "TCP port the API server listens on (`[apiserver].port`).";
          };
        };

        metrics = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable the Prometheus `/metrics` endpoint (`[metrics].enable`).
              Off by default for the forge-less M0 boot; observability is wired
              in M6.
            '';
          };
          disableAuth = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Serve `/metrics` without JWT auth (`[metrics].disable_auth`).
              Only meaningful when `metrics.enable` is true.
            '';
          };
        };

        # Optional operator-supplied secrets. When unset (default), the service
        # generates strong random secrets on first boot and persists them under
        # stateDir. When set, the referenced files are staged via
        # LoadCredential and used verbatim.
        jwtSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Optional path to a file containing the `[jwt_auth].secret`. Staged
            via systemd LoadCredential (so it need not be world-readable). Null
            (default) ⇒ a strong secret is generated on first boot and persisted
            under stateDir.
          '';
        };

        dbPassphraseFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Optional path to a file containing the `[database].passphrase`
            (must be a strong secret; the first 32 chars are used). Staged via
            LoadCredential. Null (default) ⇒ generated + persisted on first
            boot. NOTE: changing this after the DB has encrypted data
            invalidates that data.
          '';
        };

        openFirewall = mkOption {
          type = types.bool;
          default = false;
          description = "Open the API server `port` in the host firewall.";
        };

        # Internal: credential names used by LoadCredential. Not user-facing.
        jwtSecretCredentialName = mkOption {
          type = types.str;
          default = "jwt-secret";
          internal = true;
          visible = false;
          description = "LoadCredential name for the JWT secret file.";
        };
        dbPassphraseCredentialName = mkOption {
          type = types.str;
          default = "db-passphrase";
          internal = true;
          visible = false;
          description = "LoadCredential name for the DB passphrase file.";
        };

        # Ephemeral-Windows-Runners-GARM M1 — the vmharness external provider.
        # OPT-IN (enable default off) so M0's forge-less/provider-less boot is
        # unaffected. When enabled, a `[[provider]]` block pointing at the
        # `garm-provider-vmharness` binary + its (secret-free) config.toml is
        # appended to garm's config.
        providers.vmharness = {
          enable = mkEnableOption "the garm-provider-vmharness external provider (libvirt/KVM Windows runners)";

          package = mkOption {
            type = types.package;
            default = defaultVmharnessPackage;
            defaultText = lib.literalMD "this flake's `garm-provider-vmharness` package";
            description = "Package providing the `garm-provider-vmharness` binary.";
          };

          name = mkOption {
            type = types.str;
            default = "vmharness";
            description = "GARM provider name (the `[[provider]].name`), referenced by pools.";
          };

          backend = mkOption {
            type = types.enum [ "libvirt" ];
            default = "libvirt";
            description = "vm-harness backend the provider drives.";
          };

          virshPath = mkOption {
            type = types.str;
            default = "${pkgs.libvirt}/bin/virsh";
            defaultText = lib.literalMD "`\${pkgs.libvirt}/bin/virsh`";
            description = "Path to the `virsh` binary the provider shells to.";
          };

          vmHarnessPath = mkOption {
            type = types.str;
            default = "vm-harness";
            description = ''
              Path to the `vm-harness` binary used for per-job clone (M2) and
              config-drive injection (M3). Recorded now; the real clone/inject
              lands in later milestones.
            '';
          };

          libvirtURI = mkOption {
            type = types.str;
            default = "qemu:///system";
            description = "libvirt connection URI passed to virsh.";
          };

          network = mkOption {
            type = types.str;
            default = "default";
            description = "libvirt network the per-job domains attach to.";
          };

          images = mkOption {
            default = { };
            description = ''
              Map of pool image identifier (BootstrapInstance.image) to a golden
              source. If a pool's image is absent here, the raw image string is
              used as the source directly.
            '';
            type = types.attrsOf (
              types.submodule {
                options = {
                  sourceImage = mkOption {
                    type = types.str;
                    description = "Golden qcow2/volume the per-job domain is cloned from.";
                  };
                  osName = mkOption {
                    type = types.str;
                    default = "windows";
                    description = "Reported OS name (surfaced in ProviderInstance.os_name).";
                  };
                  osVersion = mkOption {
                    type = types.str;
                    default = "";
                    description = "Reported OS version (surfaced in ProviderInstance.os_version).";
                  };
                };
              }
            );
          };
        };
      };

      config = mkIf cfg.enable {
        environment.systemPackages = [ cfg.package ];

        networking.firewall = mkIf cfg.openFirewall {
          allowedTCPPorts = [ cfg.apiServer.port ];
        };

        systemd.services.garm = {
          description = "GitHub Actions Runner Manager (garm)";
          documentation = [ "https://github.com/cloudbase/garm" ];
          after = [ "network.target" ];
          wantedBy = [ "multi-user.target" ];

          serviceConfig = {
            Type = "simple";

            # Render the runtime config (with secrets injected) before the
            # daemon starts. Runs as the same DynamicUser with the
            # StateDirectory + credentials already available.
            ExecStartPre = lib.getExe renderScript;
            ExecStart = lib.escapeShellArgs [
              (lib.getExe cfg.package)
              "-config"
              renderedConfig
            ];
            # GARM uses SIGHUP only to rotate its log file; a full reload still
            # means a restart. Mirror contrib/garm.service's ExecReload intent.
            ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
            Restart = "always";
            RestartSec = "5s";

            # Durable state: systemd creates + owns /var/lib/garm for the
            # DynamicUser and exposes it as %S/garm. The SQLite db_file lives
            # here; its parent must exist before the daemon validates config
            # (StateDirectory guarantees this).
            DynamicUser = true;
            StateDirectory = "garm";
            StateDirectoryMode = "0700";
            WorkingDirectory = stateDir;

            # Stage operator-supplied secrets (if any) into the per-service
            # credentials store (%d = $CREDENTIALS_DIRECTORY), readable by the
            # sandboxed DynamicUser under ProtectSystem=strict.
            LoadCredential =
              lib.optional (
                cfg.jwtSecretFile != null
              ) "${cfg.jwtSecretCredentialName}:${toString cfg.jwtSecretFile}"
              ++ lib.optional (
                cfg.dbPassphraseFile != null
              ) "${cfg.dbPassphraseCredentialName}:${toString cfg.dbPassphraseFile}";

            # Hardening — mirror the posture of the mcl-repro-binary-cache unit,
            # a superset of the minimal upstream contrib/garm.service.
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
            # GARM is a pure-Go/cgo-sqlite binary; W^X is fine.
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
