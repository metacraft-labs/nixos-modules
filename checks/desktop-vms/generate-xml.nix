# Generates domain XML files from test fixtures using the desktop-vms lib.
#
# Usage:
#   nix build -f checks/desktop-vms/generate-xml.nix -o result
#   ls result/   # one .xml file per fixture
{
  pkgs ? import <nixpkgs> { },
}:

let
  lib = pkgs.lib;
  desktopVmsLib = import ../../modules/virtualisation/desktop-vms/lib.nix { inherit lib; };
  fixtures = import ./fixtures.nix;

  xmlFiles = lib.mapAttrs (
    name: params: pkgs.writeText "${name}.xml" (desktopVmsLib.generateDomainXml params)
  ) fixtures;
in
pkgs.runCommand "desktop-vms-test-xmls" { } ''
  mkdir -p $out
  ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: drv: "cp ${drv} $out/${name}.xml") xmlFiles)}
''
