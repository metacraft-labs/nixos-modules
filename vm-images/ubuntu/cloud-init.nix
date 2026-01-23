# Cloud-Init Configuration Generator for Linux VMs
#
# This module generates cloud-init configuration files (user-data and meta-data)
# that are used to configure VMs on first boot. Cloud-init is the industry standard
# for VM initialization in cloud environments.
#
# References:
# - Cloud-init documentation: https://cloud-init.readthedocs.io/
# - Cloud-init examples: https://cloudinit.readthedocs.io/en/latest/reference/examples.html
# - NoCloud data source: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html

{ pkgs, lib }:

{
  # Generate a minimal cloud-init configuration for Ubuntu VMs.
  #
  # Parameters:
  #   hostname: The hostname to set for the VM
  #   username: The primary user account to create
  #   sshPublicKey: SSH public key for key-based authentication
  #   sshPort: Port for SSH server (default: 22)
  #   installNix: Whether to install Nix multi-user daemon (default: false)
  #   ahFollowerdPath: Optional path to ah-followerd binary to deploy (default: null)
  #
  # Returns: A derivation containing user-data and meta-data files
  #
  # Example usage:
  #   makeCloudInitConfig {
  #     hostname = "ubuntu-follower";
  #     username = "agent";
  #     sshPublicKey = "ssh-ed25519 AAAAC3...";
  #     sshPort = 22;
  #     installNix = true;
  #     ahFollowerdPath = "${ah-followerd}/bin/ah-followerd";
  #   }
  makeCloudInitConfig =
    {
      hostname,
      username,
      sshPublicKey,
      sshPort ? 22,
      installNix ? false,
      ahFollowerdPath ? null,
    }:
    let
      # Base64-encode ah-followerd binary if provided
      # Cloud-init's write_files module supports base64 encoding for binary files
      # Reference: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#write-files
      ahFollowerdBase64 =
        if ahFollowerdPath != null then
          pkgs.runCommand "ah-followerd-base64" { } ''
            base64 -w 0 ${ahFollowerdPath} > $out
          ''
        else
          null;

      # Cloud-init user-data configuration in YAML format
      # This configures the initial user, SSH access, and basic system settings
      userData = pkgs.writeText "user-data" ''
        #cloud-config

        # Set the hostname for the VM
        hostname: ${hostname}

        # Create a user account with sudo privileges
        # The 'users' module is the primary way to configure user accounts in cloud-init
        # Reference: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#users-and-groups
        users:
          - name: ${username}
            # Grant full sudo access without password (needed for automated testing)
            sudo: ALL=(ALL) NOPASSWD:ALL
            # Add user to common administrative groups
            groups: [sudo, docker, users]
            # Lock the password to enforce SSH key-only authentication
            # This is a security best practice for cloud VMs
            lock_passwd: true
            # Install the SSH public key for authentication
            ssh_authorized_keys:
              - ${sshPublicKey}
            # Use bash as the default shell
            shell: /bin/bash

        # SSH server configuration
        # Reference: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#ssh
        ssh_pwauth: false  # Disable password authentication (keys only)
        disable_root: true  # Disable root login via SSH

        # Package management - update cache on first boot
        # This ensures we have access to the latest packages
        package_update: true
        package_upgrade: false  # Don't upgrade to save time on first boot

        # Deploy ah-followerd binary if provided
        # The write_files module allows us to write arbitrary files during cloud-init
        # We use base64 encoding for binary files to ensure correct transfer
        # Reference: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#write-files
        ${lib.optionalString (ahFollowerdPath != null) ''
          write_files:
            - path: /usr/local/bin/ah-followerd
              permissions: '0755'
              owner: root:root
              encoding: b64
              content: ${builtins.readFile ahFollowerdBase64}
        ''}

        # Install required packages for Nix installation (if needed)
        # The Nix installer requires curl and other basic utilities
        ${lib.optionalString installNix ''
          packages:
            - curl
            - xz-utils
        ''}

        # Run commands during first boot
        # These commands are executed after the user is created and packages are installed
        # Reference: https://cloudinit.readthedocs.io/en/latest/reference/modules.html#runcmd
        ${lib.optionalString (sshPort != 22 || installNix) ''
          runcmd:
        ''}
        ${lib.optionalString (sshPort != 22) ''
          # Configure SSH to listen on the specified port
          - sed -i 's/^#Port 22/Port ${toString sshPort}/' /etc/ssh/sshd_config
          - systemctl restart sshd
        ''}
        ${lib.optionalString installNix ''
          # Install Nix package manager (multi-user installation)
          #
          # We use the official Nix installer which:
          # 1. Creates the /nix directory and sets up the Nix store
          # 2. Creates build users (nixbld1, nixbld2, ...) for sandboxed builds
          # 3. Installs and starts the nix-daemon systemd service
          # 4. Configures shell profiles to source Nix environment
          #
          # The --daemon flag enables multi-user installation (required for production use)
          # The --yes flag makes the installation non-interactive (required for automation)
          #
          # Why multi-user installation:
          # - Sandboxed builds: Each build runs as a separate user for security
          # - System-wide installation: All users can access Nix
          # - Nix daemon: Manages builds and store operations centrally
          #
          # Reference: https://nixos.org/manual/nix/stable/installation/multi-user.html
          # Installer source: https://github.com/NixOS/nix/blob/master/scripts/install-multi-user.sh
          - |
            echo "Installing Nix package manager..."

            # Set HOME for the installer script (required for multi-user installation)
            # The cloud-init runcmd context doesn't have HOME set by default
            export HOME=/root

            # Download and run the official Nix installer
            # Using --daemon for multi-user installation (creates nix-daemon service)
            # Using --yes for non-interactive installation
            curl -L https://nixos.org/nix/install | sh -s -- --daemon --yes

            # Verify installation succeeded by checking for /nix/store
            if [ ! -d /nix/store ]; then
              echo "ERROR: Nix installation failed - /nix/store does not exist" >&2
              exit 1
            fi

            # Verify nix-daemon service is running
            if ! systemctl is-active --quiet nix-daemon; then
              echo "ERROR: Nix daemon is not running" >&2
              exit 1
            fi

            # Source Nix environment for all users by creating daemon config
            # This ensures nix commands are available in PATH
            # The installer already sets this up, but we verify it exists
            if [ ! -f /etc/profile.d/nix.sh ]; then
              echo "WARNING: /etc/profile.d/nix.sh not found after installation" >&2
            fi

            echo "Nix installation complete"
        ''}

        # Final message to indicate cloud-init has completed
        final_message: "Cloud-init configuration complete. System is ready."
      '';

      # Cloud-init meta-data configuration
      # This provides instance-specific metadata to the VM
      # Reference: https://cloudinit.readthedocs.io/en/latest/reference/datasources/nocloud.html#metadata
      metaData = pkgs.writeText "meta-data" ''
        instance-id: ${hostname}
        local-hostname: ${hostname}
      '';
    in
    pkgs.runCommand "cloud-init-config" { } ''
      mkdir -p $out
      cp ${userData} $out/user-data
      cp ${metaData} $out/meta-data
    '';

  # Generate a test SSH key pair for VM testing
  # This uses a fixed test key pair that is suitable for automated testing
  # NOTE: This key is NOT secure and should only be used for testing purposes
  #
  # The key pair below is a well-known test key that should never be used in production.
  # It's included here to avoid IFD (Import From Derivation) issues during flake evaluation.
  generateTestSSHKey =
    {
      name ? "vm-test-key",
    }:
    let
      # Fixed test private key (ED25519)
      # This is a randomly generated key specifically for VM testing
      # DO NOT use this in production environments
      testPrivateKey = ''
        -----BEGIN OPENSSH PRIVATE KEY-----
        b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAAAMwAAAAtzc2gtZW
        QyNTUxOQAAACDBIYUxvrIdnIXyr5EigY+rIYE++F25pRA+WFFPgS//NwAAAJgWpgwXFqYM
        FwAAAAtzc2gtZWQyNTUxOQAAACDBIYUxvrIdnIXyr5EigY+rIYE++F25pRA+WFFPgS//Nw
        AAAEAcw84lZU3hJvwbCtmqqRDocXOwagjfDLYGWF9ISWaK0cEhhTG+sh2chfKvkSKBj6sh
        gT74XbmlED5YUU+BL/83AAAAE3ZtLXRlc3Qta2V5QHZtLXRlc3QBAg==
        -----END OPENSSH PRIVATE KEY-----
      '';

      # Corresponding public key
      testPublicKey = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIMEhhTG+sh2chfKvkSKBj6shgT74XbmlED5YUU+BL/83 vm-test-key@vm-test";

      # Create the key pair as derivations
      privateKeyFile = pkgs.writeText "${name}-private-key" testPrivateKey;
      publicKeyFile = pkgs.writeText "${name}-public-key" testPublicKey;

      # Bundle keys in a directory structure
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
