{ withSystem, ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA2.
  #
  # `services.vm-harness-serve` — a hardened systemd unit running `vm-harness
  # serve` (the RA1 remoting daemon). This is the GENERAL, company-agnostic
  # machinery: it bakes in NO Metacraft host list, IPs, or credentials. The
  # concrete instantiation (which hosts, which overlay IPs, the agenix token
  # ciphertext) lives in the private `infra` repo, which CONSUMES these options.
  #
  # The daemon is the uniform network access point that lets ONE central GARM's
  # providers target every Linux host (campaign Phase B), replacing the per-host
  # GARM + the eph-linux-x64 capacity band-aid. The SAME daemon fronts whichever
  # backends the host runs — the per-request backend is the client's
  # `run --backend <id>` argv — so one instance can serve incus (Linux
  # containers) AND libvirt (e.g. the Windows-11 VMs on high-mem-server, RA3).
  # Backend access is opened parametrically: {option}`extraGroups` for the
  # backend's control group(s) as a unit-level runtime grant (enough for incus,
  # which checks the socket peer's runtime groups), {option}`staticGroups` for
  # backends whose authorization reads the user's STATIC group-database entry
  # instead (libvirt, via polkit — a runtime-only grant is invisible to it),
  # {option}`extraPackages` for its CLI(s), and {option}`readWritePaths` /
  # {option}`readOnlyPaths` for the sandbox holes a disk-image backend needs.
  # NO backend is hardcoded here.
  #
  # Posture (campaign non-negotiable pattern (a) + serve.md "Auth & network
  # posture"): the control channel is authenticated (bearer token over the
  # NetBird overlay) and is NEVER exposed on a public interface. This module
  # enforces that two ways at once — it binds the listener to a single overlay
  # address (never 0.0.0.0), and it opens the port ONLY on the overlay
  # interface's firewall zone (never the global firewall). The bearer token is
  # delivered out of the world-readable store via systemd `LoadCredential`
  # (agenix-provisioned ciphertext in infra).
  #
  # It is idle-cheap / scale-to-zero-friendly: a single accept loop handling one
  # connection at a time, no polling, no timers — an idle daemon costs ~nothing.
  flake.modules.nixos.vm-harness-serve =
    {
      config,
      lib,
      pkgs,
      ...
    }:
    let
      cfg = config.services.vm-harness-serve;
      inherit (lib)
        mkEnableOption
        mkIf
        mkOption
        types
        optional
        optionals
        optionalString
        ;

      # Default to this flake's vendored vm-harness package (its single binary
      # includes `vm-harness serve`), resolved for the host's system — mirrors
      # how `services.garm` defaults `package` to `config.packages.garm`.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.vm-harness
      );

      credName = "token";
      # $CREDENTIALS_DIRECTORY is exposed to the unit as %d.
      tokenCredPath = "%d/${credName}";
      runtimeDir = "vm-harness-serve";
      portFile = "/run/${runtimeDir}/port";
    in
    {
      options.services.vm-harness-serve = {
        enable = mkEnableOption ''
          the `vm-harness serve` remoting daemon — an authenticated network
          front-end exposing this host's VM/container lifecycle ops to a remote
          controller over the NetBird overlay
        '';

        package = mkOption {
          type = types.package;
          default = defaultPackage;
          defaultText = lib.literalMD "this flake's `vm-harness` package";
          description = ''
            The vm-harness package whose `serve` subcommand is run. Its single
            binary includes both the daemon and the backend code it fronts.
          '';
        };

        listenAddress = mkOption {
          type = types.str;
          default = "127.0.0.1";
          example = "100.83.180.254";
          description = ''
            The single address the daemon binds to. This MUST be a NetBird
            overlay IP (or another private/overlay interface address) — NEVER a
            public interface and NEVER `0.0.0.0`. Binding one overlay address is
            the first of the two mechanisms that keep the control channel off the
            public internet (the second is the overlay-only firewall opening).

            The default `127.0.0.1` is a safe non-routable placeholder; a real
            deployment overrides it with the host's overlay IP.
          '';
        };

        port = mkOption {
          type = types.port;
          default = 8873;
          description = "TCP port the daemon listens on (vm-harness serve default).";
        };

        backend = mkOption {
          type = types.str;
          default = "auto";
          example = "incus";
          description = ''
            The `--backend` the daemon reports/advertises on `GET /v1/info`
            (`auto` probes which backends are usable on this host). Note the
            per-request backend is chosen by the client's `run --backend <id>`
            argv, so this mainly seeds the capability report.
          '';
        };

        authTokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/agenix/vm-harness-serve/token";
          description = ''
            Path to the file holding the bearer token (a decrypted agenix
            secret, e.g. `config.age.secrets."vm-harness-serve/token".path`). It
            is handed to the daemon via systemd `LoadCredential`, so the token is
            copied into the unit's private credentials store and never placed in
            the world-readable Nix store. Required when {option}`enable` is true.
          '';
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = optional config.virtualisation.incus.enable config.virtualisation.incus.package;
          defaultText = lib.literalMD "`[ config.virtualisation.incus.package ]` when incus is enabled, else `[ ]`";
          description = ''
            Extra packages placed on the daemon's `PATH`. The serve daemon shells
            out to the backend CLI it drives (e.g. `incus`, `virsh`), so that CLI
            must be here. Defaults to the incus package when incus is enabled on
            the host.
          '';
        };

        user = mkOption {
          type = types.str;
          default = "vm-harness-serve";
          description = "System user the daemon runs as.";
        };

        group = mkOption {
          type = types.str;
          default = "vm-harness-serve";
          description = "Primary group of the daemon user.";
        };

        extraGroups = mkOption {
          type = types.listOf types.str;
          default = optional config.virtualisation.incus.enable "incus-admin";
          defaultText = lib.literalMD "`[ \"incus-admin\" ]` when incus is enabled, else `[ ]`";
          description = ''
            Supplementary groups the daemon needs to reach its backend. The incus
            client reaches the daemon socket via the `incus-admin` group (added by
            default when incus is enabled); a libvirt host adds `libvirtd` (the
            group NixOS' libvirtd polkit rule grants `org.libvirt.unix.manage`)
            plus `kvm`. A host that serves BOTH backends lists all of them, e.g.
            `[ "incus-admin" "libvirtd" "kvm" ]`.
          '';
        };

        staticGroups = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "libvirtd" ];
          description = ''
            Groups the daemon USER is made a STATIC member of in the group
            database (`users.users.<user>.extraGroups`), in addition to the
            per-unit runtime {option}`extraGroups`.

            This distinction is load-bearing and backend-specific:

            * incus authorizes by the connecting process's *runtime* groups
              (`SO_PEERCRED`), so a unit-level `SupplementaryGroups` grant
              (i.e. {option}`extraGroups`) is enough — nothing is needed here.

            * libvirt authorizes through **polkit**, and polkit resolves
              `subject.isInGroup("libvirtd")` from the user's *static* group
              database entry, NOT from the process's runtime supplementary
              groups. A runtime-only grant is therefore invisible to polkit and
              the `org.libvirt.unix.manage` action is refused. So a libvirt host
              MUST list `libvirtd` (the group NixOS' libvirtd polkit rule
              allows) here, e.g. `[ "libvirtd" "kvm" ]`.

            Static membership is a per-user grant, so keep {option}`user` a
            dedicated system user (the default) that runs nothing but this
            daemon.
          '';
        };

        readWritePaths = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "/storage/vm-harness-serve" ];
          description = ''
            Filesystem subtrees the daemon needs WRITE access to under the
            `ProtectSystem=strict` sandbox (which otherwise mounts the whole
            hierarchy read-only). Passed through to the unit's
            `ReadWritePaths=`.

            The incus path needs none of these (it drives everything through the
            incus socket). A libvirt host needs write access to the per-job image
            pool directory — where the backend writes each job's copy-on-write
            overlay (`<name>.overlay.qcow2`) and config-drive ISO before defining
            the transient domain. That directory must also be owned/writable by
            {option}`user` (create it with `systemd.tmpfiles`).
          '';
        };

        readOnlyPaths = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [ "/storage/iso" ];
          description = ''
            Filesystem subtrees to expose read-only to the daemon, passed through
            to the unit's `ReadOnlyPaths=`. Under `ProtectSystem=strict` the
            hierarchy is already read-only, so this is mostly documentation of
            intent — e.g. the directory holding a libvirt golden image the
            backend clones the per-job overlay from. Listing it makes the daemon's
            read surface explicit and survives a future relaxation of the sandbox.
          '';
        };

        overlayInterface = mkOption {
          type = types.nullOr types.str;
          default = "nb-default";
          example = "nb-default";
          description = ''
            The overlay (NetBird) network interface whose firewall zone the port
            is opened on — and ONLY that zone. This never touches the global
            firewall (`networking.firewall.allowedTCPPorts`), so the port stays
            unreachable from any non-overlay interface. Set to `null` to open no
            firewall hole at all (rely solely on the overlay-address bind, e.g.
            when the overlay interface is already fully trusted).
          '';
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = cfg.authTokenFile != null;
            message = ''
              services.vm-harness-serve.authTokenFile must be set — the daemon
              refuses to start without a bearer token, and it must arrive via a
              LoadCredential-mounted file (an agenix secret), never the store.
            '';
          }
          {
            assertion = cfg.listenAddress != "0.0.0.0" && cfg.listenAddress != "::";
            message = ''
              services.vm-harness-serve.listenAddress must be a single overlay
              address, never a wildcard (0.0.0.0 / ::) — the control channel must
              not be exposed on a public interface.
            '';
          }
        ];

        users.users.${cfg.user} = {
          isSystemUser = true;
          group = cfg.group;
          home = "/var/lib/${runtimeDir}";
          # STATIC group membership — needed by backends whose access check
          # reads the user's group-database entry rather than the socket peer's
          # runtime groups (libvirt via polkit). See staticGroups' description.
          extraGroups = cfg.staticGroups;
        };
        users.groups.${cfg.group} = { };

        # Open the port ONLY on the overlay interface's firewall zone — never the
        # global firewall. Combined with the single-address bind, the port is
        # unreachable off the overlay.
        networking.firewall.interfaces = mkIf (cfg.overlayInterface != null) {
          ${cfg.overlayInterface}.allowedTCPPorts = [ cfg.port ];
        };

        systemd.services.vm-harness-serve = {
          description = "vm-harness serve — VM/container remoting daemon (NetBird-only)";
          wantedBy = [ "multi-user.target" ];
          after = [
            "network-online.target"
          ]
          ++ optional config.virtualisation.incus.enable "incus.service"
          # Order after libvirtd when present so its system socket exists before
          # the daemon may be asked to drive a libvirt job (harmless on hosts
          # that never receive a `--backend libvirt` request).
          ++ optional config.virtualisation.libvirtd.enable "libvirtd.service"
          # Order after agenix ONLY when it runs as a systemd unit; on the infra
          # hosts agenix runs from an activation script (no unit), so this stays
          # inert there.
          ++ optional (config.systemd.services ? agenix-install-secrets) "agenix-install-secrets.service";
          wants = [ "network-online.target" ];
          requires = optional config.virtualisation.incus.enable "incus.service";

          # The backend CLI the daemon shells out to must be on PATH.
          path = [ cfg.package ] ++ cfg.extraPackages;

          serviceConfig = {
            # Type=exec (not simple): with LoadCredential, `exec` waits for the
            # credential setup + the execve, avoiding the credential-race the
            # garm module documents.
            Type = "exec";
            ExecStart = lib.concatStringsSep " " [
              (lib.getExe cfg.package)
              "serve"
              "--listen ${cfg.listenAddress}:${toString cfg.port}"
              "--backend ${cfg.backend}"
              "--auth-token-file ${tokenCredPath}"
              "--port-file ${portFile}"
            ];
            LoadCredential = [ "${credName}:${toString cfg.authTokenFile}" ];
            # Fail fast + loud if the agenix secret is missing at start.
            # (unitConfig below.)

            User = cfg.user;
            Group = cfg.group;
            SupplementaryGroups = cfg.extraGroups;

            Restart = "on-failure";
            RestartSec = 2;

            RuntimeDirectory = runtimeDir;
            RuntimeDirectoryMode = "0750";
            StateDirectory = runtimeDir;
            StateDirectoryMode = "0700";
            WorkingDirectory = "/var/lib/${runtimeDir}";
            # The incus CLI writes its config under $HOME; keep it in the state dir.
            Environment = [ "HOME=/var/lib/${runtimeDir}" ];

            # ---- systemd hardening (mirrors the garm incus-strict posture) ----
            NoNewPrivileges = true;
            ProtectHome = true;
            ProtectSystem = "strict";
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
            SystemCallFilter = [
              "@system-service"
              "~@privileged"
              "~@resources"
            ];
            CapabilityBoundingSet = [ "" ];
            AmbientCapabilities = [ "" ];
            UMask = "0077";
          }
          # Punch the backend-specific holes in ProtectSystem=strict: a libvirt
          # host needs its per-job image pool writable and (optionally) the
          # golden's directory read-exposed. incus hosts leave both empty.
          // lib.optionalAttrs (cfg.readWritePaths != [ ]) {
            ReadWritePaths = cfg.readWritePaths;
          }
          // lib.optionalAttrs (cfg.readOnlyPaths != [ ]) {
            ReadOnlyPaths = cfg.readOnlyPaths;
          };

          unitConfig.AssertPathExists = [ (toString cfg.authTokenFile) ];
        };
      };
    };
}
