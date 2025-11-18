{ withSystem, inputs, ... }:
let
  mkModule =
    variant:
    {
      config,
      options,
      lib,
      dirs,
      ...
    }:
    let
      eachServiceCfg = config.mcl.secrets.services;
      isDebugVM = config.mcl.host-info.isDebugVM;

      mcl-secrets = config.mcl.secrets;

      sshKey =
        if isDebugVM then
          config.virtualisation.vmVariant.mcl.host-info.sshKey
        else
          config.mcl.host-info.sshKey;

      ageSecretOpts = builtins.head (builtins.head options.age.secrets.type.nestedTypes.elemType.getSubModules)
      .imports;

      secretDir =
        let
          machineConfigPath = config.mcl.host-info.configPath;
          machineSecretDir = machineConfigPath + "/secrets";
          vmConfig = dirs.modules + "/default-vm-config";
          vmSecretDir = vmConfig + "/secrets";
        in
        if isDebugVM then vmSecretDir else machineSecretDir;
    in
    {
      imports = [
        inputs.agenix."${variant}Modules".default
      ];

      options.mcl.secrets = with lib; {
        extraKeys = mkOption {
          type = types.listOf types.str;
          default = [ ];
          example = [
            "ssh-ed25519 AAAAC3Nza"
            "ssh-ed25519 AAAACSNss"
          ];
          description = "Extra keys which can decrypt the secrets.";
        };

        services = mkOption {
          type = types.attrsOf (
            types.submodule (
              { config, ... }:
              let
                serviceName = config._module.args.name;
              in
              {
                options = {
                  encryptedSecretDir = mkOption {
                    type = types.path;
                    default = secretDir;
                  };
                  secrets = mkOption {
                    default = { };
                    type = types.attrsOf (
                      types.submoduleWith {
                        modules = [
                          ageSecretOpts
                          (
                            { name, ... }:
                            let
                              secretName = name;
                            in
                            {
                              config = {
                                name = "${serviceName}/${secretName}";
                                file = lib.mkDefault (config.encryptedSecretDir + "/${serviceName}/${secretName}.age");
                              };
                            }
                          )
                        ];
                      }
                    );
                  };
                  extraKeys = mkOption {
                    type = types.listOf types.str;
                    default = [ ];
                    example = [
                      "ssh-ed25519 AAAAC3Nza"
                      "ssh-ed25519 AAAACSNss"
                    ];
                    description = "Extra keys which can decrypt the secrets.";
                  };
                  nix-file = mkOption {
                    default = builtins.toFile "${serviceName}-secrets.nix" ''
                      let
                        hostKey = ["${sshKey}"];
                        extraKeysPerService = ["${concatStringsSep "\"\"" config.extraKeys}"];
                        extraKeysPerHost = ["${concatStringsSep "\"\"" mcl-secrets.extraKeys}"];
                      in {
                        ${concatMapStringsSep "\n" (
                          n: "\"${n}.age\".publicKeys = hostKey ++ extraKeysPerService ++ extraKeysPerHost;"
                        ) (builtins.attrNames config.secrets)}
                      }
                    '';
                    type = types.path;
                  };
                };
              }
            )
          );
          default = { };
          example = {
            service1.secrets.secretA = { };
            service1.secrets.secretB = { };
            service2.secrets.secretC = { };
            cachix-deploy.secrets.token = {
              path = "/etc/cachix-agent.token";
            };
          };
          description = mdDoc "Per-service attrset of encryptedSecretDir and secrets";
        };
      };

      config = lib.mkIf (eachServiceCfg != { }) {
        age.secrets = lib.pipe eachServiceCfg [
          (lib.mapAttrsToList (
            serviceName: service:
            lib.mapAttrsToList (
              secretName: config: lib.nameValuePair "${serviceName}/${secretName}" config
            ) service.secrets
          ))
          lib.concatLists
          lib.listToAttrs
        ];
      };
    };
in
{
  flake.modules = {
    nixos.mcl-secrets = mkModule "nixos";
    darwin.mcl-secrets = mkModule "darwin";
  };
}
