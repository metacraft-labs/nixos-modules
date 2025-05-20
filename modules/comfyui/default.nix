{ withSystem, ... }:
{
  flake.modules.nixos.comfyui =
    {
      pkgs,
      config,
      lib,
      ...
    }:
    let
      cfg = config.services.comfyui;
      package = withSystem pkgs.stdenv.hostPlatform.system (
        { config, ... }: config.packages.comfyui.override ({ inherit (cfg) basePath; })
      );
    in
    {
      options.services.pyroscope =
        with lib;
        {
          enable = mkEnableOption (lib.mdDoc "ComfyUI");
          basePath = mkOption {
            type = types.path;
            default = "/var/lib/comfyui";
            description = "Base path for ComfyUI data.";
          };
          nodes = mkOption {
            type = types.listOf types.package;
            default = [ ];
            description = "List of custom nodes to install. (Some are defined in comfyui.nodes)";
          };
          models = mkOption {
            type = types.attrsOf types.listOf (
              types.either types.package (
                types.submodule {
                  options = {
                    url = mkOption {
                      type = types.str;
                      description = "URL to the model.";
                    };
                    hash = mkOption {
                      type = types.str;
                      description = "Hash of the model.";
                    };
                    name = mkOption {
                      type = types.str;
                      default = null;
                      description = "Filename of the model.";
                    };
                  };
                }
              )
            );
            default = {
              checkpoints = [ ];
              clip = [ ];
              clip_vision = [ ];
              configs = [ ];
              controlnet = [ ];
              diffusion_models = [ ];
              embeddings = [ ];
              loras = [ ];
              style_models = [ ];
              text_encoders = [ ];
              upscale_models = [ ];
              vae = [ ];
              vae_approx = [ ];
            };
            description = "List of models to install. (Either derivations or sets of urls, hashes and optionally filenames)";
          };
          port = mkOption {
            type = types.port;
            default = 8188;
            description = "Port for ComfyUI.";
          };
          listen = mkOption {
            type = types.str;
            default = null;
            description = "Specify the IP address to listen on (default: 127.0.0.1). You can give a list of ip addresses by separating them with a comma like: 127.2.2.2,127.3.3.3 If --listen is provided without an argument, it defaults to 0.0.0.0,:: (listens on all ipv4 and ipv6)";
          };
          cudaDevice = mkOption {
            type = types.str;
            default = null;
            description = "Set the id of the cuda device this instance will use.";
          };
          tlsKeyFile = mkOption {
            type = types.path;
            default = null;
            description = "Path to the TLS key file. If set, ComfyUI will use TLS. (Requires tlsCertFile)";
          };
          tlsCertFile = mkOption {
            type = types.path;
            default = null;
            description = "Path to the TLS certificate file. If set, ComfyUI will use TLS. (Requires tlsKeyFile)";
          };
          enableCorsHeader = mkOption {
            type = types.either types.str types.bool;
            default = false;
            description = "Enable CORS (Cross-Origin Resource Sharing) with optional origin or allow all with default '*'.";
          };
          maxUploadSize = mkOption {
            type = types.int;
            default = 0;
            description = "Maximum upload size in MB. 0 means no limit.";
          };
          cudaMAlloc = mkOption {
            type = types.bool;
            default = true;
            description = "Enable cudaMallocAsync (enabled by default for torch 2.0 and up).";
          };
          deterministic = mkOption {
            type = types.bool;
            default = false;
            description = "Enable deterministic mode (default: false).";
          };
        }
        // builtins.listToAttrs (
          map
            (x: {
              name = "${x}Path";
              value = mkOption {
                type = types.path;
                default = "${cfg.basePath}/${x}";
                description = "Path for ComfyUI ${x} data.";
              };
            })
            [
              "models"
              "input"
              "output"
              "temp"
              "user"
            ]
        );
      config =
        with lib;
        with builtins;
        {
          assertions = [
            {
              assertion = (isNull cfg.tlsKeyFile) != (isNull cfg.tlsCertFile);
              message = "If tlsKeyFile is set, tlsCertFile must also be set and vice versa.";
            }
          ];
          systemd.services.pyroscope = lib.mkIf cfg.enable {
            description = "comfyui";
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              ExecStart =
                "${getExe package} --multi-user --port ${toString cfg.port}"
                + (optionalString (!isNull cfg.listen) " --listen ${cfg.listen}")
                + (optionalString (!isNull cfg.cudaDevice) " --cuda-device ${cfg.cudaDevice}")
                + (optionalString (!isNull cfg.tlsKeyFile) " --tls-keyfile ${toString cfg.tlsKeyFile}")
                + (optionalString (!isNull cfg.tlsCertFile) " --tls-certfile ${toString cfg.tlsCertFile}")
                + (optionalString (cfg.enableCorsHeader != false) (
                  " --enable-cors-header"
                  + (
                    if isString cfg.enableCorsHeader then
                      cfg.enableCorsHeader
                    else if cfg.enableCorsHeader == true then
                      "*"
                    else
                      ""
                  )
                ))
                + (optionalString (cfg.maxUploadSize != 0) " --max-upload-size ${toString cfg.maxUploadSize}")
                + (if cfg.cudaMAlloc then " --cuda-malloc" else " --disable-cuda-malloc")
                + (optionalString cfg.deterministic " --deterministic");
            };
          };
        };
    };
}
