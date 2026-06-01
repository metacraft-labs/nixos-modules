# Cloud-init NoCloud seed for the nixos-ah-test-guest VM
#
# This module produces the user-data + meta-data files for a NoCloud
# datasource seed.  The NixOS guest configuration in ./configuration.nix
# enables `services.cloud-init`, which on first boot mounts the attached
# seed ISO (typically as /dev/sr0), reads user-data, and applies the
# embedded SSH authorized_keys + hostname.
#
# This mirrors the pattern in ../ubuntu/cloud-init.nix.  The main difference
# is that NixOS already has the `agent` user provisioned at image build
# time (via the `users.users.${username}` declaration in configuration.nix),
# so the cloud-init user-data here only contributes:
#
#   - The SSH public key to authorize for that account.
#   - The instance hostname (so multiple guests cloned from the same image
#     can be addressed individually if they ever run in parallel).
#
# Cloud-init handles writing to /home/agent/.ssh/authorized_keys via its
# `users` module's `ssh_authorized_keys` directive.
#
# References:
#   - Cloud-init NoCloud spec: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html
#   - NixOS cloud-init integration: services.cloud-init.enable
{ pkgs, lib }:

{
  # Generate the cloud-init seed ISO contents for the AH test guest.
  #
  # Parameters:
  #   hostname     — instance hostname (defaults to "nixos-ah-test-guest")
  #   username     — user account to authorize the SSH key for (default "agent")
  #   sshPublicKey — OpenSSH-format public key string
  #
  # Returns: a derivation with $out/user-data and $out/meta-data, suitable to
  # be passed to `cloud-localds` to produce the seed ISO that the host-side
  # launcher attaches to the VM.
  makeCloudInitConfig =
    {
      hostname ? "nixos-ah-test-guest",
      username ? "agent",
      sshPublicKey,
    }:
    let
      userData = pkgs.writeText "user-data" ''
        #cloud-config

        # Hostname for this instance.  NixOS also sets networking.hostName at
        # build time; cloud-init overrides it at runtime to allow per-clone
        # personalisation without rebuilding the image.
        hostname: ${hostname}
        preserve_hostname: false

        # NoCloud datasource: the user `agent` is already provisioned by the
        # NixOS configuration.  We only authorize the SSH key here.  Setting
        # `lock_passwd: true` is a safety net — NixOS already locks the
        # password by virtue of not declaring `hashedPassword`.
        users:
          - name: ${username}
            sudo: ALL=(ALL) NOPASSWD:ALL
            lock_passwd: true
            ssh_authorized_keys:
              - ${sshPublicKey}
            shell: /run/current-system/sw/bin/bash

        # SSH server settings — these match the NixOS services.openssh
        # configuration but reasserting them via cloud-init lets the host
        # operator override them per-instance if needed.
        ssh_pwauth: false
        disable_root: true

        # No package_update here — NixOS is declarative; cloud-init's
        # apt/yum-based package management modules would just no-op or
        # complain on a NixOS guest.

        final_message: "Cloud-init complete: nixos-ah-test-guest is ready for `ssh ${username}@<host>`."
      '';

      metaData = pkgs.writeText "meta-data" ''
        instance-id: ${hostname}
        local-hostname: ${hostname}
      '';
    in
    pkgs.runCommand "nixos-ah-test-guest-cloud-init-config" { } ''
      mkdir -p $out
      cp ${userData} $out/user-data
      cp ${metaData} $out/meta-data
    '';

  # Test SSH key pair.  As with ../ubuntu/cloud-init.nix this is intentionally
  # a fixed key suitable only for development VMs — *do not reuse it in any
  # production context*.  Operators who want a per-instance key should pass
  # their own public key to `makeCloudInitConfig` instead of calling this.
  generateTestSSHKey =
    {
      name ? "nixos-ah-test-guest-key",
    }:
    let
      testPrivateKey = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDBIYUxvrIdnIXyr5EigY+rIYE++F25pRA+WFFPgS//NwAAAJgWpgwXFqYM
        FwAAAAtzc2gtZWQyNTUxOQAAACDBIYUxvrIdnIXyr5EigY+rIYE++F25pRA+WFFPgS//Nw
        AAAEAcw84lZU3hJvwbCtmqqRDocXOwagjfDLYGWF9ISWaK0cEhhTG+sh2chfKvkSKBj6sh
        gT74XbmlED5YUU+BL/83AAAAE3ZtLXRlc3Qta2V5QHZtLXRlc3QBAg==
        -----END OPENSSH PRIVATE KEY-----
      '';
      testPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMEhhTG+sh2chfKvkSKBj6shgT74XbmlED5YUU+BL/83 vm-test-key@vm-test";

      privateKeyFile = pkgs.writeText "${name}-private-key" testPrivateKey;
      publicKeyFile = pkgs.writeText "${name}-public-key" testPublicKey;

      keyDir = pkgs.runCommand "${name}-ssh-key" { } ''
        mkdir -p $out
        cp ${privateKeyFile} $out/id_ed25519
        cp ${publicKeyFile} $out/id_ed25519.pub
        chmod 600 $out/id_ed25519
        chmod 644 $out/id_ed25519.pub
      '';
    in
    {
      privateKey = "${keyDir}/id_ed25519";
      publicKey = testPublicKey;
      keyPath = keyDir;
    };
}
