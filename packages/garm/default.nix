{
  lib,
  # GARM's go.mod pins `go 1.26.2`. This flake's default `nixpkgs`
  # (nixos-25.11) ships go 1.25.9 as the default `buildGoModule` toolchain, so
  # use the explicit 1.26 builder to satisfy the module directive without
  # letting the Go toolchain try to auto-download 1.26.2 in the sandbox
  # (GOTOOLCHAIN=local under buildGoModule).
  buildGo126Module,
  fetchFromGitHub,
}:
# Ephemeral-Windows-Runners-GARM M0 — package cloudbase/garm (the GitHub
# Actions Runner Manager control plane) for NixOS. GARM vendors all of its Go
# dependencies in-tree (`vendor/` + `vendor/modules.txt`), so the build is
# fully offline with `vendorHash = null` — Nix builds against the checked-in
# vendor directory and pulls NO k8s/cloud SDKs beyond what the pin already
# vendors. The daemon (`garm`) and admin CLI (`garm-cli`) are both produced.
buildGo126Module rec {
  pname = "garm";
  version = "0.2.1";

  # Pin the exact upstream commit for v0.2.1 (do NOT depend on the local
  # references/garm overlay — CI builds nixos-modules without it).
  rev = "154638445c3949c1958b01812f69d9a1e4d82684";

  src = fetchFromGitHub {
    owner = "cloudbase";
    repo = "garm";
    inherit rev;
    hash = "sha256-Eqa0gnPm/puaxVqODJ+nwphYgt0crN6D/OmRijzmZ/M=";
  };

  # Deps are vendored in-tree → build offline against `vendor/`.
  vendorHash = null;

  # go-sqlite3 is a cgo module; the daemon needs cgo to link SQLite.
  # (The upstream Makefile builds with sqlite_omit_load_extension; we keep
  # cgo on so the SQLite driver links.)
  env.CGO_ENABLED = "1";

  # Build both binaries the upstream Makefile builds.
  subPackages = [
    "cmd/garm"
    "cmd/garm-cli"
  ];

  # Match the upstream build tags (osusergo/netgo static-ish build + the
  # SQLite extension-loading omission) so runtime behaviour matches a stock
  # `make build`.
  tags = [
    "osusergo"
    "netgo"
    "sqlite_omit_load_extension"
  ];

  # Stamp the version the way the Makefile does
  # (-X .../util/appdefaults.Version). Without this, `garm --version` prints
  # "v0.0.0-unknown". The M0 gate asserts this equals the pin.
  ldflags = [
    "-s"
    "-w"
    "-X github.com/cloudbase/garm/util/appdefaults.Version=v${version}"
  ];

  # The repo has no compilable tests wired for an offline vendored build and
  # the M0 gate exercises the binaries in a VM; skip the Go check phase.
  doCheck = false;

  meta = {
    description = "GitHub Actions Runner Manager (GARM) — control plane for self-hosted runners";
    homepage = "https://github.com/cloudbase/garm";
    license = lib.licenses.asl20;
    mainProgram = "garm";
    platforms = lib.platforms.linux ++ lib.platforms.darwin;
  };
}
