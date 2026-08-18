{ ... }:
{
  # The Windows guest-provisioning tests in `internal/provider` were written to
  # pin one thing that cannot be recovered later: `Initialize-RunnerToolchain`
  # must run BEFORE `Runner.Listener` starts, because actions/checkout is the
  # first step of a job and inherits whatever PATH the runner was launched with.
  # Provisioning that happens afterwards satisfies every content assertion and
  # still leaves checkout without git, silently degrading it to a REST-API zip
  # download with no submodules, no history and no LFS.
  #
  # Nothing ran those tests. `packages/garm-provider-vmharness/default.nix` sets
  # `doCheck = false`, and no workflow invokes `go test` for this package, so the
  # suite existed without ever executing -- a check that cannot report anything
  # is the same class of defect it was written to catch.
  #
  # This mirrors `garm-macos-runner-install-wrapper.nix`, which already enables
  # `doCheck` on a sibling package for exactly this reason. The tests are pure
  # template rendering: no network, no daemon, no guest.
  perSystem =
    { self', ... }:
    {
      checks.t_garm_provider_vmharness_windows_toolchain =
        self'.packages.garm-provider-vmharness.overrideAttrs
          (_old: {
            doCheck = true;
            checkPhase = ''
              runHook preCheck
              go test ./internal/provider
              runHook postCheck
            '';
          });
    };
}
