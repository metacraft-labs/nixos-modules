{ withSystem, ... }:
{
  imports = [
    ./incus-runner-host.nix
  ];

  # Ephemeral-Windows-Runners-GARM M0 — host cloudbase/garm (the GitHub Actions
  # Runner Manager control plane) as an opt-in NixOS systemd service, mirroring
  # the shape of `services.mcl-repro-binary-cache`: a package option, a
  # `config.toml` generator, a durable StateDirectory for the SQLite DB, and a
  # hardened long-running unit modelled on GARM's own `contrib/garm.service`.
  #
  # M0 scope is DELIBERATELY forge-less and provider-less: GARM boots fine with
  # empty `[[provider]]`/`[[github]]` sections (see cmd/garm/main.go — providers
  # and forges are loaded lazily and an empty set is valid). The provider is
  # wired in M1 (`garm-provider-vmharness`) and the forge/pool in M4.
  #
  # EXP-MP (Production-Runners-And-Shared-Store): the module now supports
  # MULTIPLE named providers (`services.garm.providers.<name>`, each with its own
  # backend/image/sizing) and MULTIPLE GitHub App credentials
  # (`services.garm.github.<name>`), rendered as multiple `[[provider]]` +
  # `[[github]]` blocks (GARM supports both natively). The systemd sandbox
  # posture is the UNION across the enabled providers: if ANY provider is libvirt
  # the qemu relaxations + libvirtd/kvm groups apply; if ANY is incus the
  # incus-admin group is added; when NO provider is enabled the unit is the M0
  # strict DynamicUser sandbox, byte-unchanged. This is the foundation for
  # running Windows (libvirt) + Linux (incus) from one GARM and for all orgs.
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
      # may override `providers.<name>.package`.
      defaultVmharnessPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.garm-provider-vmharness
      );

      stateDir = cfg.stateDir;
      dbFile = "${stateDir}/garm.sqlite";
      renderedConfig = "${stateDir}/config.toml";

      # The enabled provider/credential sets. Each is an attrset keyed by the
      # instance NAME (the `[[provider]].name` / `[[github]].name`). Empty
      # (default) keeps the forge-less/provider-less M0 boot intact.
      enabledProviders = lib.filterAttrs (_: p: p.enable) cfg.providers;
      enabledGithub = lib.filterAttrs (_: g: g.enable) cfg.github;

      # Shell-safe token for a name (for sentinels / filenames).
      sanitizeName = name: lib.replaceStrings [ "-" "." "/" " " ":" ] [ "_" "_" "_" "_" "_" ] name;
      # systemd LoadCredential id + on-disk staged path for a credential's PEM.
      appKeyCredName = name: "app-key-${name}";
      stagedPemPath = name: "${stateDir}/app-key-${sanitizeName name}.pem";

      # ----- Per-provider config.toml (a DIFFERENT file from garm's config) ---
      # It holds NO secrets — only the virsh/qemu-img/vm-harness binary paths,
      # the libvirt URI/network OR the incus bridge + static-IPv4 params, the
      # OVMF firmware paths, the per-VM sizing, and the golden-image map — so it
      # is safe in the Nix store. Passed to the provider verbatim via
      # GARM_PROVIDER_CONFIG_FILE. Keys match
      # garm-provider-vmharness/internal/config.Config.
      # (Build the STRING first, then wrap with writeText — otherwise the
      # [images.*] blocks would be appended to the derivation's store PATH.)
      providerIsIncus = p: p.backend == "incus";
      providerIsLibvirt = p: p.backend == "libvirt";
      providerIsVMHarnessRun =
        p:
        builtins.elem p.backend [
          "tart-linux-arm"
          "tart-macos"
          "utm-windows-arm"
          "qemu-windows-arm"
        ];
      providerIsQemuWindowsArm = p: p.backend == "qemu-windows-arm";
      providerEnvVars =
        p:
        [
          "PATH"
        ]
        ++ lib.optional (providerIsIncus p) "HOME"
        ++ lib.optionals (providerIsVMHarnessRun p) [
          "MCL_RUNNER_SHARED_NIX_STORE"
          "MCL_RUNNER_SHARED_REPRO_STORE"
          "VM_HARNESS_TART_STATE_DIR"
          "TART_HOME"
          "VM_HARNESS_UTM_STATE_DIR"
          "VM_HARNESS_QEMU_WINDOWS_ARM_STATE_DIR"
          "VMH_QEMU_WINDOWS_ARM_SWTPM_CMD"
          "VM_HARNESS_DARWIN_ASUSER_UID"
        ];
      mkLibvirtKeys = p: ''
        virsh_path = "${p.virshPath}"
        qemu_img_path = "${p.qemuImgPath}"
        vm_harness_path = "${p.vmHarnessPath}"
        libvirt_uri = "${p.libvirtURI}"
        network = "${p.network}"
        pool_dir = "${p.poolDir}"
        uefi_loader = "${p.uefiLoader}"
        uefi_nvram_template = "${p.uefiNvramTemplate}"
        memory_mb = ${toString p.memoryMb}
        vcpus = ${toString p.vcpus}
      '';
      mkIncusKeys = p: ''
        incus_path = "${p.incusPath}"
        incus_bridge = "${p.incusBridge}"
        incus_ipv4_cidr = "${p.incusIPv4CIDR}"
        incus_ipv4_gateway = "${p.incusIPv4Gateway}"
        incus_ipv4_range_start = "${p.incusIPv4RangeStart}"
        incus_ipv4_range_end = "${p.incusIPv4RangeEnd}"
        incus_nameservers = [${lib.concatMapStringsSep ", " (s: "\"${s}\"") p.incusNameservers}]
        incus_gpu_passthrough = ${lib.boolToString p.incusGpuPassthrough}
        incus_share_host_nix_store = ${lib.boolToString p.incusShareHostNixStore}
        incus_reprobuild_store = "${p.incusReprobuildStore}"
        incus_reprobuild_store_guest_path = "${p.incusReprobuildStoreGuestPath}"
        incus_security_nesting = ${lib.boolToString p.incusSecurityNesting}
        incus_nested_kvm = ${lib.boolToString p.incusNestedKvm}
      '';
      mkVMHarnessRunKeys =
        p:
        ''
          vm_harness_path = "${p.vmHarnessPath}"
          state_dir = "${p.stateDir}"
        ''
        + optionalString (p.guestMetadataURL != null) ''
          guest_metadata_url = "${p.guestMetadataURL}"
        ''
        + optionalString (p.guestCallbackURL != null) ''
          guest_callback_url = "${p.guestCallbackURL}"
        '';
      mkProviderConfigText =
        p:
        ''
          backend = "${p.backend}"
        ''
        + (
          if providerIsIncus p then
            mkIncusKeys p
          else if providerIsVMHarnessRun p then
            mkVMHarnessRunKeys p
          else
            mkLibvirtKeys p
        )
        + lib.concatStrings (
          lib.mapAttrsToList (image: spec: ''

            [images."${image}"]
            source_image = "${spec.sourceImage}"
            os_name = "${spec.osName}"
            os_version = "${spec.osVersion}"
          '') p.images
        );
      mkProviderConfigFile =
        name: p: pkgs.writeText "garm-provider-${sanitizeName name}.toml" (mkProviderConfigText p);

      # The `[[provider]]` block per enabled provider. External-provider keys per
      # config/external.go: provider_executable / config_file / interface_version.
      mkProviderBlock = name: p: ''

        [[provider]]
        name = "${name}"
        provider_type = "external"
        description = "${
          if providerIsIncus p then
            "incus Linux container ephemeral runners via vm-harness"
          else
            "libvirt/KVM Windows ephemeral runners via vm-harness"
        }"

          [provider.external]
          provider_executable = "${lib.getExe p.package}"
          config_file = "${mkProviderConfigFile name p}"
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
          environment_variables = [${lib.concatMapStringsSep ", " (v: "\"${v}\"") (providerEnvVars p)}]
      '';
      providersBlock = lib.concatStrings (lib.mapAttrsToList mkProviderBlock enabledProviders);

      # ----- The GitHub App credentials — one `[[github]]` block each ----------
      # The App PEM never enters the store: private_key_path points at a stable
      # 0600 copy under stateDir (`<stateDir>/app-key-<name>.pem`), which the
      # ExecStartPre hook stages from the LoadCredential-mounted secret. Because
      # that path is deterministic there is no sentinel — it is baked directly.
      #
      # GARM CONSTRAINT: config `[[github]]` creds are imported into the DB only
      # by the legacy one-shot migrateCredentialsToDB, and ONLY on the first DB
      # open AND only if an admin user already exists then. GARM's first-run
      # creates the admin via the API after boot, so on a FRESH deploy the import
      # is skipped. This block is thus effective for UPGRADING a pre-existing
      # single-user GARM; for a greenfield install register the creds once via
      # `garm-cli github credentials add --private-key-path <stateDir>/app-key-<name>.pem`.
      mkGithubBlock = name: g: ''

        [[github]]
        name = "${g.credentialsName}"
        description = "${g.description}"
        auth_type = "app"

          [github.app]
          app_id = ${toString g.appId}
          installation_id = ${toString g.installationId}
          private_key_path = "${stagedPemPath name}"
      '';
      githubBlock = lib.concatStrings (lib.mapAttrsToList mkGithubBlock enabledGithub);

      # M6 controller URLs. GARM's guest-facing metadata/callback base URLs must
      # be reachable BY THE GUEST — on the libvirt NAT network that is the host's
      # bridge IP (virbr0 = 192.168.122.1) / the incus bridge gateway, NOT
      # localhost. Empty ⇒ omitted (keeps the forge-less M0 boot).
      controllerURLLines =
        optionalString (cfg.metadataURL != "") ''metadata_url = "${cfg.metadataURL}"''
        + optionalString (cfg.callbackURL != "") "\ncallback_url = \"${cfg.callbackURL}\"";

      # The config template written to the Nix store. The two secret fields carry
      # sentinel tokens that the ExecStartPre hook replaces with real secrets
      # from files (never present in the store). Everything else is resolved.
      #
      # Section order follows config/config.go: [default], [logging], [metrics],
      # [jwt_auth], [apiserver], [database], then optional [[provider]] blocks
      # and [[github]] blocks. With no provider/forge configured this reduces to
      # the forge-less M0 boot.
      #
      # NOTE the parenthesisation: function application binds tighter than `+`,
      # so the concatenation must happen on the STRING first, then be wrapped by
      # writeText — otherwise the derivation is coerced to its store PATH and the
      # TOML blocks leak into any `"${configTemplate}"` interpolation.
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
      # EXP-MP: append every enabled provider's [[provider]] block. Empty (the
      # default) keeps the forge-less/provider-less M0 boot intact.
      + providersBlock
      # EXP-MP: append every enabled GitHub App credential's [[github]] block.
      + githubBlock;

      configTemplate = pkgs.writeText "garm-config.toml.tmpl" configTemplateText;

      # Per-credential App PEM staging (baked paths, no sentinels). Each enabled
      # credential's LoadCredential-mounted secret is copied to its stable 0600
      # path under stateDir. Failure to stage a declared credential is fatal.
      stageGithubPems = lib.concatStrings (
        lib.mapAttrsToList (name: g: ''
          if [ -n "$cred_dir" ] && [ -f "$cred_dir/${appKeyCredName name}" ]; then
            install -m 0600 /dev/null "${stagedPemPath name}"
            cat "$cred_dir/${appKeyCredName name}" > "${stagedPemPath name}"
          else
            echo "garm-render-config: services.garm.github.${name}.enable is set but the App key credential '${appKeyCredName name}' was not staged (set services.garm.github.${name}.appKeyFile)" >&2
            exit 1
          fi
        '') enabledGithub
      );

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
          # EXP-MP App PEMs. Each GitHub App private key is a MULTI-LINE PEM, so
          # it cannot be substituted inline — config.toml's private_key_path
          # points at an on-disk file. LoadCredential mounts it read-only at
          # $CREDENTIALS_DIRECTORY/<name>, but that tmpfs path is not guaranteed
          # stable across the render → daemon boundary, and GARM re-reads the key
          # when it re-authenticates. So copy each to a STABLE 0600 path under
          # stateDir (owned by the service user, outside the store).
          ${stageGithubPems}

          tmp="$(mktemp "${renderedConfig}.XXXXXX")"
          sed \
            -e "s|@DB_PASSPHRASE@|$db_passphrase|" \
            -e "s|@JWT_SECRET@|$jwt_secret|" \
            "${configTemplate}" > "$tmp"
          mv -f "$tmp" "${renderedConfig}"
        '';
      };

      # ----- Declarative reconcile (PM5, pulled forward) ----------------------
      # The reconcile reads a Nix-rendered DESIRED-STATE manifest (JSON, no
      # secrets: credential NAMES + app ids + PEM paths + org/scale-set tuning)
      # and drives `garm-cli` to converge GARM's DB onto it. The manifest is a
      # store file (safe: no secret material — the PEM PATH is not the PEM), so
      # the reconcile logic is a pure function of `garm-cli list --format json`
      # vs this manifest. Idempotent by construction (every mutation is guarded
      # by a "does it already match?" check).
      rcfg = cfg.reconcile;

      # DESIRED credentials — one per ENABLED github.<name>. `credentialsName`
      # is the GARM `[[github]].name`; `pemPath` is the module-staged 0600 copy.
      desiredCreds = lib.mapAttrsToList (name: g: {
        name = g.credentialsName;
        description = g.description;
        appId = g.appId;
        installationId = g.installationId;
        pemPath = stagedPemPath name;
      }) enabledGithub;

      # DESIRED scale sets — one per scaleSets.<name> (the GARM-side NAME is
      # `scaleSetName`, decoupled from the attr key). Each carries its org +
      # credential + provider + tuning.
      desiredScaleSets = lib.mapAttrsToList (_: ss: {
        name = ss.scaleSetName;
        org = ss.org;
        credentials = ss.credentials;
        provider = ss.provider;
        image = ss.image;
        osType = ss.osType;
        osArch = ss.osArch;
        maxRunners = ss.maxRunners;
        minIdleRunners = ss.minIdleRunners;
        runnerBootstrapTimeout = ss.runnerBootstrapTimeout;
        enabled = ss.enabled;
      }) cfg.scaleSets;

      # DESIRED orgs — the DISTINCT (org, credentials) pairs referenced by the
      # declared scale sets. Each managed org is created against its credential.
      desiredOrgs =
        let
          pairs = lib.filter (o: o.name != "") (
            map (ss: {
              name = ss.org;
              credentials = ss.credentials;
            }) desiredScaleSets
          );
        in
        lib.unique pairs;

      # Controller URLs the reconcile must set BEFORE any org/scale-set op:
      # GARM guards the `/api/v1` router with `urlsRequired` (409 until
      # metadata + callback + agent URLs are all set). Derive them from the
      # module's guest-facing URLs, falling back to the local API base so the
      # reconcile can converge even when no guest-facing URL is configured
      # (the hermetic test) — the URLs need only be non-empty to pass the gate.
      localApiBase = "http://127.0.0.1:${toString cfg.apiServer.port}";
      ctrlMetadataURL =
        if cfg.metadataURL != "" then cfg.metadataURL else "${localApiBase}/api/v1/metadata";
      ctrlCallbackURL =
        if cfg.callbackURL != "" then cfg.callbackURL else "${localApiBase}/api/v1/callbacks";
      ctrlAgentURL = "${localApiBase}/agent";

      reconcileManifest = pkgs.writeText "garm-reconcile-manifest.json" (
        builtins.toJSON {
          endpoint = {
            name = rcfg.forgeEndpoint;
            apiBaseURL = rcfg.apiBaseURL;
            baseURL = rcfg.baseURL;
            uploadURL = rcfg.uploadURL;
          };
          controllerURLs = {
            metadata = ctrlMetadataURL;
            callback = ctrlCallbackURL;
            agent = ctrlAgentURL;
          };
          credentials = desiredCreds;
          orgs = desiredOrgs;
          scaleSets = desiredScaleSets;
          pruneUnmanaged = rcfg.pruneUnmanaged;
        }
      );

      reconcileScript = pkgs.writeShellApplication {
        name = "garm-reconcile";
        runtimeInputs = [
          cfg.package
          pkgs.coreutils
          pkgs.jq
          pkgs.curl
          pkgs.openssl
        ];
        text = ''
          set -euo pipefail

          state_dir="${stateDir}"
          manifest="${reconcileManifest}"
          api_url="http://127.0.0.1:${toString cfg.apiServer.port}"
          endpoint_name="${rcfg.forgeEndpoint}"
          admin_user="${rcfg.adminUsername}"
          admin_email="${rcfg.adminEmail}"
          cred_dir="''${CREDENTIALS_DIRECTORY:-}"
          export HOME="$state_dir"

          log() { echo "garm-reconcile: $*"; }

          # ---- Admin password: operator-supplied (LoadCredential) or persisted.
          pw_persist="$state_dir/reconcile-admin-password.secret"
          # The operator-supplied password only lands in cred_dir when
          # adminPasswordFile is set (via LoadCredential), so the -f test below
          # already covers the null case — no Nix-level guard needed (a
          # `[ -n "1" ]` literal here trips shellcheck SC2157).
          if [ -n "$cred_dir" ] && [ -f "$cred_dir/reconcile-admin-password" ]; then
            admin_pw="$(head -n1 "$cred_dir/reconcile-admin-password" | tr -d '\n')"
          else
            if [ ! -f "$pw_persist" ]; then
              umask 077
              # zxcvbn score 4: long, mixed. Persisted 0600 under stateDir.
              openssl rand -base64 24 | tr -d '\n' | sed 's/$/-Grm9!/' > "$pw_persist"
            fi
            admin_pw="$(head -n1 "$pw_persist" | tr -d '\n')"
          fi

          gcli() { garm-cli --format json "$@"; }

          # ---- (0) Wait for the API + ensure first-run admin exists -----------
          for _ in $(seq 1 60); do
            if curl -fsS -o /dev/null "$api_url/api/v1/controller-info" 2>/dev/null; then break; fi
            # 409 (init/urls required) also means the server is UP.
            code="$(curl -s -o /dev/null -w '%{http_code}' "$api_url/api/v1/controller-info" || true)"
            [ "$code" = "409" ] && break
            sleep 1
          done

          # first-run is idempotent enough: 200 on fresh, 409 if already done.
          fr_code="$(curl -s -o /tmp/garm-fr.json -w '%{http_code}' \
            -X POST "$api_url/api/v1/first-run" \
            -H 'Content-Type: application/json' \
            -d "$(jq -cn --arg u "$admin_user" --arg e "$admin_email" --arg p "$admin_pw" \
                  '{username:$u,email:$e,password:$p}')" || true)"
          case "$fr_code" in
            200) log "controller first-run complete (admin '$admin_user' created)";;
            409) log "controller already initialised";;
            *)   log "WARNING: first-run returned HTTP $fr_code (continuing; assuming pre-initialised)";;
          esac

          # Log the local garm-cli profile in (needed for every garm-cli call).
          # `init` writes the profile + logs in; if a profile already exists we
          # refresh the token via `profile login`.
          if ! garm-cli profile list --format json 2>/dev/null | jq -e '.[]?|select(.name=="reconcile")' >/dev/null 2>&1; then
            garm-cli init --name reconcile --url "$api_url" \
              --username "$admin_user" --email "$admin_email" --password "$admin_pw" \
              >/dev/null 2>&1 || \
              garm-cli profile add --name reconcile --url "$api_url" \
                --username "$admin_user" --password "$admin_pw" >/dev/null 2>&1 || true
          fi
          garm-cli profile switch reconcile >/dev/null 2>&1 || true
          # `profile login` MUST be given --username: without it garm-cli drops
          # into an interactive Username: prompt, which under systemd (no TTY)
          # reads EOF and fails. The failure is swallowed by `|| true`, so the
          # stale profile token is left in place — every subsequent garm-cli
          # call then 401s (existence checks silently return empty, and the
          # first un-guarded write, `credentials add`, aborts the reconcile).
          # This only surfaced after a garm restart invalidated the token that
          # the initial `init` (which does pass --username) had minted.
          garm-cli profile login reconcile --username "$admin_user" \
            --password "$admin_pw" >/dev/null 2>&1 || true

          # ---- (0.5) Controller URLs — REQUIRED before any /api/v1 op --------
          # GARM's apiRouter is guarded by `urlsRequired` (409 until metadata +
          # callback + agent URLs are all set). Set them idempotently (only if
          # any is currently empty) so org/credential/scale-set ops are allowed.
          md_url="$(jq -r '.controllerURLs.metadata' "$manifest")"
          cb_url="$(jq -r '.controllerURLs.callback' "$manifest")"
          ag_url="$(jq -r '.controllerURLs.agent' "$manifest")"
          ctrl="$(garm-cli controller show --format json 2>/dev/null || echo '{}')"
          have_md="$(echo "$ctrl" | jq -r '.metadata_url // ""')"
          have_cb="$(echo "$ctrl" | jq -r '.callback_url // ""')"
          have_ag="$(echo "$ctrl" | jq -r '.agent_url // ""')"
          if [ -z "$have_md" ] || [ -z "$have_cb" ] || [ -z "$have_ag" ]; then
            garm-cli controller update \
              --metadata-url "$md_url" --callback-url "$cb_url" --agent-url "$ag_url" \
              >/dev/null 2>&1 || true
            log "controller URLs set (metadata/callback/agent)"
          else
            log "controller URLs already set"
          fi

          # ---- (1) Forge endpoint (only for a NON-github.com endpoint) --------
          if [ "$endpoint_name" != "github.com" ]; then
            api_base="$(jq -r '.endpoint.apiBaseURL' "$manifest")"
            base_url="$(jq -r '.endpoint.baseURL' "$manifest")"
            upload_url="$(jq -r '.endpoint.uploadURL' "$manifest")"
            [ -n "$upload_url" ] || upload_url="$api_base"
            if gcli github endpoint list | jq -e --arg n "$endpoint_name" '.[]?|select(.name==$n)' >/dev/null; then
              garm-cli github endpoint update "$endpoint_name" \
                --api-base-url "$api_base" --base-url "$base_url" --upload-url "$upload_url" \
                >/dev/null 2>&1 || true
              log "endpoint '$endpoint_name' present (updated)"
            else
              garm-cli github endpoint create --name "$endpoint_name" \
                --api-base-url "$api_base" --base-url "$base_url" --upload-url "$upload_url" \
                >/dev/null
              log "endpoint '$endpoint_name' created"
            fi
          fi

          # ---- (2) Credentials: create-missing / update-drifted ---------------
          existing_creds="$(gcli github credentials list --long 2>/dev/null || echo '[]')"
          declared_cred_names="$(jq -r '.credentials[].name' "$manifest")"
          jq -c '.credentials[]' "$manifest" | while read -r c; do
            cname="$(echo "$c" | jq -r '.name')"
            cdesc="$(echo "$c" | jq -r '.description')"
            capp="$(echo "$c" | jq -r '.appId')"
            cinst="$(echo "$c" | jq -r '.installationId')"
            cpem="$(echo "$c" | jq -r '.pemPath')"
            if echo "$existing_creds" | jq -e --arg n "$cname" '.[]?|select(.name==$n)' >/dev/null; then
              # Present — reconcile app/installation ids + description + key.
              garm-cli github credentials update --name "$cname" \
                --description "$cdesc" --app-id "$capp" \
                --app-installation-id "$cinst" --private-key-path "$cpem" \
                >/dev/null 2>&1 || true
              log "credential '$cname' present (updated app-id=$capp inst=$cinst)"
            else
              garm-cli github credentials add --name "$cname" \
                --endpoint "$endpoint_name" --auth-type app --description "$cdesc" \
                --app-id "$capp" --app-installation-id "$cinst" \
                --private-key-path "$cpem" >/dev/null
              log "credential '$cname' created (app-id=$capp inst=$cinst)"
            fi
          done

          # ---- (3) Orgs: create-missing (idempotent) --------------------------
          # org-add does NOT call GitHub; it stores the org + starts a pool mgr.
          declared_org_names="$(jq -r '.orgs[].name' "$manifest" | sort -u)"
          jq -c '.orgs[]' "$manifest" | while read -r o; do
            oname="$(echo "$o" | jq -r '.name')"
            ocreds="$(echo "$o" | jq -r '.credentials')"
            if gcli organization list --name "$oname" 2>/dev/null | jq -e --arg n "$oname" '.[]?|select(.name==$n)' >/dev/null; then
              log "org '$oname' present"
            else
              garm-cli organization add --name "$oname" --credentials "$ocreds" \
                --random-webhook-secret >/dev/null 2>&1 || \
                garm-cli organization add --name "$oname" --credentials "$ocreds" \
                  --webhook-secret "$(openssl rand -hex 16)" >/dev/null
              log "org '$oname' created (credentials=$ocreds)"
            fi
          done

          # Map org NAME -> id for scale-set operations.
          org_id_for() {
            gcli organization list --name "$1" 2>/dev/null \
              | jq -r --arg n "$1" '.[]?|select(.name==$n)|.id' | head -n1
          }

          # ---- (4) Scale sets: create-missing / update-drifted ----------------
          jq -c '.scaleSets[]' "$manifest" | while read -r s; do
            sname="$(echo "$s" | jq -r '.name')"
            sorg="$(echo "$s" | jq -r '.org')"
            sprov="$(echo "$s" | jq -r '.provider')"
            simage="$(echo "$s" | jq -r '.image')"
            sos="$(echo "$s" | jq -r '.osType')"
            sarch="$(echo "$s" | jq -r '.osArch')"
            smax="$(echo "$s" | jq -r '.maxRunners')"
            smin="$(echo "$s" | jq -r '.minIdleRunners')"
            sboot="$(echo "$s" | jq -r '.runnerBootstrapTimeout')"
            senabled="$(echo "$s" | jq -r '.enabled')"
            oid="$(org_id_for "$sorg")"
            if [ -z "$oid" ]; then
              log "WARNING: scale set '$sname' org '$sorg' has no id; skipping"
              continue
            fi
            cur="$(gcli scaleset list --org "$oid" 2>/dev/null \
              | jq -c --arg n "$sname" '.[]?|select(.name==$n)' | head -n1 || true)"
            # `--enabled` is a cobra BOOL flag: pass `--enabled=true` /
            # `--enabled=false` explicitly so a declared `enabled=false` scale
            # set actually gets DISABLED (a bare "" flag could never emit the
            # disable side, so a declared-disabled set stayed enabled forever).
            if [ "$senabled" = "true" ]; then
              enabled_flag="--enabled=true"
            else
              enabled_flag="--enabled=false"
            fi
            if [ -z "$cur" ]; then
              # shellcheck disable=SC2086
              garm-cli scaleset add --org "$oid" --provider-name "$sprov" \
                --image "$simage" --name "$sname" --flavor default $enabled_flag \
                --min-idle-runners "$smin" --max-runners "$smax" \
                --os-type "$sos" --os-arch "$sarch" \
                --runner-bootstrap-timeout "$sboot" >/dev/null
              log "scale set '$sname' created in org '$sorg' (max=$smax min=$smin)"
            else
              sid="$(echo "$cur" | jq -r '.id')"
              # Drift check: max/min/image/bootstrap/enabled.
              drift=0
              [ "$(echo "$cur" | jq -r '.max_runners // 0')" = "$smax" ] || drift=1
              [ "$(echo "$cur" | jq -r '.min_idle_runners // 0')" = "$smin" ] || drift=1
              [ "$(echo "$cur" | jq -r '.image // ""')" = "$simage" ] || drift=1
              [ "$(echo "$cur" | jq -r '.runner_bootstrap_timeout // 0')" = "$sboot" ] || drift=1
              [ "$(echo "$cur" | jq -r '.enabled // false')" = "$senabled" ] || drift=1
              if [ "$drift" = 1 ]; then
                # shellcheck disable=SC2086
                garm-cli scaleset update "$sid" --name "$sname" --image "$simage" \
                  $enabled_flag --min-idle-runners "$smin" --max-runners "$smax" \
                  --os-type "$sos" --os-arch "$sarch" \
                  --runner-bootstrap-timeout "$sboot" >/dev/null
                log "scale set '$sname' (id=$sid) drift-corrected (max=$smax min=$smin)"
              else
                log "scale set '$sname' (id=$sid) already converged"
              fi
            fi
          done

          # ---- (5) Prune (GUARDED, opt-in) ------------------------------------
          prune="$(jq -r '.pruneUnmanaged' "$manifest")"
          if [ "$prune" = "true" ]; then
            log "prune enabled — removing undeclared scale sets in MANAGED orgs"
            # Only prune within the DECLARED org set (the reconcile-managed
            # boundary). Orgs GARM knows about but that this config never
            # declares are left entirely alone.
            for oname in $declared_org_names; do
              oid="$(org_id_for "$oname")"
              [ -n "$oid" ] || continue
              # Scale sets that DO exist in this managed org but are not declared.
              declared_in_org="$(jq -r --arg o "$oname" '.scaleSets[]|select(.org==$o)|.name' "$manifest")"
              gcli scaleset list --org "$oid" 2>/dev/null | jq -c '.[]?' | while read -r ex; do
                exname="$(echo "$ex" | jq -r '.name')"
                exid="$(echo "$ex" | jq -r '.id')"
                if ! echo "$declared_in_org" | grep -qxF "$exname"; then
                  # GARM refuses to delete an ENABLED scale set
                  # (`400: scale set is enabled; disable it first`). Disable it
                  # first (best-effort — a set already disabled makes this a
                  # no-op), THEN delete. Do NOT swallow a real delete failure:
                  # surface it and fail the reconcile so a stuck prune is loud
                  # rather than being falsely logged as "pruned".
                  garm-cli scaleset update "$exid" --enabled=false >/dev/null 2>&1 || true
                  if garm-cli scaleset delete "$exid" >/dev/null; then
                    log "pruned undeclared scale set '$exname' (id=$exid) from org '$oname'"
                  else
                    log "ERROR: failed to delete undeclared scale set '$exname' (id=$exid) in org '$oname'"
                    exit 1
                  fi
                fi
              done
            done
            # Prune undeclared credentials (only those we recognise as managed —
            # here: any credential not in the declared set is pruned ONLY when
            # prune is on, and never the built-in ones GARM seeds).
            gcli github credentials list 2>/dev/null | jq -r '.[]?.name' | while read -r exc; do
              if ! echo "$declared_cred_names" | grep -qxF "$exc"; then
                garm-cli github credentials delete "$exc" >/dev/null 2>&1 \
                  && log "pruned undeclared credential '$exc'" || true
              fi
            done
          else
            log "prune disabled (default) — undeclared entries left untouched"
          fi

          log "reconcile complete"
        '';
      };

      # ----- FU9 GARM-API-WATCHDOG ------------------------------------------
      hcfg = cfg.healthcheck;
      # The probe address MUST match what garm binds and what reconcile uses:
      # loopback + the configured apiserver port. controller-info is a stable,
      # always-present route; a 200/401/409 all prove the LISTENER is bound and
      # serving (401 = auth required, 409 = init/urls required — the socket is
      # up either way). Only a connection-refused / timeout means the API died.
      healthProbeURL = "http://127.0.0.1:${toString cfg.apiServer.port}/api/v1/controller-info";

      # The ExecStartPost bind-verify: wait up to startupBindTimeout for the API
      # listener to answer, else exit non-zero so garm.service (Restart=always)
      # restarts. Catches the startup bind race directly.
      bindVerifyScript = pkgs.writeShellApplication {
        name = "garm-bind-verify";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
        ];
        text = ''
          set -euo pipefail
          url="${healthProbeURL}"
          deadline=$(( $(date +%s) + ${toString hcfg.startupBindTimeout} ))
          while :; do
            # ANY HTTP response (curl exit 0, incl. 401/409) means bound+serving.
            if curl -s -o /dev/null --max-time ${toString hcfg.probeTimeout} "$url" </dev/null; then
              echo "garm-bind-verify: API listener is up ($url)"
              exit 0
            fi
            if [ "$(date +%s)" -ge "$deadline" ]; then
              echo "garm-bind-verify: API did NOT bind within ${toString hcfg.startupBindTimeout}s ($url) — failing start so systemd restarts garm" >&2
              exit 1
            fi
            sleep 1
          done
        '';
      };

      # The periodic health-check: one probe per timer tick. Persists a
      # consecutive-failure counter + the last watchdog-restart timestamp under
      # stateDir. Restarts garm.service ONLY when the API has been refused
      # `failureThreshold` times in a row AND garm.service is active AND we have
      # not restarted within `minRestartInterval` — no false positives, no
      # storms.
      healthCheckScript = pkgs.writeShellApplication {
        name = "garm-healthcheck";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.systemd
          pkgs.gnused
        ];
        text = ''
          set -euo pipefail

          url="${healthProbeURL}"
          # The watchdog runs as root; its counter/timestamp live in ITS OWN
          # state dir (/var/lib/garm-healthcheck), NOT garm's StateDirectory.
          # Sharing garm's StateDirectory made systemd re-chown /var/lib/garm to
          # root:root on every timer run (~1/min), so garm — which runs as the
          # non-root `garm` user — lost access to its own SQLite DB and could
          # manage no runners (whole ephemeral fleet stalled).
          fail_file="/var/lib/garm-healthcheck/healthcheck-consecutive-failures"
          last_restart_file="/var/lib/garm-healthcheck/healthcheck-last-restart"
          threshold=${toString hcfg.failureThreshold}

          log() { echo "garm-healthcheck: $*"; }

          # Probe. curl exit 0 for ANY HTTP status (incl. 401/409) ⇒ the
          # listener is BOUND and serving. Non-zero (connection-refused, timeout,
          # reset) ⇒ the API is dead.
          if curl -s -o /dev/null --max-time ${toString hcfg.probeTimeout} "$url" </dev/null; then
            # Healthy: reset the consecutive-failure counter.
            if [ -f "$fail_file" ] && [ "$(cat "$fail_file" 2>/dev/null || echo 0)" != "0" ]; then
              log "API healthy again ($url) — resetting failure counter"
            fi
            printf '0' > "$fail_file"
            exit 0
          fi

          # Failed probe. Only act if garm.service is actually meant to be up:
          # a stopped/failed garm is systemd's job (Restart=always), and probing
          # a deliberately-stopped garm must not trigger a spurious "restart".
          if [ "$(systemctl is-active garm.service 2>/dev/null || true)" != "active" ]; then
            log "API probe failed but garm.service is not active — leaving to systemd (no watchdog action)"
            printf '0' > "$fail_file"
            exit 0
          fi

          fails=$(( $(cat "$fail_file" 2>/dev/null || echo 0) + 1 ))
          printf '%s' "$fails" > "$fail_file"
          log "API probe failed ($url); consecutive failures = $fails/$threshold"

          if [ "$fails" -lt "$threshold" ]; then
            exit 0
          fi

          # Threshold reached. Rate-limit: refuse to restart if we restarted
          # within minRestartInterval. `systemd-analyze timespan` normalises any
          # span to a "μs: <N>" line; convert that to whole seconds. Fall back to
          # 600s (10min) if parsing ever fails, so the rate-limit is never a
          # no-op that would let a storm through.
          now=$(date +%s)
          min_gap_us=$(systemd-analyze timespan "${hcfg.minRestartInterval}" 2>/dev/null \
            | sed -n 's/^[^0-9]*μs:[[:space:]]*\([0-9]\+\).*/\1/p' | head -n1)
          if [ -n "''${min_gap_us:-}" ]; then
            min_gap_s=$(( min_gap_us / 1000000 ))
          else
            min_gap_s=600
          fi

          if [ -f "$last_restart_file" ]; then
            last=$(cat "$last_restart_file" 2>/dev/null || echo 0)
            if [ $(( now - last )) -lt "$min_gap_s" ]; then
              log "API dead for $fails probes, but a watchdog restart happened $(( now - last ))s ago (< ''${min_gap_s}s) — RATE-LIMITED, not restarting"
              exit 0
            fi
          fi

          log "API dead for $fails consecutive probes — restarting garm.service (watchdog recovery)"
          printf '%s' "$now" > "$last_restart_file"
          # Reset the counter so post-restart probes start fresh.
          printf '0' > "$fail_file"
          systemctl restart garm.service
          log "garm.service restart issued"
        '';
      };

      # ----- The reusable provider submodule ---------------------------------
      # One named instance per `services.garm.providers.<name>`; the attr name is
      # the GARM `[[provider]].name` referenced by scale sets.
      providerModule =
        { ... }:
        {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether this provider instance is enabled (emitted as a
                `[[provider]]` block and factored into the sandbox posture).
                Defaults to true — merely declaring the instance turns it on;
                set false to keep the config but disable it.
              '';
            };

            package = mkOption {
              type = types.package;
              default = defaultVmharnessPackage;
              defaultText = lib.literalMD "this flake's `garm-provider-vmharness` package";
              description = "Package providing the `garm-provider-vmharness` binary.";
            };

            backend = mkOption {
              type = types.enum [
                "libvirt"
                "incus"
                "tart-linux-arm"
                "tart-macos"
                "utm-windows-arm"
                "qemu-windows-arm"
              ];
              default = "libvirt";
              description = ''
                vm-harness backend the provider drives. `libvirt` boots per-job
                Windows-11 VMs from a golden qcow2 (the Ephemeral-Windows-Runners
                path); `incus` launches per-job Linux SYSTEM CONTAINERS from a
                runner image (the Ephemeral-Linux-Runners path);
                `tart-linux-arm`, `tart-macos`, `utm-windows-arm`, and
                `qemu-windows-arm` shell to vm-harness's Apple-silicon backends
                for m3. The backend also
                contributes to the systemd sandbox posture UNION: `incus` needs
                only `incus-admin` socket-group access and no /dev/kvm (keeps the
                STRICT knobs), whereas `libvirt` relaxes them for qemu
                (libvirtd/kvm groups + DeviceAllow /dev/kvm + ProtectSystem=full).
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
                (`uefi_loader`). On NixOS with libvirtd this is the symlink farm
                under /run/libvirt/nix-ovmf.
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
                the eval-time resource-guard assertion
                (`maxRunners * memoryMb <= hostBudget.memoryMb`).
              '';
            };

            vcpus = mkOption {
              type = types.ints.positive;
              default = 4;
              description = ''
                Per-job guest vCPUs, emitted as `vcpus`. Also an input to the
                resource-guard assertion.
              '';
            };

            vmHarnessPath = mkOption {
              type = types.str;
              default = "vm-harness";
              description = "Path to the `vm-harness` binary used for per-job clone + config-drive injection.";
            };

            stateDir = mkOption {
              type = types.str;
              default = "/var/lib/garm-provider-vmharness";
              description = ''
                State directory used by vm-harness-run providers
                (`tart-linux-arm`, `tart-macos`, `utm-windows-arm`,
                `qemu-windows-arm`) for pid and instance metadata files.
                Contains no secrets.
              '';
            };

            guestMetadataURL = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "http://10.0.2.2:9997/api/v1/metadata";
              description = ''
                Optional provider-local override for the GARM metadata URL
                rendered into guest bootstrap scripts for vm-harness-run
                backends. Leave null to use `services.garm.metadataURL`.
              '';
            };

            guestCallbackURL = mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "http://10.0.2.2:9997/api/v1/callbacks";
              description = ''
                Optional provider-local override for the GARM callback URL
                rendered into guest bootstrap scripts for vm-harness-run
                backends. Leave null to use `services.garm.callbackURL`.
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

            # ---- Incus backend --------------------------------------------
            incusPath = mkOption {
              type = types.str;
              default = "${pkgs.incus}/bin/incus";
              defaultText = lib.literalMD "`\${pkgs.incus}/bin/incus`";
              description = ''
                Path to the `incus` client binary the provider shells to (the
                incus backend). GARM runs as the `garm` user in the `incus-admin`
                group, which can reach the incus daemon socket directly.
              '';
            };

            incusBridge = mkOption {
              type = types.str;
              default = "incusbr0";
              description = ''
                The managed incus bridge the per-job containers attach to. Also
                the interface trusted for the GARM callback/metadata port when
                `services.garm.openIncusBridgeFirewall` is set.
              '';
            };

            incusIPv4CIDR = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.0/24";
              description = ''
                The incus bridge subnet in a.b.c.d/nn form. The provider injects
                a STATIC IPv4 into each container via cloud-init.network-config
                because incusbr0's DHCP does not lease on this host. Required when
                backend = "incus".
              '';
            };
            incusIPv4Gateway = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.1";
              description = ''
                The default route for per-job containers (the incus bridge host
                IP). Also the host IP the guest reaches GARM's metadata/callback
                endpoint on. Required when backend = "incus".
              '';
            };
            incusIPv4RangeStart = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.200";
              description = ''
                Lower bound (inclusive, dotted) of the static-IPv4 pool the
                provider allocates per container. Empty ⇒ the provider defaults
                to the .200 host of the /24.
              '';
            };
            incusIPv4RangeEnd = mkOption {
              type = types.str;
              default = "";
              example = "10.0.100.250";
              description = ''
                Upper bound (inclusive, dotted) of the static-IPv4 pool. Empty ⇒
                the provider defaults to the .250 host of the /24.
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

            incusGpuPassthrough = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider attaches an NVIDIA
                GPU to every per-job container before start:
                `incus config device add <name> gpu gpu` plus
                `incus config set <name> nvidia.runtime=true`. The host must have
                `hardware.nvidia-container-toolkit.enable = true` (the CDI/runtime
                toolkit Incus uses to expose the GPU + userspace driver into the
                container). Backs a GPU runner class (`runs-on: incus-gpu`): a
                fresh container gets a GPU, runs one job, is destroyed. Ignored by
                non-incus providers.
              '';
            };

            incusShareHostNixStore = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider wires every per-job
                container into the HOST's shared `/nix/store` as a build-farm
                participant (the multi-user-Nix model: build once, cache-hit for
                every later guest/host). Before start it mounts `/nix/store`
                READ-ONLY (the guest reads prebuilt paths directly — instant
                cache hits) and the host nix-daemon socket directory
                (`/nix/var/nix/daemon-socket`) so all guest WRITES/builds go
                through the HOST daemon (`NIX_REMOTE=daemon`): a novel derivation
                built in a guest lands in the shared host store (validated +
                content-addressed by the daemon) and is a cache hit for later
                guests.

                SECURITY POSTURE (writable-by-design and SAFE): incus's default
                idmap shifts guest root to an unprivileged host uid that is NOT
                in nix `trusted-users`, so the daemon treats the guest as
                UNTRUSTED (`Trusted: 0`). An untrusted client can build + add
                CONTENT-ADDRESSED paths but CANNOT set substituters/trusted-keys
                or import unsigned NARs as trusted (those settings are ignored
                with a warning); a malicious path content-addresses to a
                different hash than anything production resolves, so it cannot
                poison the cache; and the raw store bytes are read-only from the
                guest. The residual risk is disk-DoS (a guest filling the store),
                contained by ephemeral one-job guests + store quotas. Default
                false ⇒ the container is byte-unchanged. Ignored by non-incus
                providers. Backs PM2 (Production-Runners shared nix store).
              '';
            };

            incusReprobuildStore = mkOption {
              type = types.str;
              default = "";
              example = "/var/lib/reprobuild/shared-store";
              description = ''
                When set (incus backend only), the HOST path of the reprobuild
                content-addressed store (`repro_local_store`) mounted READ-WRITE
                into every per-job container before start. The CAS is
                BLAKE3-content-addressed (hash-on-read), so writes are
                self-verifying: a guest ADDS content-addressed entries that
                PERSIST to the shared store for later guests, and CANNOT corrupt
                an existing entry (a tampered blob hashes to a different digest).
                A job resolves prebuilt artifacts locally (no HTTP round-trip) by
                pointing reprobuild at the mount (`REPRO_STORE_ROOT`). Empty ⇒ no
                reprobuild share. Ignored by non-incus providers. Backs PM3.
              '';
            };

            incusReprobuildStoreGuestPath = mkOption {
              type = types.str;
              default = "";
              example = "/srv/repro-store";
              description = ''
                In-guest mount point for the `incusReprobuildStore` share. Empty
                ⇒ mirrors the host path. Only consulted when
                `incusReprobuildStore` is set.
              '';
            };

            incusSecurityNesting = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider enables NESTED
                containerisation on every per-job container before start so an
                in-guest Docker/Podman daemon can run (the `runs-on: incus`
                nested-Docker path):
                `incus config set <name> security.nesting true` plus the two
                syscall intercepts fuse-overlayfs needs to build images
                UNPRIVILEGED —
                `security.syscalls.intercept.mknod true` (mknod device-node
                image layers) and `security.syscalls.intercept.setxattr true`
                (overlayfs `trusted.overlay.*` xattrs). `security.nesting` lets
                the guest create its own namespaces/cgroups + mount an overlay.
                The runner image must ship docker/moby + fuse-overlayfs and be
                configured for the fuse-overlayfs storage driver (an
                unprivileged nested container cannot use the kernel overlay2
                driver). Default false ⇒ the container is byte-unchanged (the
                live runners are untouched). Ignored by non-incus providers.
                Backs HR1 (Production-Runners nested Docker).
              '';
            };

            incusNestedKvm = mkOption {
              type = types.bool;
              default = false;
              description = ''
                When true (incus backend only), the provider exposes the host
                `/dev/kvm` into every per-job container and ensures
                `security.nesting=true` before start so an in-guest
                `qemu-system-* -enable-kvm` gets HARDWARE-ACCELERATED nested
                virtualisation (the `runs-on: incus` nested-VM path):
                `incus config set <name> security.nesting true` plus
                `incus config device add <name> kvm unix-char
                source=/dev/kvm path=/dev/kvm mode=0666`. The permissive mode
                is confined to the dedicated ephemeral guest so its
                unprivileged runner can use KVM. The host must itself expose
                `/dev/kvm` with nested virtualisation enabled
                (`kvm_intel.nested=Y` / `kvm_amd.nested=Y`), and the runner
                image must ship qemu/kvm. Default false ⇒ the container is
                byte-unchanged (the live runners are untouched). Ignored by
                non-incus providers. Backs HR2 (Production-Runners nested KVM).
              '';
            };

            poolDir = mkOption {
              type = types.str;
              default = "/var/lib/garm/pool";
              description = ''
                Directory where the (libvirt) provider writes per-job artifacts
                (the CoW overlay + the config-drive ISO + the OVMF nvram). The
                module provisions it via systemd-tmpfiles owned `garm:libvirtd`
                (0771). NOTE: if MULTIPLE libvirt providers are enabled, give each
                a DISTINCT poolDir. The incus backend writes NO host pool dir
                (the incus daemon owns container storage).
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
                        Golden qcow2/volume (libvirt) or incus image alias (incus)
                        the per-job instance is cloned from. For libvirt the
                        golden AND every parent directory must be READABLE +
                        TRAVERSABLE by the `garm` user.
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
        };

      # ----- The reusable GitHub App credential submodule --------------------
      githubModule =
        { name, ... }:
        {
          options = {
            enable = mkOption {
              type = types.bool;
              default = true;
              description = ''
                Whether this GitHub App credential is enabled (emitted as a
                `[[github]]` block and its PEM staged via LoadCredential).
                Defaults to true.
              '';
            };

            credentialsName = mkOption {
              type = types.str;
              default = name;
              defaultText = lib.literalMD "the attribute name";
              description = ''
                The `[[github]].name` — the credential name an org/scale set
                references (`garm-cli organization add --credentials <name>`).
                Defaults to the attribute name.
              '';
            };

            description = mkOption {
              type = types.str;
              default = "GARM GitHub App credentials (${name})";
              defaultText = lib.literalMD "`GARM GitHub App credentials (<name>)`";
              description = "Human-readable `[[github]].description`.";
            };

            appId = mkOption {
              type = types.ints.positive;
              example = 123456;
              description = "GitHub App ID (`[github.app].app_id`).";
            };

            installationId = mkOption {
              type = types.ints.positive;
              example = 7654321;
              description = "GitHub App installation ID (`[github.app].installation_id`).";
            };

            appKeyFile = mkOption {
              type = types.nullOr types.path;
              default = null;
              example = "/run/agenix/garm/github-app-key";
              description = ''
                Path to the GitHub App private-key PEM, staged via LoadCredential
                (agenix-managed on the real host) so it is NOT world-readable and
                NEVER enters the Nix store. At render time it is copied to a
                stable 0600 path under `stateDir` and `private_key_path` points
                there. Required when the credential is enabled.
              '';
            };
          };
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
            UUID on first run (stored in the DB); this is only a label.
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
            '';
          };
          disableAuth = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Serve `/metrics` without JWT auth (`[metrics].disable_auth`).
              Only meaningful when `metrics.enable` is true. Keep this endpoint
              on a trusted/overlay interface (see `apiServer.bind`).
            '';
          };
          period = mkOption {
            type = types.str;
            default = "60s";
            description = ''
              Snapshot-metrics refresh interval (`[metrics].period`, a Go
              duration). 60s matches GARM's default.
            '';
          };
        };

        # Optional operator-supplied secrets. When unset (default), the service
        # generates strong random secrets on first boot and persists them under
        # stateDir. When set, the referenced files are staged via LoadCredential
        # and used verbatim.
        jwtSecretFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          description = ''
            Optional path to a file containing the `[jwt_auth].secret`. Staged
            via systemd LoadCredential. Null (default) ⇒ a strong secret is
            generated on first boot and persisted under stateDir.
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

        # ---- FU9 GARM-API-WATCHDOG: health supervision ------------------------
        # GARM runs Type=simple + Restart=always. That only recovers a CRASH
        # (main-process exit). It does NOT recover the failure mode observed live
        # on high-mem-server: the garm PROCESS came up and its pool managers ran,
        # but the HTTP API listener on :9997 NEVER BOUND (a bind race on a fast
        # restart — the old instance's socket still held). The process stayed
        # alive, so Restart=always never fired, and systemd had no visibility
        # into the dead API → a ~3h silent outage that crash-looped
        # garm-reconcile with connection-refused to 127.0.0.1:9997.
        #
        # This adds process-independent health supervision on the SAME address
        # garm binds and reconcile probes (loopback 127.0.0.1:<apiServer.port>):
        #   * a periodic health-check (systemd service+timer) that probes
        #     GET /api/v1/controller-info — a 200/401/409 proves the listener is
        #     BOUND + serving (401 = auth required, but the socket is up); a
        #     connection-refused / timeout means the API is dead — and restarts
        #     garm.service after N CONSECUTIVE failed probes (safe: a single
        #     momentarily-busy probe never restarts), rate-limited so it can
        #     never restart-storm;
        #   * an ExecStartPost bind-verify on garm.service that waits up to
        #     `startupBindTimeout` for the API to bind and FAILS (→ Restart=always
        #     restarts garm) if it never does — catching the bind race AT
        #     STARTUP, before the periodic probe would.
        healthcheck = {
          enable =
            mkEnableOption "the GARM API health-check watchdog (auto-recover a process-alive-but-API-dead garm)"
            // {
              default = true;
              example = false;
            };

          interval = mkOption {
            type = types.str;
            default = "1min";
            description = ''
              How often the health-check probes the GARM API
              (`OnUnitActiveSec` / `OnBootSec` of the `garm-healthcheck.timer`,
              a systemd time span). One probe per interval.
            '';
          };

          failureThreshold = mkOption {
            type = types.ints.positive;
            default = 3;
            description = ''
              Number of CONSECUTIVE failed probes (connection-refused/timeout)
              before the watchdog restarts `garm.service`. A single failing
              probe (a momentarily-busy garm) never triggers a restart; the
              failure counter is persisted under `stateDir` and RESET to zero on
              the first successful probe. With the default 1min interval and a
              threshold of 3, a genuinely dead API is recovered within ~3-4min.
            '';
          };

          minRestartInterval = mkOption {
            type = types.str;
            default = "10min";
            description = ''
              Minimum wall-clock time between two watchdog-initiated restarts (a
              `systemd-analyze timestamp`-parseable span). After the watchdog
              restarts garm it will NOT restart again until this much time has
              elapsed, even if probes keep failing — so a garm that is dead for
              a deeper reason (bad config, disk full) is restarted at most once
              per window instead of storming. The restart timestamp is persisted
              under `stateDir`.
            '';
          };

          probeTimeout = mkOption {
            type = types.ints.positive;
            default = 5;
            description = ''
              Per-probe curl timeout in seconds (`curl --max-time`). A probe
              that neither connects nor responds within this window counts as a
              failure. Keep it well below `interval`.
            '';
          };

          startupBindVerify = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Add an `ExecStartPost` to `garm.service` that waits up to
              `startupBindTimeout` for the API listener to bind and FAILS the
              start (so `Restart=always` restarts garm) if it never binds within
              that window. Catches the startup bind race directly; the periodic
              health-check catches later deaths. The probe is against the local
              loopback API, so it never depends on external forge/GitHub state.
            '';
          };

          startupBindTimeout = mkOption {
            type = types.ints.positive;
            default = 30;
            description = ''
              Seconds the `ExecStartPost` bind-verify waits for the API to bind
              before failing the start (only used when `startupBindVerify` is
              true).
            '';
          };
        };

        # ---- Declarative reconcile (PM5 "declarative reconcile", pulled fwd) --
        # A post-boot systemd oneshot that makes GARM's DB-resident state (forge
        # endpoints, credentials, orgs, scale sets) track the module's declared
        # `github` + `scaleSets` shape. Scale sets, orgs, and credentials are DB
        # state (a scale set registers a GitHub runner-scale-set and gets an id),
        # so `config.toml` alone cannot converge them — the reconcile drives
        # `garm-cli` idempotently to create-missing / update-drifted, and
        # (GUARDED) prune-undeclared. See `reconcile.enable`.
        reconcile = {
          enable = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Enable the `garm-reconcile` systemd oneshot: after `garm.service`
              is up, idempotently sync GARM's DB (forge endpoint + credentials +
              orgs + scale sets) to the declared `services.garm.github` +
              `services.garm.scaleSets`. A second run with unchanged config is a
              no-op. Unrelated runtime state (runners, other controllers) is
              never touched. Default false — declaring the shape does NOT enable
              the reconcile, so enabling it on a host with a live DB is a
              deliberate step. Prove it hermetically (the `t_garm_reconcile` VM
              test) before enabling against a live GARM DB.
            '';
          };

          pruneUnmanaged = mkOption {
            type = types.bool;
            default = false;
            description = ''
              CONSERVATIVE, OPT-IN pruning. When true, the reconcile DELETES
              scale sets it manages (those whose org is one of the declared
              `scaleSets.*.org` values) that are no longer declared, and
              likewise undeclared orgs/credentials it recognises as managed.
              Default false so the reconcile can NEVER accidentally delete the
              live mcl/blocksense/agent-harbor scale sets: with pruning off, a
              scale set dropped from the Nix config is simply left in the DB
              (logged as "unmanaged, kept"). Only the reconcile-managed set is
              ever eligible for pruning — a scale set in an org GARM knows about
              but that this config never declares an org for is left alone even
              with pruning on.
            '';
          };

          adminUsername = mkOption {
            type = types.str;
            default = "admin";
            description = ''
              Administrative username the reconcile uses (creating it via
              first-run if the controller is un-initialised, then logging the
              local garm-cli profile in as it). Only meaningful for the
              reconcile's own garm-cli session.
            '';
          };

          adminEmail = mkOption {
            type = types.str;
            default = "garm-reconcile@localhost";
            description = "Email used when the reconcile performs the first-run admin init.";
          };

          adminPasswordFile = mkOption {
            type = types.nullOr types.path;
            default = null;
            description = ''
              Optional path to a file holding the admin password the reconcile
              uses for first-run + garm-cli login (staged via LoadCredential).
              Null (default) ⇒ a strong password is generated once and persisted
              under stateDir (mode 0600). Changing an already-initialised
              controller's admin password is NOT attempted.
            '';
          };

          forgeEndpoint = mkOption {
            type = types.str;
            default = "github.com";
            description = ''
              The GARM forge endpoint name the reconcile associates credentials
              + orgs with. Defaults to GARM's built-in `github.com`. Set to a
              custom name (with `apiBaseURL`/`baseURL`) to point GARM at a
              non-github.com GitHub (GitHub Enterprise) — or, in the hermetic
              test, at an in-VM mock GitHub API.
            '';
          };

          apiBaseURL = mkOption {
            type = types.str;
            default = "";
            example = "http://127.0.0.1:8081";
            description = ''
              When `forgeEndpoint` is NOT `github.com`, the API base URL of that
              endpoint (created/updated via `garm-cli github endpoint`). Empty
              for the built-in github.com endpoint (GARM already knows it).
            '';
          };

          baseURL = mkOption {
            type = types.str;
            default = "";
            example = "http://127.0.0.1:8081";
            description = ''
              When `forgeEndpoint` is NOT `github.com`, the (web) base URL of the
              custom endpoint. Empty for the built-in github.com endpoint.
            '';
          };

          uploadURL = mkOption {
            type = types.str;
            default = "";
            description = ''
              Optional upload URL for a custom `forgeEndpoint`. Empty ⇒ reuse
              `apiBaseURL`.
            '';
          };
        };

        openIncusBridgeFirewall = mkOption {
          type = types.bool;
          default = false;
          description = ''
            When an incus-backend provider is used, trust its incus bridge
            (`providers.<name>.incusBridge`) for the GARM API/metadata/callback
            port, so per-job CONTAINERS can reach the host GARM endpoint. Wires
            `networking.firewall.interfaces.<bridge>.allowedTCPPorts =
            [ apiServer.port ]` for every enabled incus provider's bridge.

            This ONLY opens the container->host GARM path, and ONLY on the bridge
            interface (never the public firewall). Container->internet EGRESS
            needs NO host change: incus's own `inet incus` nftables table already
            NATs + forwards the bridge.
          '';
        };

        # The guest-facing controller URLs. GARM hands these to the runner
        # instance; the guest fetches its JIT config from metadataURL and reports
        # status to callbackURL. They MUST be reachable from the guest — the host
        # bridge IP on the provider network, never localhost.
        metadataURL = mkOption {
          type = types.str;
          default = "";
          example = "http://192.168.122.1:9997/api/v1/metadata";
          description = ''
            `[default].metadata_url` — the base URL the runner fetches its
            JIT/instance metadata from. Must be guest-reachable.
          '';
        };
        callbackURL = mkOption {
          type = types.str;
          default = "";
          example = "http://192.168.122.1:9997/api/v1/callbacks";
          description = ''
            `[default].callback_url` — the base URL the runner posts status
            reports back to. Must be guest-reachable.
          '';
        };

        # Run GARM as a dedicated system user (default) instead of a DynamicUser
        # whenever a provider is enabled. The libvirt provider needs the `garm`
        # user to be in the libvirtd/kvm groups; the incus provider needs
        # incus-admin — a DynamicUser (fresh uid each boot) cannot be a stable
        # group member.
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

        # Extra supplementary groups for the service user. The module adds the
        # provider-required groups automatically (libvirtd/kvm for any libvirt
        # provider, incus-admin for any incus provider); this lets a host add
        # more (e.g. a storage group for a shared pool dir).
        extraGroups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          description = "Additional supplementary groups for the garm service user.";
        };

        # EXP-MP — the GitHub App forge credentials, wired DECLARATIVELY, as an
        # attrset of named credentials (each a `[[github]]` block). OPT-IN
        # (default {}) so M0/M5 boots are unaffected. Each App PEM is supplied
        # via LoadCredential (agenix at runtime) and NEVER enters the store.
        # Orgs + scale sets remain runtime/DB state (provisioned via garm-cli),
        # since they carry GitHub-side state — only the credentials are
        # declarative here.
        github = mkOption {
          default = { };
          description = ''
            GitHub App forge credentials, keyed by credential name. Each entry is
            emitted as a `[[github]]` block (imported into GARM's DB on first
            boot) and its App PEM staged via LoadCredential. Multiple entries
            support multiple orgs. Empty (default) keeps the forge-less M0 boot.
          '';
          type = types.attrsOf (types.submodule githubModule);
        };

        # EXP-MP — declared HOST RESOURCE BUDGET for the eval-time autoscale
        # guard. A bad config fails to EVAL, long before anything boots.
        hostBudget = {
          memoryMb = mkOption {
            type = types.ints.positive;
            default = 65536;
            description = ''
              Total guest RAM (MiB) the host is willing to commit to ephemeral
              runner VMs. The assertion requires the sum over all scale sets of
              `maxRunners * <its provider>.memoryMb <= hostBudget.memoryMb`.
            '';
          };
          vcpus = mkOption {
            type = types.ints.positive;
            default = 32;
            description = ''
              Total guest vCPUs the host is willing to commit. The assertion
              requires the sum over all scale sets of
              `maxRunners * <its provider>.vcpus <= hostBudget.vcpus`.
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

        # EXP-MP — the vm-harness external providers, an attrset of named
        # instances (each a `[[provider]]` block). OPT-IN (default {}) so M0's
        # forge-less/provider-less boot is unaffected. Multiple entries let a
        # single GARM drive Windows (libvirt) + Linux (incus) — and, on m3, macOS
        # (tart) — from one control plane.
        providers = mkOption {
          default = { };
          description = ''
            Named vm-harness external provider instances, keyed by provider name
            (the `[[provider]].name` referenced by scale sets). Each has its own
            backend (libvirt|incus), image map, network, and per-VM sizing, and
            is rendered as a distinct GARM `[[provider]]` block. The systemd
            sandbox posture is the UNION across the enabled instances.
          '';
          type = types.attrsOf (types.submodule providerModule);
        };

        # M5 autoscale tuning for scale sets. Scale sets are NOT part of garm's
        # `config.toml`: GitHub owns the scheduling and each scale set carries
        # GitHub-side state, so they are provisioned at runtime via `garm-cli
        # scaleset add/update`. This option captures the DECLARATIVE tuning shape
        # + ties each scale set to a named provider + org credential.
        scaleSets = mkOption {
          default = { };
          description = ''
            Declarative autoscale tuning for GARM scale sets, keyed by scale-set
            name (the workflow `runs-on:` selector). Records the intended
            concurrency policy (concurrency cap, warm-pool size, bootstrap
            timeout, labels), the backing `provider`, and the `org`/`credentials`
            the scale set is created against. Applied at runtime via `garm-cli
            scaleset` since scale sets carry GitHub-side state.
          '';
          type = types.attrsOf (
            types.submodule (
              { name, ... }:
              {
                options = {
                  provider = mkOption {
                    type = types.str;
                    default = "vmharness";
                    description = "The named `services.garm.providers.<provider>` that backs this scale set.";
                  };
                  org = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-org";
                    description = ''
                      The GitHub organization the scale set belongs to (the
                      `garm-cli organization add --name <org>` target). Recorded
                      for the runtime/reconcile `garm-cli scaleset add --org`.
                    '';
                  };
                  credentials = mkOption {
                    type = types.str;
                    default = "";
                    example = "my-app";
                    description = ''
                      The `services.garm.github.<name>.credentialsName` the
                      scale set's org authenticates with. Ties the scale set to
                      one App credential.
                    '';
                  };
                  image = mkOption {
                    type = types.str;
                    default = "golden";
                    description = ''
                      Image identifier resolved against the backing provider's
                      `images` map to pick the golden the per-job instances clone
                      from.
                    '';
                  };
                  osType = mkOption {
                    type = types.enum [
                      "windows"
                      "linux"
                      "macos"
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
                      Concurrency CAP: the maximum number of ephemeral instances
                      GARM runs concurrently for this scale set. The primary host
                      resource guard — keep `maxRunners * <provider>.memoryMb`
                      within host RAM headroom.
                    '';
                  };
                  minIdleRunners = mkOption {
                    type = types.ints.unsigned;
                    default = 0;
                    description = ''
                      Warm-pool size: pre-booted idle runners kept ready and
                      refilled after consumption. 0 (default) == scale-to-zero.
                      Must be <= maxRunners.
                    '';
                  };
                  runnerBootstrapTimeout = mkOption {
                    type = types.ints.positive;
                    default = 20;
                    description = ''
                      Minutes before a runner that has not joined GitHub is
                      considered failed and replaced (`--runner-bootstrap-timeout`).
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
          # THE EXP-MP CENTERPIECE — the UNION sandbox posture across the enabled
          # providers.
          #
          # M0's forge-less boot ran GARM under a DynamicUser with a MAXIMAL
          # sandbox (ProtectSystem=strict, PrivateDevices, DeviceAllow=[] via an
          # empty CapabilityBoundingSet, a restricted syscall filter). That is
          # perfect for a pure-Go API daemon but FATAL for the libvirt provider,
          # which needs the qemu:///system libvirt socket, a real PATH to
          # genisoimage, write access to the VM pool dir, /dev/kvm, and a
          # NON-ephemeral uid in the libvirtd/kvm groups. The incus provider is
          # gentler: it only needs incus-admin socket-group access.
          #
          # So the posture is the UNION across the enabled providers:
          #   * NO provider (M0/boot-gate): unchanged — DynamicUser + full
          #     sandbox, BYTE-FOR-BYTE. The M0 boot gate keeps passing.
          #   * ANY libvirt provider ON: a dedicated `garm` system user in
          #     libvirtd+kvm (+ incus-admin if any incus provider is also on),
          #     with the qemu relaxations (ProtectSystem=full, DeviceAllow=
          #     /dev/kvm, ReadWritePaths for the pool dirs, no PrivateDevices/
          #     MDWE/syscall-filter). Everything else stays on.
          #   * INCUS provider(s) ONLY: a dedicated `garm` system user in
          #     `incus-admin` ONLY. Keeps the STRICT M0 knobs (PrivateDevices,
          #     MemoryDenyWriteExecute, ProtectSystem=strict, the @system-service
          #     syscall filter) and relaxes ONLY the user/group.
          providerList = lib.attrValues enabledProviders;
          providerOn = enabledProviders != { };
          anyIncus = lib.any (p: providerIsIncus p) providerList;
          anyLibvirt = lib.any (p: providerIsLibvirt p) providerList;
          anyQemuWindowsArm = lib.any (p: providerIsQemuWindowsArm p) providerList;
          # The libvirt (Windows VM) posture forces the qemu relaxations; the
          # incus (Linux container) posture does not.
          libvirtProviderOn = anyLibvirt;

          incusProviders = lib.filter (p: providerIsIncus p) providerList;
          libvirtProviders = lib.filter (p: providerIsLibvirt p) providerList;
          # Distinct pool dirs across the enabled libvirt providers.
          libvirtPoolDirs = lib.unique (map (p: p.poolDir) libvirtProviders);

          # The UNION of supplementary groups across the enabled providers.
          supplementaryGroups =
            lib.optionals anyLibvirt [
              "libvirtd"
              "kvm"
            ]
            ++ lib.optional anyIncus "incus-admin"
            ++ cfg.extraGroups;

          # LoadCredential list: the two M0 secrets (optional) + one App PEM per
          # enabled GitHub credential. All staged read-only under
          # $CREDENTIALS_DIRECTORY; never in the store.
          loadCredential =
            lib.optional (
              cfg.jwtSecretFile != null
            ) "${cfg.jwtSecretCredentialName}:${toString cfg.jwtSecretFile}"
            ++ lib.optional (
              cfg.dbPassphraseFile != null
            ) "${cfg.dbPassphraseCredentialName}:${toString cfg.dbPassphraseFile}"
            ++ lib.mapAttrsToList (name: g: "${appKeyCredName name}:${toString g.appKeyFile}") (
              lib.filterAttrs (_: g: g.appKeyFile != null) enabledGithub
            );

          # The dedicated-user base (shared by both provider postures).
          userBaseServiceConfig = {
            User = cfg.user;
            Group = cfg.group;
            SupplementaryGroups = supplementaryGroups;
          };

          # The qemu relaxations (any libvirt provider ON — the Windows VM path).
          libvirtRelaxServiceConfig = userBaseServiceConfig // {
            # RELAXATION 1: ProtectSystem=full (not strict) so the provider can
            # write its pool dir + the libvirt runtime socket; /usr,/boot,/etc
            # stay read-only.
            ProtectSystem = "full";
            # RELAXATION 2: explicit ReadWritePaths for the VM pool dir(s) +
            # libvirt runtime. StateDirectory already grants stateDir rw.
            ReadWritePaths = libvirtPoolDirs ++ [
              "/var/lib/libvirt"
              "/run/libvirt"
            ];
            # RELAXATION 3: NO PrivateDevices — the libvirt path needs device
            # access. Scope it to exactly the devices needed via DeviceAllow.
            DeviceAllow = [
              "/dev/kvm rw"
              "/dev/null rw"
              "/dev/zero rw"
              "/dev/full rw"
              "/dev/random r"
              "/dev/urandom r"
              "/dev/ptmx rw"
            ];
            # RELAXATION 4: NO SystemCallFilter (added below only for the
            # non-libvirt postures) — the provider execs cdrkit's mkisofs which
            # is SIGSYS-killed under @system-service.
            # RELAXATION 5: NO MemoryDenyWriteExecute (qemu JIT) — dropped by
            # simply not setting it here (M0/incus set it below).
          };

          # The incus posture (incus provider(s) ONLY — the Linux container
          # path). Relaxes ONLY the user/group vs M0: a dedicated `garm` user in
          # `incus-admin`. Keeps ProtectSystem=strict, PrivateDevices,
          # MemoryDenyWriteExecute, and the @system-service filter (added below).
          incusStrictServiceConfig = userBaseServiceConfig // {
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

          # The reconcile needs a STABLE uid it can share with garm (both read
          # the same stateDir + garm-cli HOME). A DynamicUser gets a fresh uid
          # per boot, so when the reconcile is enabled WITHOUT any provider we
          # keep the strict M0 sandbox but pin garm to the dedicated `garm`
          # system user instead of DynamicUser. (With a provider on, garm ALREADY
          # runs as the dedicated user, so no change.)
          staticStrictServiceConfig = userBaseServiceConfig // {
            ProtectSystem = "strict";
            PrivateDevices = true;
            MemoryDenyWriteExecute = true;
          };

          # A dedicated static `garm` user is required whenever a provider is on
          # OR the reconcile is enabled.
          needsDedicatedUser = providerOn || rcfg.enable;

          # Posture selector: strict M0 DynamicUser (nothing on), the strict
          # static-user posture (reconcile on, no provider), libvirt relaxations
          # (any libvirt), or the strict incus posture (incus only). libvirt
          # "wins" the relaxations; its group set is unioned with incus-admin
          # when both are on.
          postureServiceConfig =
            if !providerOn then
              (if rcfg.enable then staticStrictServiceConfig else m0ServiceConfig)
            else if anyLibvirt then
              libvirtRelaxServiceConfig
            else
              incusStrictServiceConfig;
        in
        {
          assertions =
            # M5 invariant: a warm pool can never exceed the concurrency cap.
            lib.mapAttrsToList (n: ss: {
              assertion = ss.minIdleRunners <= ss.maxRunners;
              message = "services.garm.scaleSets.${n}: minIdleRunners (${toString ss.minIdleRunners}) must be <= maxRunners (${toString ss.maxRunners}).";
            }) cfg.scaleSets
            # EXP-MP: a scale set must reference a declared provider.
            ++ lib.mapAttrsToList (n: ss: {
              assertion = cfg.providers ? ${ss.provider};
              message = "services.garm.scaleSets.${n}.provider = \"${ss.provider}\" does not name a declared services.garm.providers.<name> (have: ${lib.concatStringsSep ", " (lib.attrNames cfg.providers)}).";
            }) cfg.scaleSets
            # Resource-guard (eval time): the sum over all scale sets of
            # maxRunners * (its provider's per-VM RAM) must fit the declared host
            # RAM budget, and likewise vCPUs. A bad config FAILS TO EVAL instead
            # of OOM-ing the host at runtime.
            ++ [
              {
                assertion =
                  let
                    totalMb = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.memoryMb or 0)
                    ) 0 cfg.scaleSets;
                  in
                  totalMb <= cfg.hostBudget.memoryMb;
                message =
                  let
                    totalMb = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.memoryMb or 0)
                    ) 0 cfg.scaleSets;
                  in
                  "services.garm: worst-case ephemeral guest RAM (sum of maxRunners * provider.memoryMb = ${toString totalMb} MiB) exceeds hostBudget.memoryMb (${toString cfg.hostBudget.memoryMb} MiB). Lower maxRunners/memoryMb or raise hostBudget.memoryMb.";
              }
              {
                assertion =
                  let
                    totalVcpu = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.vcpus or 0)
                    ) 0 cfg.scaleSets;
                  in
                  totalVcpu <= cfg.hostBudget.vcpus;
                message =
                  let
                    totalVcpu = lib.foldlAttrs (
                      acc: _: ss:
                      acc + ss.maxRunners * (cfg.providers.${ss.provider}.vcpus or 0)
                    ) 0 cfg.scaleSets;
                  in
                  "services.garm: worst-case ephemeral guest vCPUs (sum of maxRunners * provider.vcpus = ${toString totalVcpu}) exceeds hostBudget.vcpus (${toString cfg.hostBudget.vcpus}). Lower maxRunners/vcpus or raise hostBudget.vcpus.";
              }
            ]
            # EXP-MP: each enabled App credential needs its PEM + ids.
            ++ lib.mapAttrsToList (name: g: {
              assertion = g.appKeyFile != null;
              message = "services.garm.github.${name} requires appKeyFile (the App PEM, staged via LoadCredential).";
            }) enabledGithub
            # EXP-MP: each enabled incus provider injects a static IPv4 per
            # container (incusbr0 DHCP does not lease), so a subnet + gateway are
            # required. Mirrors the provider's own Validate().
            ++ lib.mapAttrsToList (name: p: {
              assertion = p.backend != "incus" || (p.incusIPv4CIDR != "" && p.incusIPv4Gateway != "");
              message = "services.garm.providers.${name}.backend = \"incus\" requires incusIPv4CIDR and incusIPv4Gateway (incusbr0 DHCP does not lease; the provider injects a static IPv4 per container).";
            }) enabledProviders;

          environment.systemPackages = [ cfg.package ];

          networking.firewall = {
            allowedTCPPorts = mkIf cfg.openFirewall [ cfg.apiServer.port ];
            # EXP-MP declarative egress: trust each enabled incus provider's
            # bridge for the GARM API/metadata/callback port so per-job
            # CONTAINERS can reach the host GARM endpoint. Only the bridge
            # interface (never the public firewall).
            interfaces = mkIf cfg.openIncusBridgeFirewall (
              lib.listToAttrs (
                map (
                  p: lib.nameValuePair p.incusBridge { allowedTCPPorts = [ cfg.apiServer.port ]; }
                ) incusProviders
              )
            );
          };

          # Dedicated system user for the provider posture. Created
          # unconditionally-when-any-provider-on so the socket-group membership
          # (libvirtd+kvm for the VM path; incus-admin for the container path) is
          # stable across boots (a DynamicUser cannot be a persistent member).
          users.users = mkIf needsDedicatedUser {
            ${cfg.user} = {
              isSystemUser = true;
              group = cfg.group;
              description = "GARM (GitHub Actions Runner Manager) service user";
              home = stateDir;
            };
          };
          users.groups = mkIf needsDedicatedUser { ${cfg.group} = { }; };

          # Each enabled libvirt provider writes per-job artifacts into its
          # poolDir; provision each owned garm:libvirtd (0771). The incus daemon
          # owns container storage, so incus providers need no host pool dir.
          systemd.tmpfiles.rules = map (dir: "d ${dir} 0771 ${cfg.user} libvirtd - -") libvirtPoolDirs;

          systemd.services.garm = {
            description = "GitHub Actions Runner Manager (garm)";
            documentation = [ "https://github.com/cloudbase/garm" ];
            # GARM reads the external-provider executable and config paths only
            # at daemon startup.  Keep those paths tied to the declarative
            # template so a provider package/config change cannot leave the
            # old provider live after a system switch.
            restartTriggers = [ configTemplate ];
            after = [
              "network.target"
            ]
            ++ lib.optional anyLibvirt "libvirtd.service"
            ++ lib.optional anyIncus "incus.service";
            wants = lib.optional anyLibvirt "libvirtd.service" ++ lib.optional anyIncus "incus.service";
            wantedBy = [ "multi-user.target" ];

            # The provider child inherits the unit PATH (GARM forwards PATH via
            # environment_variables). libvirt: cdrkit(genisoimage)+qemu+libvirt
            # for the config-drive/clone path. incus: the `incus` client.
            # qemu-windows-arm: swtpm for the Windows ARM TPM emulator.
            path =
              lib.optionals anyLibvirt [
                pkgs.cdrkit
                pkgs.qemu
                pkgs.libvirt
              ]
              ++ lib.optional anyIncus pkgs.incus
              ++ lib.optional anyQemuWindowsArm pkgs.swtpm;

            serviceConfig = {
              Type = "simple";

              ExecStartPre = lib.getExe renderScript;
              ExecStart = lib.escapeShellArgs [
                (lib.getExe cfg.package)
                "-config"
                renderedConfig
              ];
              # FU9 startup bind-verify: wait for the API listener to bind and
              # FAIL the start (→ Restart=always restarts garm) if it never does
              # within startupBindTimeout — catching the bind race at startup.
              # A failing ExecStartPost marks the unit failed and triggers the
              # Restart policy. Opt-outable via healthcheck.startupBindVerify.
              ExecStartPost = lib.optional (hcfg.enable && hcfg.startupBindVerify) (lib.getExe bindVerifyScript);
              ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
              Restart = "always";
              RestartSec = "5s";

              StateDirectory = "garm";
              StateDirectoryMode = "0700";
              WorkingDirectory = stateDir;

              LoadCredential = loadCredential;

              # ---- Hardening COMMON to every posture --------------------------
              # These do NOT interfere with any provider and stay on everywhere
              # (a superset of upstream contrib/garm.service).
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
            # strict-but-incus-admin sandbox (incus only), or the qemu
            # relaxations (any libvirt provider).
            // postureServiceConfig
            # The strict @system-service syscall filter is kept for EVERY posture
            # EXCEPT the libvirt one — the libvirt path execs cdrkit's mkisofs
            # which is SIGSYS-killed under it. M0 (pure Go daemon) and the incus
            # path (Go daemon + the `incus` Go CLI) both pass it.
            // lib.optionalAttrs (!libvirtProviderOn) {
              SystemCallFilter = [
                "@system-service"
                "~@privileged"
                "~@resources"
              ];
            };
          };

          # ---- The declarative reconcile oneshot ----------------------------
          # Runs AFTER garm.service is up, converges GARM's DB onto the declared
          # github creds + orgs + scale sets, then exits (RemainAfterExit so a
          # re-switch re-runs it). Idempotent: a second run with unchanged config
          # makes no changes. It runs as the SAME user as garm (so it reads the
          # module-staged PEM copies under stateDir + shares the garm-cli HOME)
          # and, like garm, may stage an operator admin password via
          # LoadCredential. Enabling it is OPT-IN (`reconcile.enable`).
          systemd.services.garm-reconcile = mkIf rcfg.enable {
            description = "Reconcile GARM DB state (orgs/credentials/scale sets) to the declared config";
            documentation = [ "https://github.com/cloudbase/garm" ];
            after = [ "garm.service" ];
            requires = [ "garm.service" ];
            wantedBy = [ "multi-user.target" ];

            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
              ExecStart = lib.getExe reconcileScript;
              # Run as the garm user so it reads the staged PEMs + shares HOME.
              User = cfg.user;
              Group = cfg.group;
              StateDirectory = "garm";
              WorkingDirectory = stateDir;
              LoadCredential = lib.optional (
                rcfg.adminPasswordFile != null
              ) "reconcile-admin-password:${toString rcfg.adminPasswordFile}";
              # Retry a few times if garm is still coming up.
              Restart = "on-failure";
              RestartSec = "5s";
            };
            unitConfig = {
              StartLimitIntervalSec = "120";
              StartLimitBurst = 6;
            };
          };

          # ---- FU9 GARM-API-WATCHDOG: health-check service + timer -----------
          # A periodic oneshot that probes the GARM API on the SAME loopback
          # address+port garm binds (and reconcile probes). It restarts
          # garm.service ONLY after `failureThreshold` CONSECUTIVE
          # connection-refused/timeout probes, and never more often than
          # `minRestartInterval` — recovering a process-alive-but-API-dead garm
          # without ever restarting a healthy-but-busy one or restart-storming.
          #
          # It runs as ROOT (needs `systemctl restart garm.service`) but does
          # only a loopback curl + a counter file under stateDir + one restart;
          # the heavy sandbox is unnecessary for a tiny probe and would block
          # the `systemctl` D-Bus call, so it is intentionally minimal.
          systemd.services.garm-healthcheck = mkIf hcfg.enable {
            description = "GARM API health-check watchdog (auto-recover a process-alive-but-API-dead garm)";
            documentation = [ "https://github.com/cloudbase/garm" ];
            # Probe only once garm is (meant to be) up. Not a hard requires: the
            # timer keeps probing across garm restarts.
            after = [ "garm.service" ];
            serviceConfig = {
              Type = "oneshot";
              ExecStart = lib.getExe healthCheckScript;
              # Use the watchdog's OWN state dir — NOT garm's. This root-run
              # oneshot with StateDirectory="garm" made systemd re-chown
              # /var/lib/garm to root on every run, breaking garm's DB access.
              StateDirectory = "garm-healthcheck";
              # Hardening: read-only system, no new privs. It still needs D-Bus
              # to systemctl-restart garm, so keep the sandbox light.
              ProtectSystem = "strict";
              NoNewPrivileges = true;
              ProtectHome = true;
              PrivateTmp = true;
            };
          };

          systemd.timers.garm-healthcheck = mkIf hcfg.enable {
            description = "Periodic GARM API health-check (FU9 watchdog)";
            wantedBy = [ "timers.target" ];
            timerConfig = {
              OnBootSec = hcfg.interval;
              OnUnitActiveSec = hcfg.interval;
              # If the machine was asleep, do not fire a burst of catch-up runs.
              AccuracySec = "10s";
              Unit = "garm-healthcheck.service";
            };
          };
        }
      );
    };
}
