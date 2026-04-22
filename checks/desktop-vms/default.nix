# Golden-file tests for desktop-vms XML generation.
#
# Builds domain XML from test fixtures and compares against checked-in
# golden files.  Any mismatch fails the check and prints a diff.
#
# Golden files are stored with trailing whitespace stripped (to satisfy
# editorconfig), so both sides are normalized before comparison.
#
# To update golden files after an intentional change:
#   nix build -f checks/desktop-vms/generate-xml.nix -o /tmp/vms
#   for f in /tmp/vms/*.xml; do sed 's/[[:space:]]*$//' "$f" > checks/desktop-vms/golden/$(basename "$f"); done
{ lib, ... }:
{
  perSystem =
    { pkgs, ... }:
    let
      inherit (pkgs.stdenv.hostPlatform) isLinux;

      desktopVmsLib = import ../../modules/virtualisation/desktop-vms/lib.nix { inherit (pkgs) lib; };
      fixtures = import ./fixtures.nix;

      # Build each fixture's XML as a store path
      generatedXmls = lib.mapAttrs (
        name: params: pkgs.writeText "${name}.xml" (desktopVmsLib.generateDomainXml params)
      ) fixtures;

      goldenDir = ./golden;

      # One diff command per fixture — normalize trailing whitespace on both
      # sides so golden files can satisfy editorconfig (trim_trailing_whitespace)
      diffCommands = lib.concatStringsSep "\n" (
        lib.mapAttrsToList (
          name: drv:
          let
            golden = "${goldenDir}/${name}.xml";
          in
          ''
            echo "Checking ${name}..."
            sed 's/[[:space:]]*$//' "${golden}" | sed -e '$a\' > "$TMPDIR/${name}.golden"
            sed 's/[[:space:]]*$//' "${drv}"    | sed -e '$a\' > "$TMPDIR/${name}.actual"
            if ! diff -u "$TMPDIR/${name}.golden" "$TMPDIR/${name}.actual" > "$TMPDIR/${name}.diff" 2>&1; then
              echo "FAIL: ${name} — output differs from golden file"
              cat "$TMPDIR/${name}.diff"
              failed=1
            else
              echo "  OK"
            fi
          ''
        ) generatedXmls
      );
    in
    {
      checks = lib.optionalAttrs isLinux {
        desktop-vms-golden = pkgs.runCommand "desktop-vms-golden-test" { } ''
          failed=0
          ${diffCommands}
          if [ "$failed" -ne 0 ]; then
            echo ""
            echo "Golden file mismatch detected."
            echo "If the change is intentional, update golden files:"
            echo "  nix build -f checks/desktop-vms/generate-xml.nix -o /tmp/vms"
            echo "  for f in /tmp/vms/*.xml; do sed 's/[[:space:]]*\$//' \"\$f\" > checks/desktop-vms/golden/\$(basename \"\$f\"); done"
            exit 1
          fi
          echo ""
          echo "All ${toString (lib.length (lib.attrNames fixtures))} fixtures match golden files."
          touch $out
        '';
      };
    };
}
