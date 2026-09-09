{ withSystem, ... }:
{
  # Runner-Fleet-Capability-Pools-And-Remote-Driving campaign, milestone RA5.
  #
  # `services.vm-harness-serve` — the DARWIN (nix-darwin / launchd) sibling of
  # the Linux `services.vm-harness-serve` systemd module. It runs the SAME RA1
  # `vm-harness serve` remoting daemon, but as a launchd system daemon rather
  # than a systemd unit, because nix-darwin has neither systemd, the NixOS
  # firewall, nor `LoadCredential`.
  #
  # Why a SIBLING module rather than one cross-platform module: the Linux module
  # is almost entirely systemd/firewall/user-database machinery
  # (`systemd.services`, `networking.firewall.interfaces`,
  # `users.users.<u>.isSystemUser`, `SupplementaryGroups`, `ProtectSystem`,
  # `LoadCredential`) — none of which exist on darwin. What the two share is the
  # CLI contract of the `serve` binary, not the deployment mechanism. This split
  # mirrors the repo's existing `deployment/{pull-agent,pull-agent-darwin}.nix`
  # and `mcl-reprobuild` nixos+darwin siblings.
  #
  # This is the GENERAL, company-agnostic machinery: it bakes in NO host list,
  # IPs, credentials, or Metacraft/tart specifics. The concrete instantiation
  # (which host, the overlay IP, the agenix token, the tart env + asuser worker
  # wrapper) lives in the private `infra` repo, which CONSUMES these options.
  #
  # Posture (campaign non-negotiable pattern (a) + serve.md "Auth & network
  # posture"): the control channel is authenticated (bearer token over the
  # NetBird overlay) and is NEVER exposed on a public interface. On darwin there
  # is no per-interface NixOS firewall to open a zone on, so the posture rests on
  # the single mechanism that IS available here: the listener binds ONE overlay
  # address (asserted to never be a wildcard). The token is read directly from
  # {option}`authTokenFile` (an agenix-darwin secret path) — launchd has no
  # `LoadCredential`, so the daemon reads the decrypted file, which must be
  # readable by {option}`user` (root by default).
  #
  # It is idle-cheap / scale-to-zero-friendly: a single accept loop handling one
  # connection at a time, no polling, no timers — an idle daemon costs ~nothing.
  flake.modules.darwin.vm-harness-serve =
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
        optionals
        ;

      # Default to this flake's vendored vm-harness package (its single binary
      # includes `vm-harness serve`), resolved for the host's system — mirrors
      # the Linux module and how `services.garm` defaults `package`.
      defaultPackage = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.vm-harness
      );

      portFile = "${cfg.stateDir}/port";
    in
    {
      options.services.vm-harness-serve = {
        enable = mkEnableOption ''
          the `vm-harness serve` remoting daemon on darwin (launchd) — an
          authenticated network front-end exposing this host's VM/container
          lifecycle ops to a remote controller over the NetBird overlay
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
          example = "100.83.174.120";
          description = ''
            The single address the daemon binds to. This MUST be a NetBird
            overlay IP (or another private/overlay interface address) — NEVER a
            public interface and NEVER `0.0.0.0`. On darwin this single-address
            bind is the ONLY posture mechanism (there is no NixOS per-interface
            firewall to also gate the port), so it is load-bearing.

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
          example = "tart-macos";
          description = ''
            The `--backend` the daemon reports/advertises on `GET /v1/info`
            (`auto` probes which backends are usable on this host). The
            per-request backend is chosen by the client's `run --backend <id>`
            argv, so this mainly seeds the capability report. On a tart host set
            it to `tart-macos` or `tart-linux-arm`.
          '';
        };

        authTokenFile = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = "/run/agenix/vm-harness-serve/token";
          description = ''
            Path to the file holding the bearer token (a decrypted agenix-darwin
            secret, e.g. `config.age.secrets."vm-harness-serve/token".path`).
            Passed to the daemon via `--auth-token-file`. launchd has no
            `LoadCredential`, so the daemon reads this path directly; it must be
            readable by {option}`user` (root by default). Required when
            {option}`enable` is true.
          '';
        };

        extraPackages = mkOption {
          type = types.listOf types.package;
          default = [ ];
          example = lib.literalMD "`[ pkgs.tart pkgs.sshpass pkgs.qemu ]`";
          description = ''
            Extra packages placed on the daemon's `PATH`. The serve daemon shells
            out to the backend CLI it drives (e.g. `tart`, `sshpass`, `qemu`), so
            that CLI must be here. `coreutils` is always added (the tart backend
            uses `timeout`).
          '';
        };

        environment = mkOption {
          type = types.attrsOf types.str;
          default = { };
          example = lib.literalMD ''
            `{ VM_HARNESS_TART_STATE_DIR = "/private/var/lib/vm-harness/tart"; }`
          '';
          description = ''
            Extra environment variables for the launchd daemon (merged into
            `EnvironmentVariables`, and thus inherited by the worker it spawns).
            This is where a tart host supplies its state-dir / asuser knobs
            (`VM_HARNESS_TART_STATE_DIR`, `TART_HOME`,
            `VM_HARNESS_DARWIN_ASUSER_UID`, the shared-store paths) so the
            serve-driven backend path is byte-equivalent to the local GARM-driven
            one. Kept OUT of the general module: the specific variables and values
            are deployment policy (infra).
          '';
        };

        workerExe = mkOption {
          type = types.nullOr types.path;
          default = null;
          example = lib.literalMD "a `launchctl asuser` wrapper script";
          description = ''
            Optional `--worker-exe`: the executable the daemon prepends to every
            forwarded `run …` argv instead of running the `vm-harness` binary
            directly. Defaults to null (the daemon self-execs `vm-harness`).

            A macOS/tart deployment points this at a wrapper that re-execs the
            worker inside the console user's GUI session, e.g.
            `exec /bin/launchctl asuser <uid> /usr/bin/sudo -E -u #<uid> -- <vm-harness> "$@"`
            — the same asuser+`sudo -E` mechanism the local-exec
            `garm-provider-vmharness` uses, because Tart links AppKit even under
            `--no-graphics` and deadlocks if run as uid 0. The wrapper + uid are
            deployment-specific, so they live in infra, not here.
          '';
        };

        user = mkOption {
          type = types.nullOr types.str;
          default = null;
          example = "root";
          description = ''
            launchd `UserName` for the daemon. Default null runs it in the system
            domain (root), which is correct for a tart host that drops the WORKER
            to the console user via {option}`workerExe` (mirroring GARM's
            root-daemon + asuser-worker split). Set a non-root user only for a
            backend whose whole daemon can run unprivileged.
          '';
        };

        group = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "launchd `GroupName` for the daemon (default null → system default).";
        };

        stateDir = mkOption {
          type = types.str;
          default = "/private/var/lib/vm-harness-serve";
          description = ''
            Daemon working directory + where the `--port-file` readiness file is
            written. Created (root-owned, 0750) by an activation script.
          '';
        };

        standardOutLog = mkOption {
          type = types.str;
          default = "/var/log/vm-harness-serve/stdout.log";
          description = "launchd `StandardOutPath`. Its directory is created at activation.";
        };

        standardErrorLog = mkOption {
          type = types.str;
          default = "/var/log/vm-harness-serve/stderr.log";
          description = "launchd `StandardErrorPath`. Its directory is created at activation.";
        };

        label = mkOption {
          type = types.str;
          default = "org.metacraft-labs.vm-harness-serve";
          description = "launchd job Label.";
        };
      };

      config = mkIf cfg.enable {
        assertions = [
          {
            assertion = pkgs.stdenv.hostPlatform.isDarwin;
            message = "services.vm-harness-serve (darwin) is only valid on a nix-darwin host.";
          }
          {
            assertion = cfg.authTokenFile != null;
            message = ''
              services.vm-harness-serve.authTokenFile must be set — the daemon
              refuses to start without a bearer token (an agenix secret path).
            '';
          }
          {
            assertion = cfg.listenAddress != "0.0.0.0" && cfg.listenAddress != "::";
            message = ''
              services.vm-harness-serve.listenAddress must be a single overlay
              address, never a wildcard (0.0.0.0 / ::) — on darwin the bind is
              the only thing keeping the control channel off a public interface.
            '';
          }
        ];

        # launchd cannot open StandardOut/StandardError paths, nor can the daemon
        # write the port file, unless these directories already exist. Create
        # them before nix-darwin reconciles the launchd jobs.
        system.activationScripts.preActivation.text = lib.mkAfter ''
          ${lib.getExe' pkgs.coreutils "install"} -d -m 0750 -o root -g wheel \
            ${lib.escapeShellArg cfg.stateDir} \
            ${lib.escapeShellArg (builtins.dirOf cfg.standardOutLog)} \
            ${lib.escapeShellArg (builtins.dirOf cfg.standardErrorLog)}
        '';

        launchd.daemons.vm-harness-serve = {
          serviceConfig = {
            Label = cfg.label;
            ProgramArguments = [
              (lib.getExe cfg.package)
              "serve"
              "--listen"
              "${cfg.listenAddress}:${toString cfg.port}"
              "--backend"
              cfg.backend
              "--auth-token-file"
              (toString cfg.authTokenFile)
              "--port-file"
              portFile
            ]
            ++ optionals (cfg.workerExe != null) [
              "--worker-exe"
              (toString cfg.workerExe)
            ];

            EnvironmentVariables = {
              PATH = lib.makeBinPath ([ cfg.package ] ++ cfg.extraPackages ++ [ pkgs.coreutils ]);
              HOME = cfg.stateDir;
            }
            // cfg.environment;

            # Restart on failure/crash, never busy-loop on a clean exit — the
            # launchd analogue of the Linux unit's `Restart=on-failure`.
            KeepAlive = {
              SuccessfulExit = false;
              Crashed = true;
            };
            RunAtLoad = true;
            ThrottleInterval = 10;
            StandardOutPath = cfg.standardOutLog;
            StandardErrorPath = cfg.standardErrorLog;
            WorkingDirectory = cfg.stateDir;
          }
          // lib.optionalAttrs (cfg.user != null) { UserName = cfg.user; }
          // lib.optionalAttrs (cfg.group != null) { GroupName = cfg.group; };
        };
      };
    };
}
