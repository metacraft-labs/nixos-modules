top@{ ... }:
{
  # Declarative GARM Reconcile — deliverables (2)+(3) gate: t_garm_incus_runner_host.
  #
  # Boots a NixOS VM with incus + the `services.garm-incus-runner-host` helper
  # and proves the two operator steps it replaces are now declarative:
  #
  #   (2) incus PRESEED bridge — after switch, the managed `incusbr0` exists on
  #       the declared per-host subnet (gateway .1/24, ipv4.nat on), created by
  #       the nixpkgs incus-preseed.service the helper populates. Replaces the
  #       manual `incus admin init` / `incus network create incusbr0 …`.
  #
  #   (3) image-import ONESHOT — the helper's garm-incus-image-import oneshot
  #       imports the runner image under the declared alias iff absent, and a
  #       re-run is a NO-OP. We feed it a tiny hand-built incus image tarball
  #       (metadata-only, no rootfs needed to register an alias in the store's
  #       image DB) and assert the alias appears, then re-run and assert the
  #       oneshot stays green + the alias count is unchanged.
  perSystem =
    {
      pkgs,
      lib,
      ...
    }:
    let
      flake = top.config.flake;

      subnet = "10.157.159.0/24";

      # A minimal unified incus image tarball: just a metadata.yaml describing a
      # trivial image. `incus image import <tarball>` registers it (alias) in
      # the local image store without needing a bootable rootfs for THIS gate
      # (we assert registration, not launch).
      testImage =
        pkgs.runCommand "vmh-linux-runner-test-image.tar.gz"
          {
            nativeBuildInputs = [
              pkgs.gnutar
              pkgs.gzip
            ];
          }
          ''
            mkdir -p build/rootfs
            cat > build/metadata.yaml <<EOF
            architecture: x86_64
            creation_date: 1700000000
            properties:
              description: garm reconcile gate test image
              os: debian
              release: bookworm
            EOF
            # An empty rootfs dir is fine for registration.
            tar -C build -czf $out metadata.yaml rootfs
          '';
    in
    {
      checks = lib.optionalAttrs pkgs.stdenv.hostPlatform.isLinux {
        t_garm_incus_runner_host = pkgs.testers.nixosTest {
          name = "t_garm_incus_runner_host";

          nodes.host =
            { ... }:
            {
              imports = [ flake.modules.nixos.garm-incus-runner-host ];
              networking.nftables.enable = true;
              virtualisation.incus.enable = true;
              # Give the VM enough disk for the incus storage pool.
              virtualisation.diskSize = 4096;
              environment.systemPackages = [ pkgs.jq ];

              services.garm-incus-runner-host = {
                enable = true;
                bridgeSubnet = subnet;
                image = {
                  alias = "vmh-linux-runner";
                  source = testImage;
                };
              };
            };

          testScript = ''
            host.wait_for_unit("multi-user.target")
            host.wait_for_unit("incus.service")
            host.wait_for_unit("incus-preseed.service")

            with subtest("(2) preseed created incusbr0 on the declared subnet"):
                host.succeed("incus network show incusbr0")
                addr = host.succeed(
                    "incus network get incusbr0 ipv4.address"
                ).strip()
                assert addr == "10.157.159.1/24", f"incusbr0 ipv4.address={addr!r}"
                nat = host.succeed("incus network get incusbr0 ipv4.nat").strip()
                assert nat == "true", f"incusbr0 ipv4.nat={nat!r}"

            with subtest("(3) image-import oneshot registered the alias"):
                host.wait_for_unit("garm-incus-image-import.service")
                aliases = host.succeed("incus image alias list --format csv | cut -d, -f1")
                assert "vmh-linux-runner" in aliases, f"alias missing: {aliases!r}"

            with subtest("(3) a re-run of the image-import oneshot is a no-op"):
                before = host.succeed(
                    "incus image alias list --format csv | grep -c vmh-linux-runner"
                ).strip()
                host.systemctl("restart garm-incus-image-import.service")
                host.wait_for_unit("garm-incus-image-import.service")
                # Still green (the check-then-import short-circuits) and the
                # alias count is unchanged (no duplicate import).
                state = host.succeed(
                    "systemctl show -p Result --value garm-incus-image-import.service"
                ).strip()
                assert state == "success", f"re-run result={state!r}"
                after = host.succeed(
                    "incus image alias list --format csv | grep -c vmh-linux-runner"
                ).strip()
                assert before == after == "1", f"alias count drifted: {before!r} -> {after!r}"
                # The oneshot logged the no-op path.
                host.succeed(
                    "journalctl -u garm-incus-image-import.service | grep -q 'already present'"
                )
          '';
        };
      };
    };
}
