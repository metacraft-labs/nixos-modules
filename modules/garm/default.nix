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
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system ({ config, ... }: config.packages.garm);

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
      # It holds NO secrets — only the virsh/qemu-img/vm-harness binary paths,
      # the libvirt URI/network, the OVMF firmware paths, the per-VM sizing, and
      # the golden-image map — so it is safe in the Nix store. Passed to the
      # provider verbatim via GARM_PROVIDER_CONFIG_FILE. These keys match
      # garm-provider-vmharness/internal/config.Config (M4): the provider CoW
      # clones the golden with qemu-img and boots a Windows-11 UEFI/OVMF domain,
      # so uefi_loader/uefi_nvram_template + memory_mb/vcpus are required for a
      # real (non-mock) boot.
      # (Same writeText-precedence caveat as configTemplate below: build the
      # STRING first, then wrap — otherwise the [images.*] blocks would be
      # appended to the derivation's store PATH instead of its content.)
      vmhIsIncus = vmh.backend == "incus";
      # Libvirt keys: virsh/qemu-img/OVMF/pool-dir/sizing. Emitted for the
      # libvirt backend (the Windows VM path).
      vmharnessLibvirtKeys = ''
        virsh_path = "${vmh.virshPath}"
        qemu_img_path = "${vmh.qemuImgPath}"
        vm_harness_path = "${vmh.vmHarnessPath}"
        libvirt_uri = "${vmh.libvirtURI}"
        network = "${vmh.network}"
        pool_dir = "${vmh.poolDir}"
        uefi_loader = "${vmh.uefiLoader}"
        uefi_nvram_template = "${vmh.uefiNvramTemplate}"
        memory_mb = ${toString vmh.memoryMb}
        vcpus = ${toString vmh.vcpus}
      '';
      # Incus keys: the incus binary + bridge + the static-IPv4 injection
      # parameters (incusbr0 DHCP does not lease). Emitted for the incus
      # backend (the Linux container path, IM3/IM4).
      vmharnessIncusKeys = ''
        incus_path = "${vmh.incusPath}"
        incus_bridge = "${vmh.incusBridge}"
        incus_ipv4_cidr = "${vmh.incusIPv4CIDR}"
        incus_ipv4_gateway = "${vmh.incusIPv4Gateway}"
        incus_ipv4_range_start = "${vmh.incusIPv4RangeStart}"
        incus_ipv4_range_end = "${vmh.incusIPv4RangeEnd}"
        incus_nameservers = [${lib.concatMapStringsSep ", " (s: "\"${s}\"") vmh.incusNameservers}]
      '';
      vmharnessConfigText = ''
        backend = "${vmh.backend}"
      ''
      + (if vmhIsIncus then vmharnessIncusKeys else vmharnessLibvirtKeys)
      + lib.concatStrings (
        lib.mapAttrsToList (image: spec: ''

          [images."${image}"]
          source_image = "${spec.sourceImage}"
          os_name = "${spec.osName}"
          os_version = "${spec.osVersion}"
        '') vmh.images
      );
      vmharnessConfigFile = pkgs.writeText "garm-provider-vmharness.toml" vmharnessConfigText;

      # The `[[provider]]` block appended to garm's config when the vmharness
      # provider is enabled. External-provider keys per config/external.go:
      # provider_executable / config_file / interface_version.
      vmharnessProviderBlock = optionalString vmh.enable ''

        [[provider]]
        name = "${vmh.name}"
        provider_type = "external"
        description = "${
          if vmhIsIncus then
            "incus Linux container ephemeral runners via vm-harness"
          else
            "libvirt/KVM Windows ephemeral runners via vm-harness"
        }"

          [provider.external]
          provider_executable = "${lib.getExe vmh.package}"
          config_file = "${vmharnessConfigFile}"
          interface_version = "v0.1.1"
          # GARM does NOT propagate its own environment to external providers,
          # so the provider inherits only the vars listed here.
          #   * PATH  — libvirt: the provider shells to genisoimage (config-drive)
          #     via LookPath (virsh/qemu-img are absolute); incus: incus_path is
          #     absolute but PATH still carries the incus client for robustness.
          #   * HOME  — incus ONLY: the `incus` CLI reads $HOME/.config/incus/…;
          #     without HOME (and with ProtectHome hiding /root) it errors
          #     "Unable to read the configuration file … permission denied". The
          #     unit's HOME is the garm StateDirectory (writable), so forward it.
          environment_variables = [${if vmhIsIncus then "\"PATH\", \"HOME\"" else "\"PATH\""}]
      '';

      # M6 forge wiring: the GitHub App credentials, declared in config.toml as
      # a `[[github]]` block. The App PEM never enters the store:
      # private_key_path points at the render-time @APP_PEM_PATH@ sentinel, which
      # the ExecStartPre hook rewrites to a stable 0600 copy under stateDir of
      # the LoadCredential-staged secret.
      #
      # GARM CONSTRAINT: config `[[github]]` creds are imported into the DB only
      # by the legacy one-shot migrateCredentialsToDB (cmd/garm/main.go:
      # cfg.Database.MigrateCredentials = cfg.Github), and ONLY on the first DB
      # open AND only if an admin user already exists then. GARM's first-run
      # creates the admin via the API after boot, so on a FRESH deploy the import
      # is skipped ("Admin user doesn't exist. This is a new deploy."). This
      # block is thus effective for UPGRADING a pre-existing single-user GARM;
      # for a greenfield install register the creds once via
      # `garm-cli github credentials add --private-key-path <stateDir>/app-key.pem`
      # using this module's appId/installationId + the module-staged PEM (see
      # modules/garm/README.md §3). Every input stays declarative; only the final
      # garm-cli call is a runtime step, like org/scale-set creation.
      githubBlock = optionalString cfg.github.enable ''

        [[github]]
        name = "${cfg.github.credentialsName}"
        description = "Metacraft Labs GitHub App (ephemeral runners)"
        auth_type = "app"

          [github.app]
          app_id = ${toString cfg.github.appId}
          installation_id = ${toString cfg.github.installationId}
          private_key_path = "@APP_PEM_PATH@"
      '';

      # M6 controller URLs. GARM's guest-facing metadata/callback base URLs must
      # be reachable BY THE GUEST — on the libvirt NAT network that is the host's
      # bridge IP (virbr0 = 192.168.122.1), NOT localhost. cloudbase-init in the
      # runner VM fetches its JIT config from metadataURL and the runner reports
      # status to callbackURL. Empty ⇒ omitted (keeps the forge-less M0 boot,
      # which the boot gate asserts stops at the urls_required middleware).
      controllerURLLines =
        optionalString (cfg.metadataURL != "") ''metadata_url = "${cfg.metadataURL}"''
        + optionalString (cfg.callbackURL != "") "\ncallback_url = \"${cfg.callbackURL}\"";

      # The config template written to the Nix store. Secret fields carry
      # sentinel tokens that the ExecStartPre hook replaces with real secrets
      # from files (never present in the store). Everything else is fully
      # resolved from the module options.
      #
      # Section order follows config/config.go: [default], [logging],
      # [metrics], [jwt_auth], [apiserver], [database], then optional
      # [[provider]] (M1) and [[github]] (M6). With no provider/forge configured
      # this reduces to the forge-less M0 boot.
      #
      # NOTE the parenthesisation: function application binds tighter than `+`,
      # so `writeText "n" ''…'' + provider + github` would coerce the derivation
      # to its store PATH and append the TOML blocks to that path string — the
      # blocks would leak into any `"${configTemplate}"` interpolation. The
      # concatenation must therefore happen on the STRING first, then be wrapped
      # by writeText. (M0's provider/github blocks were always empty so the bug
      # lay dormant until M6 turned them on.)
      configTemplateText = ''
        [default]
        ${controllerURLLines}

        [logging]
        log_level = "${cfg.logLevel}"
        log_format = "text"

        [metrics]
        enable = ${lib.boolToString cfg.metrics.enable}
        disable_auth = ${lib.boolToString cfg.metrics.disableAuth}
        period = "${cfg.metrics.period}"

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
      + vmharnessProviderBlock
      # M6: optionally append the GitHub App forge credentials.
      + githubBlock;

      configTemplate = pkgs.writeText "garm-config.toml.tmpl" configTemplateText;

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

          # M6 App PEM. The GitHub App private key is a MULTI-LINE PEM, so it
          # cannot be substituted inline into config.toml — instead config.toml's
          # private_key_path must point at an on-disk file. LoadCredential mounts
          # it read-only at $CREDENTIALS_DIRECTORY/<name> for the duration of the
          # unit, but that tmpfs path is not guaranteed stable across the render
          # → daemon boundary, and GARM re-reads the key when it re-authenticates.
          # So copy it to a STABLE path under stateDir (mode 0600, owned by the
          # service user, outside the world-readable store) and point GARM there.
          app_pem_path=""
          ${optionalString cfg.github.enable ''
            if [ -n "$cred_dir" ] && [ -f "$cred_dir/${cfg.appKeyCredentialName}" ]; then
              app_pem_path="$state_dir/app-key.pem"
              umask 077
              install -m 0600 /dev/null "$app_pem_path"
              cat "$cred_dir/${cfg.appKeyCredentialName}" > "$app_pem_path"
            else
              echo "garm-render-config: services.garm.github.enable is set but the App key credential '${cfg.appKeyCredentialName}' was not staged (set services.garm.github.appKeyFile)" >&2
              exit 1
            fi
          ''}

          umask 077
          tmp="$(mktemp "${renderedConfig}.XXXXXX")"
          sed \
            -e "s|@DB_PASSPHRASE@|$db_passphrase|" \
            -e "s|@JWT_SECRET@|$jwt_secret|" \
            -e "s|@APP_PEM_PATH@|$app_pem_path|" \
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
              Only meaningful when `metrics.enable` is true. GARM serves
              `/metrics` on the SAME apiserver port; `disable_auth = true` makes
              it scrapeable without a JWT metrics-token. Keep this endpoint on a
              trusted/overlay interface (see `apiServer.bind`) — it exposes
              operational telemetry, not secrets, but should not face the
              public internet.
            '';
          };
          period = mkOption {
            type = types.str;
            default = "60s";
            description = ''
              Snapshot-metrics refresh interval (`[metrics].period`, a Go
              duration). GARM recomputes pool/instance/entity/job gauges on this
              tick. 60s matches GARM's default.
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

        # IM4 declarative egress/DHCP option. The IM3 gate opened the
        # container->host GARM path with a runtime `nft insert` rule it removed
        # on exit; this promotes that to a declarative host-firewall option.
        openIncusBridgeFirewall = mkOption {
          type = types.bool;
          default = false;
          description = ''
            When the incus backend is used, trust the incus bridge
            (`providers.vmharness.incusBridge`) for the GARM API/metadata/
            callback port, so per-job CONTAINERS can reach the host GARM
            endpoint. Wires
            `networking.firewall.interfaces.<bridge>.allowedTCPPorts =
            [ apiServer.port ]` — the declarative replacement for the runtime
            `nft` rule the IM3 gate inserted.

            This ONLY opens the container->host GARM path, and ONLY on the
            bridge interface (never the public firewall). Container->internet
            EGRESS needs NO host change: incus's own `inet incus` nftables table
            already NATs + forwards `incusbr0`. incusbr0 DHCP does not lease on
            this host, so the provider injects a static IPv4 per container (see
            `providers.vmharness.incusIPv4*`); no declarative DHCP is required.
          '';
        };

        # M6: the guest-facing controller URLs. GARM hands these to the runner
        # VM via the config-drive; the guest fetches its JIT config from
        # metadataURL and reports status to callbackURL. They MUST be reachable
        # from the guest — on the libvirt NAT network that is the host bridge IP
        # (virbr0 = 192.168.122.1), never localhost. Empty (default) keeps the
        # forge-less M0 boot (the boot gate asserts the urls_required middleware
        # fires when these are unset).
        metadataURL = mkOption {
          type = types.str;
          default = "";
          example = "http://192.168.122.1:9997/api/v1/metadata";
          description = ''
            `[default].metadata_url` — the base URL the runner VM fetches its
            JIT/instance metadata from. Must be guest-reachable (the host bridge
            IP on the libvirt network, not localhost).
          '';
        };
        callbackURL = mkOption {
          type = types.str;
          default = "";
          example = "http://192.168.122.1:9997/api/v1/callbacks";
          description = ''
            `[default].callback_url` — the base URL the runner VM posts status
            reports back to. Must be guest-reachable (see `metadataURL`).
          '';
        };

        # M6: run GARM as a dedicated system user (default) instead of a
        # DynamicUser. The libvirt provider needs the `garm` user to be in the
        # libvirtd/kvm groups and to own persistent VM-pool artifacts, which a
        # DynamicUser (fresh uid each boot) cannot do — see the config block for
        # the full rationale. Overridable for hosts with a different convention.
        user = mkOption {
          type = types.str;
          default = "garm";
          description = "System user the garm daemon runs as (created by the module).";
        };
        group = mkOption {
          type = types.str;
          default = "garm";
          description = "Primary group for the garm daemon user (created by the module).";
        };

        # M6: extra supplementary groups for the service user. When the vmharness
        # provider is enabled the daemon must reach the qemu:///system libvirt
        # socket and /dev/kvm, which are group-gated (libvirtd/kvm). The config
        # block adds these automatically when the provider is on; this option
        # lets a host add more (e.g. a storage group for the pool dir).
        extraGroups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional supplementary groups for the garm service user.";
        };

        # Ephemeral-Windows-Runners-GARM M6 — the GitHub App forge credentials,
        # wired DECLARATIVELY. OPT-IN (enable default off) so M0/M5 boots are
        # unaffected. When enabled a `[[github]]` block with auth_type=app is
        # emitted; GARM imports it into its DB on first boot. The App PEM is
        # supplied via LoadCredential (agenix at runtime) and NEVER enters the
        # store. Orgs + scale sets remain runtime/DB state (provisioned via
        # garm-cli or the reconcile activation), since they carry GitHub-side
        # state — only the credentials are declarative here.
        github = {
          enable = mkEnableOption "declarative GitHub App forge credentials (imported into GARM's DB on boot)";

          credentialsName = mkOption {
            type = types.str;
            default = "mcl-app";
            description = ''
              The `[[github]].name` — the credential name an org/scale set
              references (`garm-cli organization add --credentials <name>`).
            '';
          };

          appId = mkOption {
            type = types.ints.positive;
            example = 3115338;
            description = "GitHub App ID (`[github.app].app_id`).";
          };

          installationId = mkOption {
            type = types.ints.positive;
            example = 117072647;
            description = "GitHub App installation ID (`[github.app].installation_id`).";
          };

          appKeyFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            example = "/run/agenix/github-runners/mcl-app-key";
            description = ''
              Path to the GitHub App private-key PEM, staged via LoadCredential
              (agenix-managed on the real host) so it is NOT world-readable and
              NEVER enters the Nix store. At render time it is copied to a
              stable 0600 path under `stateDir` and `private_key_path` points
              there. Required when `github.enable` is true.
            '';
          };
        };

        # M6: declared HOST RESOURCE BUDGET for the eval-time autoscale guard.
        # The M5 guard was harness-only (a runtime check in the gate script);
        # M6 promotes it to a module assertion so a bad config fails to EVAL,
        # long before anything boots. See the assertion in `config`.
        hostBudget = {
          memoryMb = mkOption {
            type = types.ints.positive;
            default = 65536;
            description = ''
              Total guest RAM (MiB) the host is willing to commit to ephemeral
              runner VMs. The assertion requires
              `maxRunners * providers.vmharness.memoryMb <= hostBudget.memoryMb`
              across all scale sets so autoscale can never over-commit RAM.
            '';
          };
          vcpus = mkOption {
            type = types.ints.positive;
            default = 32;
            description = ''
              Total guest vCPUs the host is willing to commit. The assertion
              requires `maxRunners * providers.vmharness.vcpus <=
              hostBudget.vcpus` across all scale sets.
            '';
          };
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
        appKeyCredentialName = mkOption {
          type = types.str;
          default = "app-key";
          internal = true;
          visible = false;
          description = "LoadCredential name for the GitHub App PEM file.";
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
            type = types.enum [
              "libvirt"
              "incus"
            ];
            default = "libvirt";
            description = ''
              vm-harness backend the provider drives. `libvirt` boots per-job
              Windows-11 VMs from a golden qcow2 (the Ephemeral-Windows-Runners
              path); `incus` launches per-job Linux SYSTEM CONTAINERS from a
              runner image (the Ephemeral-Linux-Runners path, IM3/IM4). The
              backend also selects the systemd sandbox posture (see the config
              block): `incus` needs only `incus-admin` socket-group access and
              no /dev/kvm, so it keeps the STRICT M0 knobs (PrivateDevices,
              MemoryDenyWriteExecute, the syscall filter, ProtectSystem=strict),
              whereas `libvirt` relaxes them for qemu.
            '';
          };

          virshPath = mkOption {
            type = types.str;
            default = "${pkgs.libvirt}/bin/virsh";
            defaultText = lib.literalMD "`\${pkgs.libvirt}/bin/virsh`";
            description = "Path to the `virsh` binary the provider shells to.";
          };

          qemuImgPath = mkOption {
            type = types.str;
            default = "${pkgs.qemu}/bin/qemu-img";
            defaultText = lib.literalMD "`\${pkgs.qemu}/bin/qemu-img`";
            description = ''
              Path to the `qemu-img` binary the provider uses to create the
              per-job CoW overlay over the golden (`qemu-img create -b`).
            '';
          };

          uefiLoader = mkOption {
            type = types.str;
            default = "/run/libvirt/nix-ovmf/edk2-x86_64-code.fd";
            description = ''
              OVMF read-only code firmware for the per-job Windows-11 domain
              (`uefi_loader`). Windows 11 requires UEFI+SMM; the provider boots
              the proven OVMF domain (M4). On NixOS with libvirtd this is the
              symlink farm under /run/libvirt/nix-ovmf.
            '';
          };

          uefiNvramTemplate = mkOption {
            type = types.str;
            default = "/run/libvirt/nix-ovmf/edk2-i386-vars.fd";
            description = ''
              OVMF vars template copied into a per-job writable nvram file
              (`uefi_nvram_template`).
            '';
          };

          memoryMb = mkOption {
            type = types.ints.positive;
            default = 4096;
            description = ''
              Per-job guest RAM (MiB), emitted as `memory_mb`. Also an input to
              the M6 eval-time resource-guard assertion
              (`maxRunners * memoryMb <= hostBudget.memoryMb`).
            '';
          };

          vcpus = mkOption {
            type = types.ints.positive;
            default = 4;
            description = ''
              Per-job guest vCPUs, emitted as `vcpus`. Also an input to the M6
              resource-guard assertion.
            '';
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

          # ---- Incus backend (IM3/IM4) ------------------------------------
          # Consumed only when backend = "incus". These populate the provider
          # config.toml's incus_* keys (see garm-provider-vmharness config.go).
          # For the incus path a golden image's sourceImage is an incus IMAGE
          # ALIAS (eg "vmh-linux-runner"), not a qcow2 path.
          incusPath = mkOption {
            type = types.str;
            default = "${pkgs.incus}/bin/incus";
            defaultText = lib.literalMD "`\${pkgs.incus}/bin/incus`";
            description = ''
              Path to the `incus` client binary the provider shells to (the
              incus backend). GARM runs as the `garm` user in the `incus-admin`
              group (see the sandbox posture), which can reach the incus daemon
              socket directly, so an absolute path is used.
            '';
          };

          incusBridge = mkOption {
            type = types.str;
            default = "incusbr0";
            description = ''
              The managed incus bridge the per-job containers attach to (their
              eth0). Also the interface trusted for the GARM callback/metadata
              port when `services.garm.openIncusBridgeFirewall` is set.
            '';
          };

          incusIPv4CIDR = mkOption {
            type = types.str;
            default = "";
            example = "10.157.159.0/24";
            description = ''
              The incus bridge subnet in a.b.c.d/nn form. The provider injects a
              STATIC IPv4 into each container via cloud-init.network-config
              because incusbr0's DHCP does not lease on this host (nixos-fw drops
              the DHCP path). Required when backend = "incus". Egress itself
              works through incus's own NAT (no host firewall change); only the
              lease is worked around.
            '';
          };
          incusIPv4Gateway = mkOption {
            type = types.str;
            default = "";
            example = "10.157.159.1";
            description = ''
              The default route for per-job containers (the incus bridge host
              IP). This is ALSO the host IP the guest reaches GARM's
              metadata/callback endpoint on. Required when backend = "incus".
            '';
          };
          incusIPv4RangeStart = mkOption {
            type = types.str;
            default = "";
            example = "10.157.159.200";
            description = ''
              Lower bound (inclusive, dotted) of the static-IPv4 pool the
              provider allocates per container. Empty ⇒ the provider defaults to
              the .200 host of the /24.
            '';
          };
          incusIPv4RangeEnd = mkOption {
            type = types.str;
            default = "";
            example = "10.157.159.250";
            description = ''
              Upper bound (inclusive, dotted) of the static-IPv4 pool. Empty ⇒
              the provider defaults to the .250 host of the /24. The size of this
              range is the true per-scale-set concurrency ceiling for the incus
              backend (one free IP per concurrent container), so keep it >=
              maxRunners across all incus scale sets.
            '';
          };
          incusNameservers = mkOption {
            type = types.listOf types.str;
            default = [
              "1.1.1.1"
              "8.8.8.8"
            ];
            description = "Resolvers written into each container's netplan.";
          };

          poolDir = mkOption {
            type = types.str;
            default = "/var/lib/garm/pool";
            description = ''
              Directory where the provider writes per-job artifacts (the CoW
              overlay + the M3 cloudbase-init config-drive ISO + the OVMF nvram).
              When empty the provider skips config-drive injection.

              M6 NOTE: the provider runs as the non-root `garm` user, so this dir
              must be WRITABLE by that user. The module provisions it via
              systemd-tmpfiles owned `garm:libvirtd` (0771). The default is a
              garm-owned path rather than the shared `/var/lib/libvirt/images`
              (which is root-only 0711) so the default works out of the box.
              qemu runs the domains as root on a stock NixOS libvirtd host, so it
              can still read the overlays regardless. If you override this to a
              shared pool, grant the `garm` user write access there yourself.
            '';
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
                    description = ''
                      Golden qcow2/volume the per-job domain is cloned from.

                      M6 NOTE: the provider (running as the non-root `garm` user)
                      opens this as the qemu-img CoW backing file, so the golden
                      AND every parent directory must be READABLE + TRAVERSABLE by
                      the `garm` user. If the golden lives under a group-gated
                      path (e.g. `/storage/...` owned `root:some-group 0770`),
                      grant access with a POSIX ACL
                      (`setfacl -m u:garm:--x /storage; setfacl -m u:garm:r-x
                      <dir>; setfacl -m u:garm:r <golden>`) or add `garm` to the
                      owning group via `services.garm.extraGroups`. The M4/M5
                      harnesses masked this by running qemu-img as root.
                    '';
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

        # Ephemeral-Windows-Runners-GARM M5 — autoscale tuning for scale sets.
        #
        # GARM scale sets are NOT part of garm's `config.toml`: GitHub owns the
        # scheduling and each scale set carries GitHub-side state (a message
        # queue subscription, a numeric id), so they are provisioned at runtime
        # via `garm-cli scaleset add/update` against a live, App-authenticated
        # org (see references/garm/doc/scale-sets.md). This option therefore
        # captures the DECLARATIVE tuning shape — the M5 autoscale knobs — so a
        # host config records its intended concurrency policy in one place; an
        # operator (or a future reconcile activation) applies it with the CLI.
        #
        # The knobs map 1:1 onto GARM's reconcilers (validated against the
        # libvirt provider by checks/t_ephemeral_runner_autoscale.sh):
        #   * maxRunners        -> the hard CONCURRENCY CAP: GARM never runs more
        #                          than this many VMs for the scale set at once;
        #                          excess queued jobs wait for a slot.
        #   * minIdleRunners    -> the WARM POOL size: GARM keeps this many
        #                          pre-booted idle runners (ensureMinIdleRunners)
        #                          to hide Windows cold-boot latency, and refills
        #                          after each consumption. 0 == SCALE-TO-ZERO
        #                          (on-demand only; nothing runs when idle).
        #   * runnerBootstrapTimeout -> minutes before a runner that never joined
        #                          GitHub is considered failed and replaced.
        #   * labels            -> optional extra labels for `runs-on` matching
        #                          (the scale-set NAME is the primary selector;
        #                          labels are immutable after creation).
        #
        # RESOURCE GUARD: each Windows-11 VM is heavy (provider memory_mb + vcpus,
        # see providers.vmharness). The worst-case committed guest RAM is
        # `maxRunners * memory_mb`; set maxRunners to what the host's (RAM, vCPU)
        # headroom allows so autoscale can never OOM the host. The autoscale gate
        # enforces exactly this bound before booting anything.
        scaleSets = mkOption {
          default = { };
          description = ''
            Declarative autoscale tuning for GARM scale sets, keyed by scale-set
            name (the workflow `runs-on:` selector). Records the intended
            concurrency policy (concurrency cap, warm-pool size, bootstrap
            timeout, labels); applied at runtime via `garm-cli scaleset` since
            scale sets carry GitHub-side state and are not part of `config.toml`.
          '';
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  provider = mkOption {
                    type = types.str;
                    default = "vmharness";
                    description = "GARM provider name that backs this scale set.";
                  };
                  image = mkOption {
                    type = types.str;
                    default = "golden";
                    description = ''
                      Image identifier resolved against `providers.vmharness.images`
                      to pick the golden the per-job VMs clone from.
                    '';
                  };
                  osType = mkOption {
                    type = types.enum [
                      "windows"
                      "linux"
                    ];
                    default = "windows";
                    description = "Runner OS type reported to GARM/GitHub.";
                  };
                  osArch = mkOption {
                    type = types.str;
                    default = "amd64";
                    description = "Runner OS architecture.";
                  };
                  maxRunners = mkOption {
                    type = types.ints.positive;
                    default = 2;
                    description = ''
                      Concurrency CAP: the maximum number of ephemeral VMs GARM
                      runs concurrently for this scale set. The primary host
                      resource guard — keep `maxRunners * providers.vmharness
                      memory_mb` within host RAM headroom. Modest by default so
                      autoscale proves the mechanism without stressing the host.
                    '';
                  };
                  minIdleRunners = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = ''
                      Warm-pool size: pre-booted idle runners kept ready and
                      refilled after consumption. 0 (default) == scale-to-zero
                      (on-demand only). Must be <= maxRunners.
                    '';
                  };
                  runnerBootstrapTimeout = mkOption {
                    type = types.ints.positive;
                    default = 20;
                    description = ''
                      Minutes before a runner that has not joined GitHub is
                      considered failed and replaced (`--runner-bootstrap-timeout`).
                      Cold Windows boot + cloudbase-init + register can take
                      several minutes; keep this generous.
                    '';
                  };
                  labels = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    description = ''
                      Optional extra runner labels (immutable after creation).
                      The scale-set NAME is the primary `runs-on` selector.
                    '';
                  };
                  enabled = mkOption {
                    type = types.bool;
                    default = true;
                    description = "Whether the scale set is enabled.";
                  };
                  scaleSetName = mkOption {
                    type = types.str;
                    default = name;
                    defaultText = lib.literalMD "the attribute name";
                    description = "The scale-set name (defaults to the attribute name).";
                  };
                };
              }
            )
          );
        };
      };

      config = mkIf cfg.enable (
        let
          # THE M6 CENTERPIECE — provider-conditional sandbox posture.
          #
          # M0's forge-less boot ran GARM under a DynamicUser with a MAXIMAL
          # sandbox (ProtectSystem=strict, PrivateDevices, DeviceAllow=[] via
          # CapabilityBoundingSet, restricted syscalls). That is perfect for a
          # pure-Go API daemon but FATAL for the libvirt provider: the provider
          # (a child GARM execs) needs the qemu:///system libvirt socket, a real
          # PATH to genisoimage, write access to the VM pool dir, and — because
          # libvirt/qemu ultimately touch /dev/kvm through the socket, and the
          # provider itself shells virsh/qemu-img — a NON-ephemeral uid that is a
          # member of the libvirtd/kvm groups. A DynamicUser gets a fresh uid on
          # every boot and cannot be a stable group member, and PrivateDevices +
          # DeviceAllow=[] + the strict syscall filter block device/socket work.
          #
          # So the posture is CONDITIONAL on (provider on/off) AND (backend):
          #   * provider OFF (M0/boot-gate): unchanged — DynamicUser + full
          #     sandbox. The M0 boot gate keeps passing byte-for-byte.
          #   * LIBVIRT provider ON: a dedicated `garm` system user in
          #     libvirtd+kvm, with the qemu relaxations enumerated below
          #     (ProtectSystem=full, DeviceAllow=/dev/kvm, no PrivateDevices/
          #     MDWE/syscall-filter). Everything else stays on.
          #   * INCUS provider ON (IM4): a dedicated `garm` system user in
          #     `incus-admin` ONLY. Containers need no /dev/kvm, no writable host
          #     pool dir, and no syscall relaxations — the `incus` CLI just talks
          #     to the daemon over the incus-admin unix socket (connect() works
          #     on a read-only FS). So the incus posture keeps the STRICT M0
          #     knobs (PrivateDevices, MemoryDenyWriteExecute, ProtectSystem=
          #     strict, the @system-service syscall filter) and relaxes ONLY the
          #     user/group (a stable uid is required for persistent incus-admin
          #     membership; a DynamicUser cannot be a stable group member).
          providerOn = cfg.providers.vmharness.enable;
          # The libvirt (Windows VM) provider is the one that forces the qemu
          # relaxations; the incus (Linux container) provider does not.
          providerIsIncus = cfg.providers.vmharness.backend == "incus";
          libvirtProviderOn = providerOn && !providerIsIncus;

          # LoadCredential list: the two M0 secrets (optional) + the M6 App PEM
          # (required when github.enable). All staged read-only under
          # $CREDENTIALS_DIRECTORY; never in the store.
          loadCredential =
            lib.optional (
              cfg.jwtSecretFile != null
            ) "${cfg.jwtSecretCredentialName}:${toString cfg.jwtSecretFile}"
            ++ lib.optional (
              cfg.dbPassphraseFile != null
            ) "${cfg.dbPassphraseCredentialName}:${toString cfg.dbPassphraseFile}"
            ++ lib.optional (
              cfg.github.enable && cfg.github.appKeyFile != null
            ) "${cfg.appKeyCredentialName}:${toString cfg.github.appKeyFile}";

          # The hardened-but-libvirt-capable serviceConfig fragment (libvirt
          # provider ON — the Windows VM path).
          libvirtServiceConfig = {
            # Dedicated system user (created below), in libvirtd+kvm so it can
            # reach qemu:///system + /dev/kvm.
            User = cfg.user;
            Group = cfg.group;
            SupplementaryGroups = [
              "libvirtd"
              "kvm"
            ]
            ++ cfg.extraGroups;

            # RELAXATION 1: ProtectSystem=full (not strict). strict makes ALL of
            # /usr,/boot,/etc read-only AND the whole rest of the FS read-only
            # except explicit ReadWritePaths; the provider writes per-job overlay
            # + nvram + config-drive into the pool dir (typically under /var or
            # /storage) and talks to the libvirt runtime socket under /run. `full`
            # keeps /usr,/boot,/etc read-only (the important protection) while
            # letting the provider write its pool dir (granted explicitly below).
            ProtectSystem = "full";
            # RELAXATION 2: explicit ReadWritePaths for the VM pool dir + libvirt
            # runtime. StateDirectory already grants stateDir rw.
            ReadWritePaths = [
              cfg.providers.vmharness.poolDir
              "/var/lib/libvirt"
              "/run/libvirt"
            ];

            # RELAXATION 3: NO PrivateDevices — the provider/libvirt path needs
            # device access. Instead scope it to exactly the devices needed via
            # DeviceAllow (KVM + the standard tty/null/zero/random set).
            # PrivateDevices=true would hide /dev/kvm and break qemu.
            DeviceAllow = [
              "/dev/kvm rw"
              "/dev/null rw"
              "/dev/zero rw"
              "/dev/full rw"
              "/dev/random r"
              "/dev/urandom r"
              "/dev/ptmx rw"
            ];

            # RELAXATION 4: NO SystemCallFilter in the provider posture. The
            # provider execs a chain of external VM tooling — qemu-img, virsh,
            # and cdrkit's mkisofs (config-drive) — and mkisofs in particular is
            # KILLED by SIGSYS under `@system-service` (verified on this host:
            # `mkisofs ... status=31/SYS, core dumped`). Rather than chase the
            # exact syscall a vendored tool needs (brittle across versions), the
            # filter is dropped for the provider path. The remaining isolation is
            # still strong: a dedicated non-root user, NoNewPrivileges (so no
            # setuid escalation), an EMPTY CapabilityBoundingSet/AmbientCaps,
            # device scoping to /dev/kvm, RestrictNamespaces/Realtime/SUIDSGID,
            # ProtectSystem=full, and the kernel-protect knobs — all still on.
            # (The M0 API-only posture KEEPS the strict @system-service filter.)

            # RELAXATION 5: the provider execs child processes (virsh, qemu-img,
            # mkisofs) — MemoryDenyWriteExecute breaks some of them (qemu JIT), so
            # it is dropped ONLY in the provider posture. (kept in M0 below.)
          };

          # The IM4 incus posture (incus provider ON — the Linux container
          # path). Relaxes ONLY the user/group vs M0: a dedicated `garm` user in
          # `incus-admin` so it can reach the incus daemon socket. Containers
          # need NO device access (no /dev/kvm), NO writable host FS beyond the
          # StateDirectory (the incus daemon owns all container storage), and NO
          # syscall relaxations — so PrivateDevices, MemoryDenyWriteExecute,
          # ProtectSystem=strict and the @system-service filter (added below for
          # every non-libvirt posture) ALL stay on. This is a strictly stronger
          # sandbox than the libvirt posture. The incus CLI reads
          # $HOME/.config/incus/…; HOME is the garm StateDirectory (writable), so
          # ProtectHome hiding /root does not affect it (verified on this host:
          # `incus list` runs green under exactly these knobs).
          incusServiceConfig = {
            User = cfg.user;
            Group = cfg.group;
            SupplementaryGroups = [ "incus-admin" ] ++ cfg.extraGroups;
            ProtectSystem = "strict";
            PrivateDevices = true;
            MemoryDenyWriteExecute = true;
          };

          # The strict M0 posture fragment (provider OFF) — verbatim from M0.
          m0ServiceConfig = {
            DynamicUser = true;
            ProtectSystem = "strict";
            PrivateDevices = true;
            MemoryDenyWriteExecute = true;
          };

          # Posture selector: M0 (off), incus (container), or libvirt (VM).
          postureServiceConfig =
            if !providerOn then
              m0ServiceConfig
            else if providerIsIncus then
              incusServiceConfig
            else
              libvirtServiceConfig;
        in
        {
          assertions =
            # M5 invariant: a warm pool can never exceed the concurrency cap.
            lib.mapAttrsToList (n: ss: {
              assertion = ss.minIdleRunners <= ss.maxRunners;
              message = "services.garm.scaleSets.${n}: minIdleRunners (${toString ss.minIdleRunners}) must be <= maxRunners (${toString ss.maxRunners}).";
            }) cfg.scaleSets
            # M6 resource-guard (promoted from the M5 harness to eval time): the
            # sum over all scale sets of maxRunners * per-VM RAM must fit the
            # declared host RAM budget, and likewise vCPUs. A bad config now
            # FAILS TO EVAL instead of OOM-ing the host at runtime.
            ++ [
              {
                assertion =
                  let
                    totalMb = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * cfg.providers.vmharness.memoryMb
                    ) 0 cfg.scaleSets;
                  in
                  totalMb <= cfg.hostBudget.memoryMb;
                message =
                  let
                    totalMb = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * cfg.providers.vmharness.memoryMb
                    ) 0 cfg.scaleSets;
                  in
                  "services.garm: worst-case ephemeral guest RAM (sum of maxRunners * providers.vmharness.memoryMb = ${toString totalMb} MiB) exceeds hostBudget.memoryMb (${toString cfg.hostBudget.memoryMb} MiB). Lower maxRunners/memoryMb or raise hostBudget.memoryMb.";
              }
              {
                assertion =
                  let
                    totalVcpu = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * cfg.providers.vmharness.vcpus
                    ) 0 cfg.scaleSets;
                  in
                  totalVcpu <= cfg.hostBudget.vcpus;
                message =
                  let
                    totalVcpu = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * cfg.providers.vmharness.vcpus
                    ) 0 cfg.scaleSets;
                  in
                  "services.garm: worst-case ephemeral guest vCPUs (sum of maxRunners * providers.vmharness.vcpus = ${toString totalVcpu}) exceeds hostBudget.vcpus (${toString cfg.hostBudget.vcpus}). Lower maxRunners/vcpus or raise hostBudget.vcpus.";
              }
              # M6: the declarative App forge needs its PEM.
              {
                assertion = !cfg.github.enable || cfg.github.appKeyFile != null;
                message = "services.garm.github.enable requires services.garm.github.appKeyFile (the App PEM, staged via LoadCredential).";
              }
              {
                assertion = !cfg.github.enable || (cfg.github.appId != null && cfg.github.installationId != null);
                message = "services.garm.github.enable requires github.appId and github.installationId.";
              }
              # IM4: the incus backend injects a static IPv4 per container
              # (incusbr0 DHCP does not lease), so a subnet + gateway are
              # required. This mirrors the provider's own Validate().
              {
                assertion =
                  !(providerOn && providerIsIncus)
                  || (cfg.providers.vmharness.incusIPv4CIDR != "" && cfg.providers.vmharness.incusIPv4Gateway != "");
                message = "services.garm.providers.vmharness.backend = \"incus\" requires incusIPv4CIDR and incusIPv4Gateway (incusbr0 DHCP does not lease; the provider injects a static IPv4 per container).";
              }
            ];

          environment.systemPackages = [ cfg.package ];

          networking.firewall = {
            allowedTCPPorts = mkIf cfg.openFirewall [ cfg.apiServer.port ];
            # IM4 declarative egress: trust the incus bridge for the GARM
            # API/metadata/callback port so per-job CONTAINERS can reach the host
            # GARM endpoint. This is the declarative replacement for the runtime
            # `nft insert … iifname incusbr0 … dport <port> accept` rule the IM3
            # gate added by hand. Container->internet egress needs NO host change
            # (incus's own `inet incus` nft table already NATs the bridge); only
            # this container->host GARM path needs opening, and only on the
            # bridge interface (never the public firewall).
            interfaces = mkIf (cfg.openIncusBridgeFirewall && providerIsIncus) {
              ${cfg.providers.vmharness.incusBridge}.allowedTCPPorts = [ cfg.apiServer.port ];
            };
          };

          # Dedicated system user for the provider posture. Created
          # unconditionally-when-provider-on so the socket-group membership
          # (libvirtd+kvm for the VM path; incus-admin for the container path) is
          # stable across boots (a DynamicUser cannot be a persistent group
          # member).
          users.users = mkIf providerOn {
            ${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
              description = "GARM (GitHub Actions Runner Manager) service user";
              home = stateDir;
            };
          };
          users.groups = mkIf providerOn { ${cfg.group} = { }; };

          # M6: the provider writes per-job artifacts (CoW overlay, config-drive
          # ISO, OVMF nvram) into `poolDir`. Running as the non-root `garm` user
          # (not root, as the M4/M5 harness did) means the pool dir must be
          # WRITABLE by that user — the shared /var/lib/libvirt/images is
          # root-only (0711). Provision the pool dir owned by garm:libvirtd (0771:
          # garm writes; libvirtd traverses; qemu — which runs domains as root on
          # this host — reads the overlays). If the operator points poolDir at the
          # shared libvirt images dir, they must instead grant garm write access
          # there themselves; this tmpfiles rule only manages a garm-owned dir.
          # INCUS backend: the incus daemon owns all container storage, so the
          # provider writes NO host pool dir — this rule is libvirt-only.
          systemd.tmpfiles.rules = lib.optionals libvirtProviderOn [
            "d ${cfg.providers.vmharness.poolDir} 0771 ${cfg.user} libvirtd - -"
          ];

          systemd.services.garm = {
            description = "GitHub Actions Runner Manager (garm)";
            documentation = [ "https://github.com/cloudbase/garm" ];
            after = [
              "network.target"
            ]
            ++ lib.optional libvirtProviderOn "libvirtd.service"
            ++ lib.optional (providerOn && providerIsIncus) "incus.service";
            wants =
              lib.optional libvirtProviderOn "libvirtd.service"
              ++ lib.optional (providerOn && providerIsIncus) "incus.service";
            wantedBy = [ "multi-user.target" ];

            # The provider child inherits the unit PATH (GARM forwards PATH via
            # environment_variables). `path` is merged by NixOS into the unit's
            # PATH (no override conflict) and inherited by the provider child
            # GARM execs. libvirt: cdrkit(genisoimage)+qemu+libvirt for the
            # config-drive/clone path. incus: the `incus` client (incus_path is
            # absolute, but keep it on PATH for robustness).
            path =
              lib.optionals libvirtProviderOn [
                pkgs.cdrkit
                pkgs.qemu
                pkgs.libvirt
              ]
              ++ lib.optional (providerOn && providerIsIncus) pkgs.incus;

            serviceConfig = {
              Type = "simple";

              ExecStartPre = lib.getExe renderScript;
              ExecStart = lib.escapeShellArgs [
                (lib.getExe cfg.package)
                "-config"
                renderedConfig
              ];
              ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
              Restart = "always";
              RestartSec = "5s";

              StateDirectory = "garm";
              StateDirectoryMode = "0700";
              WorkingDirectory = stateDir;

              LoadCredential = loadCredential;

              # ---- Hardening COMMON to both postures --------------------------
              # These do NOT interfere with the libvirt provider and stay on
              # everywhere (a superset of upstream contrib/garm.service).
              NoNewPrivileges = true;
              ProtectHome = true;
              PrivateTmp = true;
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
              RemoveIPC = true;
              RestrictAddressFamilies = [
                "AF_INET"
                "AF_INET6"
                "AF_UNIX"
              ];
              SystemCallArchitectures = "native";
              CapabilityBoundingSet = [ "" ];
              AmbientCapabilities = [ "" ];
              UMask = "0077";
            }
            # Posture-specific fragment: strict M0 sandbox (provider off), the
            # strict-but-incus-admin sandbox (incus provider), or the qemu
            # relaxations (libvirt provider).
            // postureServiceConfig
            # The strict @system-service syscall filter is kept for EVERY
            # posture EXCEPT the libvirt one — the libvirt path execs cdrkit's
            # mkisofs which is SIGSYS-killed under it. M0 (pure Go daemon) and
            # the incus path (Go daemon + the `incus` Go CLI) both pass it.
            // lib.optionalAttrs (!libvirtProviderOn) {
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
                "~@resources"
              ];
            };
          };
        }
      );
    };
}
